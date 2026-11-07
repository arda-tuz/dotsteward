"""Firmware updates through fwupd, only on the owner's word.

The list comes first and is read only: ``list_updates``. At the start of a run
``approve`` asks, on a terminal only, device by device; ``--accept firmware`` answers
the question in advance but does not replace the terminal, and without one nothing is
ever applied. At the end of a run ``apply`` opens a short sudo window of its own and
updates the approved devices, on mains power only. It reports a reboot that a device
needs and never reboots; a device that is locked is the vendor's business, by hand.

    listing = firmware.list_updates()
    approved = firmware.approve(listing, run, accepted="firmware" in accept)
    ...
    firmware.apply(approved, run)

The internal command line runs these three in a row, for tests and for a look by hand:

    python3 -m dotsteward_cli.firmware list [--report COMMAND] [--state-root DIR]
    python3 -m dotsteward_cli.firmware run [--accept] [--report COMMAND] [--state-root DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from dotsteward_cli import config, procs, report

_TOOL = "fwupdmgr"
_TIMEOUT_SECONDS = 60
# fwupdmgr's exit status for "nothing to do".
_NOTHING_TO_DO = 2
_LOCKED_FLAGS = {"locked", "updatable-hidden"}
_LOCKED_PROBLEMS = {"firmware-locked"}


@dataclass(frozen=True)
class Device:
    """A device with a release. ``current`` is what it runs, ``new`` the newest release."""

    device_id: str
    name: str
    current: str
    new: str
    needs_reboot: bool
    problems: tuple[str, ...] = ()


def _device_json(device: Device) -> dict[str, Any]:
    return {key: value for key, value in asdict(device).items() if key != "problems" or value}


@dataclass(frozen=True)
class Listing:
    """What fwupd has to say. ``available`` is false when the tool is not there or did not answer."""

    available: bool
    installable: tuple[Device, ...] = ()
    locked: tuple[Device, ...] = ()
    blocked: tuple[Device, ...] = ()
    error: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "available": self.available,
            "installable": [_device_json(device) for device in self.installable],
            "locked": [_device_json(device) for device in self.locked],
            "blocked": [_device_json(device) for device in self.blocked],
            "error": self.error,
        }


def _device(entry: Mapping[str, Any]) -> Device:
    releases = entry.get("Releases") or [{}]
    return Device(
        device_id=str(entry.get("DeviceId", "")),
        name=str(entry.get("Name", "")),
        current=str(entry.get("Version", "")),
        new=str(releases[0].get("Version", "")),
        needs_reboot="needs-reboot" in (entry.get("Flags") or ()),
        problems=tuple(str(problem) for problem in entry.get("Problems") or ()),
    )


def _locked(entry: Mapping[str, Any]) -> bool:
    flags = set(entry.get("Flags") or ())
    problems = set(entry.get("Problems") or ())
    return "updatable" not in flags or bool(flags & _LOCKED_FLAGS or problems & _LOCKED_PROBLEMS)


def _installable(entry: Mapping[str, Any]) -> bool:
    return not _locked(entry) and not entry.get("Problems")


def _blocked(entry: Mapping[str, Any]) -> bool:
    """Updatable, but a condition of the moment holds it back: a low battery, a closed lid."""
    return not _locked(entry) and bool(entry.get("Problems"))


def list_updates() -> Listing:
    """The devices with a release, read only: ``fwupdmgr get-updates --json``. Linux only, as the
    CLI sees the platform (DOTSTEWARD_PLATFORM first)."""
    if config.runtime_platform() != "linux":
        return Listing(False)
    try:
        done = subprocess.run(
            [_TOOL, "get-updates", "--json"],
            capture_output=True,
            text=True,
            timeout=_TIMEOUT_SECONDS,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        return Listing(False)
    except (OSError, subprocess.SubprocessError) as error:
        return Listing(False, error=str(error))
    if done.returncode == _NOTHING_TO_DO:
        return Listing(True)
    start = done.stdout.find("{")
    try:
        document = json.loads(done.stdout[start:]) if start >= 0 else None
    except ValueError:
        document = None
    if done.returncode != 0 or not isinstance(document, dict):
        return Listing(False, error=(done.stderr or done.stdout).strip() or f"exit {done.returncode}")
    devices = [entry for entry in document.get("Devices") or () if isinstance(entry, dict)]
    return Listing(
        True,
        installable=tuple(_device(entry) for entry in devices if _installable(entry)),
        locked=tuple(_device(entry) for entry in devices if _locked(entry)),
        blocked=tuple(_device(entry) for entry in devices if _blocked(entry)),
    )


def on_terminal() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def _ask_terminal(question: str) -> bool:
    print(question, end=" ", flush=True)
    return sys.stdin.readline().strip().lower() in {"y", "yes", "e", "evet"}


def _describe(device: Device) -> dict[str, Any]:
    described: dict[str, Any] = {
        "device": device.name,
        "id": device.device_id,
        "current": device.current,
        "new": device.new,
    }
    if device.problems:
        described["problems"] = list(device.problems)
    return described


def approve(
    listing: Listing,
    run: report.RunReport,
    *,
    accepted: bool = False,
    tty: bool | None = None,
    ask: Callable[[str], bool] = _ask_terminal,
) -> tuple[Device, ...]:
    """The devices the owner approves. Without a terminal none, whatever ``accepted`` says: the
    report names what is waiting. A locked device is named as well, and asked about never."""
    if listing.locked:
        run.item(
            "firmware-locked",
            pending=False,
            devices=[_describe(device) for device in listing.locked],
            message="locked firmware is updated by hand, from the site of the vendor",
        )
    if listing.blocked:
        run.item(
            "firmware-blocked",
            pending=False,
            devices=[_describe(device) for device in listing.blocked],
            message="a condition of the moment holds these back; a later run asks again",
        )
    if not listing.installable:
        return ()
    if not (on_terminal() if tty is None else tty):
        run.item(
            "firmware-available",
            devices=[_describe(device) for device in listing.installable],
            run="dotsteward upgrade --accept firmware",
            message="firmware is applied only from a terminal",
        )
        return ()
    if accepted:
        return listing.installable
    approved = tuple(
        device
        for device in listing.installable
        if ask(f"Firmware {device.name}: {device.current} -> {device.new}. Apply? [y/N]")
    )
    declined = [device for device in listing.installable if device not in approved]
    if declined:
        run.item("firmware-available", pending=False, devices=[_describe(device) for device in declined], declined=True)
    return approved


def _reads(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def on_mains_power() -> bool:
    """Mains online, or no battery of the machine at all; the battery of a wireless mouse does not
    count (DOTSTEWARD_SYSTEM_ROOT stands in for / in tests)."""
    root = Path(os.environ.get("DOTSTEWARD_SYSTEM_ROOT") or "/") / "sys/class/power_supply"
    types: list[str] = []
    try:
        supplies = sorted(root.iterdir())
    except OSError:
        return True
    for supply in supplies:
        try:
            kind = (supply / "type").read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if kind == "Battery" and _reads(supply / "scope") == "Device":
            continue
        types.append(kind)
        if kind == "Mains":
            try:
                if (supply / "online").read_text(encoding="utf-8").strip() == "1":
                    return True
            except OSError:
                continue
    return "Battery" not in types


def apply(devices: Sequence[Device], run: report.RunReport) -> None:
    """Updates the approved devices in a sudo window of its own, which it closes again. Call it at
    the end of a run, with the terminal free: sudo may ask for the password here."""
    if not devices:
        return
    if not on_mains_power():
        run.item(
            "firmware-needs-ac",
            devices=[_describe(device) for device in devices],
            run="dotsteward upgrade --accept firmware",
            message="firmware is applied on mains power only",
        )
        run.step("firmware", report.PENDING, detail="not on mains power")
        return
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        run.item("sudo-required", run="dotsteward upgrade --accept firmware", message="sudo did not open")
        run.step("firmware", report.PENDING, detail="no sudo")
        return
    failed = []
    needs_reboot = []
    applied = []
    left: Sequence[Device] = ()
    try:
        for index, device in enumerate(devices):
            argv = ["sudo", "-n", _TOOL, "update", device.device_id, "--assume-yes", "--no-reboot-check"]
            result = procs.run_protected(argv)
            if result.returncode != 0:
                failed.append(device)
            else:
                applied.append(device.device_id)
                if device.needs_reboot:
                    needs_reboot.append(device)
            if result.interrupted:
                # Ctrl-C takes the word back: the update at work ends, the next one does not start.
                run.mark_interrupted(result.interrupted)
                left = devices[index + 1 :]
                break
    finally:
        subprocess.run(["sudo", "-k"], check=False)
    if left:
        run.item(
            "firmware-available",
            devices=[_describe(device) for device in left],
            run="dotsteward upgrade --accept firmware",
            message="interrupted: these were not written",
        )
    if needs_reboot:
        run.item(
            "firmware-needs-reboot",
            pending=False,
            devices=[_describe(device) for device in needs_reboot],
            message="the update finishes at the next reboot; nothing reboots by itself",
        )
    if failed:
        names = ", ".join(device.name for device in failed)
        run.step("firmware", report.FAILED, detail=f"fwupdmgr failed for {names}")
    else:
        run.step("firmware", report.OK, applied=applied)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dotsteward_cli.firmware", description="Firmware, for tests and by hand.")
    parser.add_argument("action", choices=["list", "run"])
    parser.add_argument(
        "--accept", action="store_true", help="answer the question in advance; a terminal stays required"
    )
    parser.add_argument("--report", metavar="COMMAND", default="firmware", help="the command of the run report")
    parser.add_argument("--state-root", help="the state root of the report")
    options = parser.parse_args(argv)
    root = options.state_root or config.discovered_state_root()
    run = report.RunReport(options.report, root)
    listing = list_updates()
    if listing.error:
        run.step("firmware-list", report.PARTIAL, detail=listing.error)
    if options.action == "list":
        print(json.dumps(listing.to_json(), indent=2, sort_keys=True))
        approve(listing, run, tty=False)
    else:
        apply(approve(listing, run, accepted=options.accept), run)
    run.write()
    return run.exit_code


if __name__ == "__main__":
    sys.exit(main())
