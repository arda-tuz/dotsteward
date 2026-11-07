"""The channels nothing tracks: a read only look, and the update when the owner says so.

The framework knows the channels of the system (apt, snap, flatpak). Every other updater is a table
of ``[[upgrade.tools]]`` in the instance, and they are all treated alike. Everything runs as the user,
with a time limit per channel; a missing tool is ``available: false``, a failing one has ``error``,
and neither ends the run. Without a network the channels that ask one say ``skipped``. The result
stays in ``<state>/upgrade/analysis.json`` and is never published: it names packages of this machine.
Updating here enters nothing into the intent, the lock or the state.
"""

from __future__ import annotations

import datetime
import json
import shutil
import subprocess
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, procs

SCHEMA_VERSION = 1
_SECONDS = 60
_FILE = Path("upgrade") / "analysis.json"
_NOT_FOUND = 127
_MAX_NAMES = 3
SYSTEM_CHANNELS = ("apt", "snap", "flatpak")
# 128 + SIGINT, SIGTERM, SIGHUP.
_SIGNALLED = {130, 143, 129}


def _read(argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv), capture_output=True, text=True, timeout=_SECONDS, stdin=subprocess.DEVNULL, check=False
    )


def _channel(tool: str, offline: bool) -> dict[str, Any] | None:
    """The answer of a channel that has nothing to read: no tool, or no network."""
    if shutil.which(tool) is None:
        return {"available": False, "count": 0}
    if offline:
        return {"available": True, "count": 0, "skipped": "offline"}
    return None


def _guarded(read: Any, *args: Any) -> dict[str, Any]:
    try:
        result: dict[str, Any] = read(*args)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return {"available": True, "count": 0, "error": str(error)}
    return result


def _snap() -> dict[str, Any]:
    done = _read(["snap", "refresh", "--list"])
    if done.returncode != 0:
        return {"available": True, "count": 0, "error": done.stderr.strip()}
    rows = [line.split() for line in done.stdout.splitlines()[1:] if line.strip()]
    items = [{"name": row[0], "version": row[1] if len(row) > 1 else ""} for row in rows if row]
    return {"available": True, "count": len(items), "items": items}


def _flatpak() -> dict[str, Any]:
    items = []
    for scope in ("--user", "--system"):
        done = _read(["flatpak", "remote-ls", "--updates", "--columns=application,version,origin", scope])
        if done.returncode != 0:
            return {"available": True, "count": 0, "error": done.stderr.strip()}
        for line in done.stdout.splitlines():
            fields = line.split("\t")
            if fields and fields[0]:
                items.append(
                    {
                        "application": fields[0],
                        "version": fields[1] if len(fields) > 1 else "",
                        "origin": fields[2] if len(fields) > 2 else "",
                        "scope": scope.removeprefix("--"),
                    }
                )
    return {"available": True, "count": len(items), "items": items}


def _sh(command: str, *arguments: str, env: Mapping[str, str], cwd: Path) -> subprocess.CompletedProcess[str]:
    """COMMAND of a declaration through sh, in the checkout, with ARGUMENTS as ``"$@"``."""
    return subprocess.run(
        ["sh", "-c", command, "sh", *arguments],
        capture_output=True,
        text=True,
        timeout=_SECONDS,
        stdin=subprocess.DEVNULL,
        env=env,
        cwd=cwd,
        check=False,
    )


def _left_out(tool: Mapping[str, Any], name: str, tracked: set[str], env: Mapping[str, str], cwd: Path) -> str | None:
    """Why NAME stays out of the update. What nobody can say about stays out too: moving a tracked
    command by accident is the one thing this must not do."""
    command = tool.get("skip_providers")
    if command is None:
        return None
    try:
        done = _sh(str(command), name, env=env, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return "providers-unknown"
    if done.returncode != 0:
        return "providers-unknown"
    return "tracked-command" if set(done.stdout.split()) & tracked else None


def _read_tool(tool: Mapping[str, Any], tracked: set[str], env: Mapping[str, str], cwd: Path) -> dict[str, Any]:
    done = _sh(str(tool["check"]), env=env, cwd=cwd)
    if done.returncode == _NOT_FOUND:
        return {"available": False, "count": 0}
    if done.returncode != 0:
        return {"available": True, "count": 0, "error": done.stderr.strip() or f"exit {done.returncode}"}
    items: list[dict[str, str]] = []
    skipped: list[dict[str, str]] = []
    for line in done.stdout.splitlines():
        if not line.strip():
            continue
        name = line.split()[0]
        reason = _left_out(tool, name, tracked, env, cwd)
        if reason:
            skipped.append({"name": name, "reason": reason})
        else:
            items.append({"name": name, "line": line.strip()})
    return {"available": True, "count": len(items), "items": items, "skipped": skipped}


def read_user_channels(
    tools: Sequence[Mapping[str, Any]], tracked_commands: set[str], offline: bool, env: Mapping[str, str], cwd: Path
) -> dict[str, Any]:
    """Every channel but apt, which needs the engine: snap, flatpak and the declared tools."""
    channels: dict[str, Any] = {}
    for name, read in (("snap", _snap), ("flatpak", _flatpak)):
        channels[name] = _channel(name, offline) or _guarded(read)
    for tool in tools:
        if offline:
            channels[str(tool["name"])] = {"available": True, "count": 0, "skipped": "offline"}
        else:
            channels[str(tool["name"])] = _guarded(_read_tool, tool, tracked_commands, env, cwd)
    return channels


def store(state_root: str, channels: Mapping[str, Any]) -> Path:
    path = Path(state_root) / _FILE
    atomic.make_private_dirs(path.parent)
    at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    document = {"schema_version": SCHEMA_VERSION, "at": at, "channels": dict(channels)}
    atomic.atomic_write(path, json.dumps(document, indent=2, sort_keys=True) + "\n", mode=0o600)
    return path


def counts(channels: Mapping[str, Any]) -> dict[str, int]:
    return {name: int(channel.get("count", 0)) for name, channel in sorted(channels.items())}


def _names(items: Sequence[Mapping[str, Any]]) -> str:
    names = [str(item.get("name")) for item in items[:_MAX_NAMES]]
    return ", ".join(names) + (", ..." if len(items) > _MAX_NAMES else "")


def lines(channels: Mapping[str, Any]) -> list[str]:
    """One line per channel, for a person; ``--json`` has the rest."""
    said = []
    others = [name for name in channels if name not in SYSTEM_CHANNELS]
    for name in (*SYSTEM_CHANNELS, *others):
        channel = channels.get(name) or {}
        if channel.get("error"):
            said.append(f"{name}: could not be read: {channel['error']}")
        elif not channel.get("available"):
            said.append(f"{name}: not on this machine")
        elif channel.get("skipped") == "offline":
            said.append(f"{name}: skipped (offline)")
        elif name == "apt":
            packages = channel.get("packages") or []
            phased = sum(1 for package in packages if package.get("phased"))
            detail = f", {phased} phased" if phased else ""
            shown = f" ({_names(packages)})" if packages else ""
            count = channel.get("count", 0)
            said.append(f"apt {count} {'package' if count == 1 else 'packages'}{detail}{shown}")
        elif name in SYSTEM_CHANNELS:
            said.append(f"{name} {channel.get('count', 0)}")
        else:
            items = channel.get("items") or []
            left_out = channel.get("skipped") or []
            said.append(
                f"{name} {channel.get('count', 0)}"
                + (f" ({_names(items)})" if items else "")
                + (f" (left out, they provide tracked commands or may: {len(left_out)})" if left_out else "")
            )
    apt = channels.get("apt") or {}
    if apt.get("autoremovable"):
        said.append(f"apt autoremove could take {apt['autoremovable']}; this command never does that")
    if apt.get("boot_low"):
        said.append(f"/boot has only {apt.get('boot_free_mib')} MiB free; nothing is removed by this command")
    return said


def _run(argv: Sequence[str], env: Mapping[str, str] | None = None, cwd: Path | None = None) -> int:
    """The status of an update. A signal that ended it ends the run: no next channel starts."""
    try:
        status = procs.run_attached(list(argv), env=env, cwd=cwd)
    except OSError:
        return _NOT_FOUND
    if status in _SIGNALLED:
        raise KeyboardInterrupt
    return status


def update_user_channels(
    tools: Sequence[Mapping[str, Any]], tracked_commands: set[str], offline: bool, env: Mapping[str, str], cwd: Path
) -> list[tuple[str, int, str | None]]:
    """The updates of what runs as the user: channel, status and what went wrong, in the order of
    the declarations. Nothing is tracked by this. A tool with nothing to update does not run, one
    that cannot say what there is to update fails, and what provides a tracked command stays as it is."""
    statuses: list[tuple[str, int, str | None]] = []
    if offline:
        return statuses
    if shutil.which("flatpak"):
        statuses.append(("flatpak", _run(["flatpak", "update", "--user", "--noninteractive", "-y"]), None))
    for tool in tools:
        channel = f"tool:{tool['name']}"
        read = _guarded(_read_tool, tool, tracked_commands, env, cwd)
        names = [str(item["name"]) for item in read.get("items") or ()]
        if read.get("error"):
            statuses.append((channel, 1, f"could not be read: {read['error']}"))
        elif names:
            statuses.append((channel, _run(["sh", "-c", str(tool["update"]), "sh", *names], env, cwd), None))
    return statuses
