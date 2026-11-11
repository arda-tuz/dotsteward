"""``dotsteward observe``: the system packages the owner changed outside dotsteward.

The systemd user path unit ``dotsteward-observe.path`` of the generation starts the service
``dotsteward-observe`` whenever dpkg writes ``/var/lib/dpkg/status``, whatever program drove
it (``apt-get upgrade`` in a terminal, unattended-upgrades, a software center); the service
also runs at login, since nothing watches while nobody is logged in.

1. Settle, without any lock, also on a machine without a name (one run per apt run, not one
   per write of the status file): no process holds a lock of the dpkg and apt lock files
   (``/proc/locks``, which every program's locks reach; on an anonymous device the inode
   alone), ``/var/lib/dpkg/updates`` is empty, ``dpkg --audit`` is clean, and nothing was
   busy for ``--settle-seconds``. While a lock is held it waits without a limit; after
   ``--wait-limit`` seconds of the other signs it observes nothing: the next change of the
   status file starts it again. A machine without a name stops here.
2. The instance lock, without waiting: when another command holds it, a pending mark makes
   the holder start the observer when it lets go (exit 3).
3. The installed packages against the last observation (``<state>/observe/dpkg-snapshot.json``).
   The first run takes them as the baseline: no check, no notification.
4. The tracked deb components whose packages changed, or whose dependency closure
   (``Pre-Depends`` and ``Depends`` of the installed packages, every alternative, the
   providers of a virtual package) holds a changed package, and those that were red, get
   their E2E checks alone (``e2e --component``, which writes no record of E2E), when the
   active generation has them; the full set stays with ``upgrade`` and ``apply``, and a full
   ``e2e`` records its verdict on them too. When dpkg moved during the checks the verdict is
   dropped (no red, no notification) and it settles again. A red version gets one desktop
   notification; its last verified version stays apart from the installed one. The observer
   never installs, removes, holds or downgrades a package: what the owner installed stays.
5. The snapshot, then the record of the state writer on this machine
   (``recorded_by: observe``); the lock is let go and the record is pushed. When the status
   file moved meanwhile, it goes round again.

Exit status: 0 done (a red component too, nothing to observe, dpkg did not settle), 1 a
refusal or a check that could not run, 2 usage error, 3 the instance lock is busy and the
observer runs when it is free, 4 the record breaks its schema or the privacy scan found
something, 6 no network or no login (the record waits; the next run sends it).

``DOTSTEWARD_SYSTEM_ROOT`` stands in for ``/`` for the files it reads (tests).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, host, locks, machine, report
from dotsteward_cli import state as states

EXIT_REFUSAL = 1
EXIT_USAGE = 2
EXIT_PENDING = 3
EXIT_PRIVACY = report.PRIVACY_STOP
EXIT_OFFLINE = report.PARTIAL

STATUS_FILE = "/var/lib/dpkg/status"
UPDATES_DIRECTORY = "/var/lib/dpkg/updates"
LOCK_FILES = (
    "/var/lib/dpkg/lock-frontend",
    "/var/lib/dpkg/lock",
    "/var/lib/apt/lists/lock",
    "/var/cache/apt/archives/lock",
)
PROC_LOCKS = "/proc/locks"
SNAPSHOT_FILE = "dpkg-snapshot.json"
SETTLE_SECONDS = 15.0
WAIT_LIMIT_SECONDS = 1800.0
_POLL_SECONDS = 1.0
_SCHEMA_VERSION = 1
# The device (major:minor, hex) and inode of a lock in /proc/locks.
_LOCK_ID = re.compile(r"([0-9a-f]+):([0-9a-f]+):([0-9]+)", re.ASCII)
_NAME = re.compile(r"[a-z0-9][a-z0-9+.-]*", re.ASCII)
_FIELDS = ("${binary:Package}", "${Package}", "${db:Status-Status}", "${Version}")
_RELATIONS = ("${Provides}", "${Pre-Depends}", "${Depends}")
# What a pending run keeps besides what every pending command keeps.
_PENDING_KEPT = ("DOTSTEWARD_SYSTEM_ROOT", "DOTSTEWARD_OS_RELEASE")


class NotSettled(Exception):
    """dpkg did not settle within the wait limit: what kept it busy."""


class CheckError(Exception):
    """The E2E checks of the components could not run: exit status 1."""


def _say(message: str) -> None:
    print(f"[dotsteward] {message}", flush=True)


def _warn(message: str) -> None:
    print(f"[dotsteward] {message}", file=sys.stderr, flush=True)


def _error(message: str) -> None:
    print(f"[dotsteward] ERROR: {message}", file=sys.stderr, flush=True)


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _system(env: Mapping[str, str], path: str) -> Path:
    return Path(env.get("DOTSTEWARD_SYSTEM_ROOT") or "/") / path.lstrip("/")


# --- Settling ------------------------------------------------------------------------------------


def _stamp(path: Path) -> tuple[int, int, int] | None:
    try:
        found = os.stat(path)
    except FileNotFoundError:
        return None
    return found.st_ino, found.st_size, found.st_mtime_ns


def _held_locks(env: Mapping[str, str]) -> set[tuple[int, int, int]]:
    """(major, minor, inode) of every lock /proc/locks lists, its waiters ("->") too."""
    try:
        text = _system(env, PROC_LOCKS).read_text(encoding="ascii", errors="replace")
    except OSError:
        return set()
    held = set()
    for line in text.splitlines():
        for word in line.split():
            matched = _LOCK_ID.fullmatch(word)
            if matched:
                held.add((int(matched.group(1), 16), int(matched.group(2), 16), int(matched.group(3))))
                break
    return held


def _locked(found: os.stat_result, held: set[tuple[int, int, int]]) -> bool:
    """Whether /proc/locks lists a lock of the file whose stat is FOUND. On an anonymous
    device (major 0: btrfs subvolumes, tmpfs) /proc/locks names the device of the superblock,
    stat another one: there the inode matches alone."""
    major, minor, inode = os.major(found.st_dev), os.minor(found.st_dev), found.st_ino
    if (major, minor, inode) in held:
        return True
    return major == 0 and any(lock_major == 0 and lock_inode == inode for lock_major, _, lock_inode in held)


def _busy(env: Mapping[str, str]) -> tuple[str | None, bool]:
    """What says that dpkg or apt is at work now (None when nothing does), and whether it is
    a lock some process holds."""
    held = _held_locks(env)
    for lock in LOCK_FILES:
        try:
            found = os.stat(_system(env, lock))
        except OSError:
            continue
        if _locked(found, held):
            return f"{lock} is locked", True
    try:
        with os.scandir(_system(env, UPDATES_DIRECTORY)) as entries:
            if any(True for _ in entries):
                return f"{UPDATES_DIRECTORY} holds unfinished work", False
    except FileNotFoundError:
        pass
    audit = subprocess.run(["dpkg", "--audit"], capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
    if audit.returncode != 0 or audit.stdout.strip():
        return "dpkg --audit reports a problem", False
    return None, False


def settle(env: Mapping[str, str], *, settle_seconds: float, wait_limit: float) -> tuple[int, int, int] | None:
    """Waits until dpkg settled: the stamp of the status file then. Quiet counts from the last
    moment dpkg was seen at work; an old status file counts as quiet only when nothing was
    busy. While a lock is held it waits without a limit (its holder is alive, and no later
    write of the status file may come to start the observer again); the wait limit bounds
    the other signs. Raises NotSettled."""
    status = _system(env, STATUS_FILE)
    deadline = time.monotonic() + wait_limit
    stamp = _stamp(status)
    since = time.monotonic()
    busy_seen = False
    while True:
        reason, locked = _busy(env)
        current = _stamp(status)
        if reason is not None:
            since, busy_seen = time.monotonic(), True
        if current != stamp:
            stamp, since, busy_seen = current, time.monotonic(), True
            reason = reason or "the dpkg status file keeps changing"
        if reason is None:
            quiet = time.monotonic() - since
            if current is not None and not busy_seen:
                quiet = max(quiet, time.time() - current[2] / 1e9)
            if quiet >= settle_seconds:
                return stamp
            reason = f"the dpkg status file changed less than {settle_seconds:g} s ago"
        remaining = deadline - time.monotonic()
        if remaining <= 0 and not locked:
            raise NotSettled(reason)
        time.sleep(_POLL_SECONDS if locked else min(_POLL_SECONDS, max(remaining, 0.0)))


def _moved(env: Mapping[str, str], stamp: tuple[int, int, int] | None) -> bool:
    """Whether dpkg is at work again or wrote its status file since STAMP."""
    return _busy(env)[0] is not None or _stamp(_system(env, STATUS_FILE)) != stamp


# --- The installed packages -------------------------------------------------------------------------


def _names(relation: str) -> list[list[str]]:
    """The groups of a relation field, each the names of its alternatives (a | b), without
    versions and architecture qualifiers."""
    groups = []
    for group in relation.split(","):
        names = []
        for alternative in group.split("|"):
            matched = _NAME.match(alternative.strip())
            if matched:
                names.append(matched.group(0))
        if names:
            groups.append(names)
    return groups


def installed() -> dict[str, dict[str, Any]]:
    """Every installed package as dpkg has it, by its binary:Package: name, version, the
    names it provides and the groups of its Pre-Depends and Depends."""
    done = subprocess.run(
        ["dpkg-query", "-W", "-f", "\t".join(_FIELDS + _RELATIONS) + "\n"],
        capture_output=True,
        text=True,
        check=False,
        stdin=subprocess.DEVNULL,
    )
    if done.returncode != 0:
        raise states.Refusal(f"dpkg-query failed: {done.stderr.strip()}")
    found = {}
    for line in done.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != len(_FIELDS) + len(_RELATIONS):
            continue
        key, name, status_, version, provides, pre_depends, depends = parts
        # As `state record` reads them: a package dpkg has not finished is not installed.
        if status_ != "installed" or not version or not key:
            continue
        found[key] = {
            "name": name or key.partition(":")[0],
            "version": version,
            "provides": [names[0] for names in _names(provides)],
            "depends": _names(pre_depends) + _names(depends),
        }
    return found


def _versions(packages: Mapping[str, Mapping[str, Any]]) -> dict[str, str]:
    return {key: str(entry["version"]) for key, entry in sorted(packages.items())}


def _snapshot_path(state: str) -> Path:
    return Path(state) / "observe" / SNAPSHOT_FILE


def read_snapshot(state: str) -> dict[str, str] | None:
    """The packages of the last observation, None before the first."""
    try:
        document = json.loads(_snapshot_path(state).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict) or document.get("schema_version") != _SCHEMA_VERSION:
        return None
    packages = document.get("packages")
    if not isinstance(packages, dict):
        return None
    return {str(key): str(version) for key, version in packages.items()}


def write_snapshot(state: str, versions: Mapping[str, str]) -> None:
    atomic.make_private_dirs(Path(state) / "observe")
    atomic.atomic_write_json(
        _snapshot_path(state),
        {"schema_version": _SCHEMA_VERSION, "recorded_at": _now(), "packages": dict(versions)},
        mode=0o600,
    )


def refresh_snapshot(state: str) -> None:
    """The installed packages become the last observation: for a command that changed them
    itself and checked what it changed, so that the observer it woke has nothing to do."""
    write_snapshot(state, _versions(installed()))


def changed_names(before: Mapping[str, str], after: Mapping[str, str]) -> set[str]:
    """The names of the packages installed, removed or moved to another version."""
    keys = {key for key in {*before, *after} if before.get(key) != after.get(key)}
    return {key.partition(":")[0] for key in keys}


def closure(packages: Mapping[str, Mapping[str, Any]], roots: Iterable[str]) -> set[str]:
    """The names ROOTS reach through Pre-Depends and Depends of the installed packages, every
    alternative and every provider of a virtual name included, and the names no installed
    package has."""
    by_name: dict[str, list[Mapping[str, Any]]] = {}
    for entry in packages.values():
        by_name.setdefault(str(entry["name"]), []).append(entry)
        for provided in entry["provides"]:
            by_name.setdefault(str(provided), []).append(entry)
    reached: set[str] = set()
    waiting = list(roots)
    while waiting:
        name = waiting.pop()
        if name in reached:
            continue
        reached.add(name)
        for entry in by_name.get(name, ()):
            reached.add(str(entry["name"]))
            for group in entry["depends"]:
                waiting.extend(group)
    return reached


# --- Checking the components ---------------------------------------------------------------------------


def _component_versions(packages: Mapping[str, Mapping[str, Any]], wanted: Sequence[str]) -> dict[str, str]:
    found: dict[str, str] = {}
    for _, entry in sorted(packages.items()):
        name = str(entry["name"])
        if name in wanted and name not in found:
            found[name] = str(entry["version"])
    return dict(sorted(found.items()))


def _e2e(
    instance: config.Instance, profile: str, names: Sequence[str], *flags: str
) -> subprocess.CompletedProcess[str]:
    argv = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(instance.root), "e2e"]
    argv += ["--profile", profile, "--json", *flags]
    for name in names:
        argv += ["--component", name]
    return subprocess.run(argv, capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)


def _no_result(names: Sequence[str], done: subprocess.CompletedProcess[str]) -> CheckError:
    detail = (done.stderr.strip().splitlines() or [f"exit {done.returncode}"])[-1]
    return CheckError(f"the E2E checks of {', '.join(names)} gave no result: {detail}")


def _generation(instance: config.Instance, profile: str) -> tuple[set[str], set[str]]:
    """(the components the active generation has, those of them with E2E checks): what
    `e2e --list --json` of the profile says. Raises CheckError."""
    done = _e2e(instance, profile, (), "--list")
    try:
        listed = json.loads(done.stdout)
        components = {str(name) for name in listed["components"]}
        checks = {str(check).partition(":")[0] for check in listed["checks"]}
    except (ValueError, KeyError, TypeError):
        raise _no_result(["the profile"], done) from None
    return components, checks & components


def _check(instance: config.Instance, profile: str, names: Sequence[str]) -> tuple[set[str], list[str]]:
    """Runs the E2E checks of NAMES alone: (the names whose checks failed, the messages of
    their findings). Raises CheckError when no result came."""
    done = _e2e(instance, profile, names, "--keep-going")
    try:
        result = json.loads(done.stdout)
        findings = result.get("findings") or []
    except (ValueError, AttributeError):
        result, findings = None, []
    if done.returncode == 0 and isinstance(result, dict) and result.get("result") == "passed":
        return set(), []
    failed = set()
    messages = []
    for finding in findings if isinstance(findings, list) else []:
        step = str(finding.get("step") or "") if isinstance(finding, dict) else ""
        component = step.partition(":")[0]
        if component in names:
            failed.add(component)
            messages.append(f"{step}: {finding.get('message')}")
    if not failed:
        raise _no_result(names, done)
    return failed, messages


def _notify(title: str, body: str) -> None:
    if shutil.which("notify-send") is None:
        _warn(f"no notify-send for the notification: {title}")
        return
    try:
        subprocess.run(
            ["notify-send", "--app-name=dotsteward", title, body],
            capture_output=True,
            check=False,
            stdin=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        _warn(f"the notification did not go out ({error}): {title}")


class Moved(Exception):
    """dpkg was at work again or wrote its status file during the checks: no verdict."""


def _verify(
    instance: config.Instance,
    env: Mapping[str, str],
    state: str,
    packages: Mapping[str, Mapping[str, Any]],
    changed: set[str],
    stamp: tuple[int, int, int] | None,
) -> bool:
    """Checks the tracked deb components that the change reached and those that were red,
    and remembers the results once the verdict stands: whether it checked any. Raises
    CheckError, Moved."""
    tracked = states.tracked_debs(instance, env)
    checks = states.read_checks(state)
    reached: dict[str, str] = {}
    for name, component in tracked.items():
        hit = closure(packages, component["packages"]) & changed
        if hit:
            reached[name] = f"changed: {', '.join(sorted(hit))}"
        elif checks.get(name, {}).get("result") == "fail":
            reached[name] = "red before"
    if not reached:
        if changed:
            _say("no tracked component depends on what changed")
        return False
    versions = {name: _component_versions(packages, tracked[name]["packages"]) for name in reached}
    missing = [name for name in reached if any(p not in versions[name] for p in tracked[name]["installs"])]
    for name in missing:
        _say(f"{name}: missing ({reached[name]})")
    checking = [name for name in reached if name not in missing]
    if not checking:
        return False
    profile = machine.machine_profile(instance, state, machine.current_name(machine.read_machine(state), env), env)
    if profile is None:
        raise CheckError("this machine has no profile to check its components with")
    active, with_checks = _generation(instance, profile)
    for name in checking:
        version = states.main_version(tracked[name]["installs"], versions[name])
        if name not in active:
            _say(f"{name}: not in the active generation yet; checked after the next rebuild")
        elif name not in with_checks:
            # Nothing verifies a component without checks: it stays as it was.
            _say(f"{name}: no E2E checks at {version} ({reached[name]})")
    checking = [name for name in checking if name in with_checks]
    if not checking:
        return False
    failed, messages = _check(instance, profile, checking)
    if _moved(env, stamp):
        raise Moved()
    for name in checking:
        version = states.main_version(tracked[name]["installs"], versions[name])
        before = checks.get(name, {})
        last = (before.get("last_verified") or {}).get("version")
        states.write_check(state, name, passed=name not in failed, packages=versions[name], version=version)
        if name not in failed:
            _say(f"{name}: verified at {version} ({reached[name]})")
            continue
        told = f"last verified {last}" if last else "never verified before"
        _say(f"{name}: red at {version}, {told} ({reached[name]})")
        for message in messages:
            if message.startswith(f"{name}:"):
                _say(f"  {message}")
        # The owner hears of a red version once.
        if before.get("result") == "fail" and before.get("version") == version:
            continue
        _notify(
            f"dotsteward: {name} is red",
            f"{name} {version} fails its checks after a package change ({told}). "
            "The installed version stays. Details: dotsteward state show",
        )
    return True


# --- One observation -------------------------------------------------------------------------------------


def _queued(instance: config.Instance, env: Mapping[str, str], name: str) -> bool:
    try:
        return bool(states.read(instance, name, env)["queued"])
    except states.Refusal:
        return False


def _observe_once(
    instance: config.Instance, env: Mapping[str, str], state: str, name: str, stamp: tuple[int, int, int] | None
) -> bool:
    """Compares, checks and records on this machine, under the instance lock: whether there
    is something to push. Raises Moved when dpkg moved during the checks."""
    packages = installed()
    versions = _versions(packages)
    before = read_snapshot(state)
    if before is None:
        _say("the first observation: the installed packages are the baseline")
        write_snapshot(state, versions)
        states.record(instance, env, by="observe", push_after=False)
        return True
    changed = changed_names(before, versions)
    if changed:
        count = len({key for key in {*before, *versions} if before.get(key) != versions.get(key)})
        _say(f"{count} package{'' if count == 1 else 's'} changed since the last observation")
    else:
        _say("no package changed since the last observation")
    try:
        checked = _verify(instance, env, state, packages, changed, stamp)
    except CheckError:
        # What is known is recorded; the change stays unobserved, so the next run checks it.
        states.record(instance, env, by="observe", push_after=False)
        raise
    if not changed and not checked:
        return _queued(instance, env, name)
    # The verdict stands: a refused record does not make the next trigger check it again.
    write_snapshot(state, versions)
    states.record(instance, env, by="observe", push_after=False)
    return True


def observe(
    instance: config.Instance,
    env: Mapping[str, str],
    *,
    settle_seconds: float = SETTLE_SECONDS,
    wait_limit: float = WAIT_LIMIT_SECONDS,
    pending: Sequence[str] | None = None,
) -> int:
    """One run of the observer: the exit status. PENDING is the command the holder of a busy
    instance lock starts when it lets go. The push of the state branch runs after the lock is
    let go. Raises Refusal, Finding, Busy, CheckError."""
    state = config.state_root(instance, env)
    if _stamp(_system(env, STATUS_FILE)) is None or shutil.which("dpkg-query") is None:
        _say(f"no dpkg on this machine ({STATUS_FILE}): nothing to observe")
        return 0
    try:
        name, _ = states.this_machine(instance, env)
    except states.Refusal as refusal:
        unnamed: states.Refusal | None = refusal
    else:
        unnamed = None
    while True:
        try:
            # Also without a name: one run per apt run, not one per write of the status file.
            stamp = settle(env, settle_seconds=settle_seconds, wait_limit=wait_limit)
        except NotSettled as busy:
            _say(
                f"dpkg did not settle within {wait_limit:g} s ({busy}): nothing was observed; "
                "the next change of the dpkg status file observes again"
            )
            return 0
        if unnamed is not None:
            _say(f"{unnamed}: nothing to observe")
            return 0
        kept = {key: env[key] for key in _PENDING_KEPT if key in env}
        try:
            with locks.instance_lock("observe", state_root=state, pending=pending, pending_env=kept):
                pushing = _observe_once(instance, env, state, name, stamp)
        except locks.LockBusy as busy:
            who = "another command" if busy.holder is None else busy.holder.name
            _warn(f"the instance lock is held by {who}; observe runs when it is free")
            return EXIT_PENDING
        except Moved:
            _say("dpkg changed during the checks: the verdict is dropped; observing again once it settles")
            continue
        code = states.push(instance, env) if pushing else 0
        if _stamp(_system(env, STATUS_FILE)) == stamp:
            return code
        _say("the dpkg status file changed meanwhile: observing again")


# --- Command line ----------------------------------------------------------------------------------------


def _seconds(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number of seconds: {text!r}") from None
    if not value >= 0:
        raise argparse.ArgumentTypeError(f"not a number of seconds: {text!r}")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward observe",
        description=(
            "Notices the system packages changed outside dotsteward (the path unit on the dpkg status file "
            "starts it): waits until dpkg and apt settled, compares the installed packages with the last "
            "observation, runs the E2E checks of the tracked deb components whose packages or dependency "
            "closure changed, records the state on the state branch of this machine and notifies the desktop "
            "of a red component. It never changes a package."
        ),
        epilog=(
            "Exit status: 0 done (a red component too), 1 a refusal or checks that gave no result, 2 usage "
            "error, 3 the instance lock is busy and the observer runs when it is free, 4 the record breaks its "
            "schema or the privacy scan found something, 6 no network or no login (the record waits)."
        ),
        allow_abbrev=False,
    )
    parser.add_argument(
        "--settle-seconds",
        type=_seconds,
        default=SETTLE_SECONDS,
        metavar="SECONDS",
        help=f"how long the dpkg status file must stay the same (default {SETTLE_SECONDS:g})",
    )
    parser.add_argument(
        "--wait-limit",
        type=_seconds,
        default=WAIT_LIMIT_SECONDS,
        metavar="SECONDS",
        help=f"how long to wait for dpkg and apt to settle (default {WAIT_LIMIT_SECONDS:g})",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    try:
        args = _parser().parse_args(arguments)
    except SystemExit as stop:
        return EXIT_USAGE if stop.code not in (0, None) else 0
    env = os.environ
    try:
        instance = config.load_instance()
        pending = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(instance.root), "observe"]
        pending += ["--settle-seconds", f"{args.settle_seconds:g}", "--wait-limit", f"{args.wait_limit:g}"]
        return observe(instance, env, settle_seconds=args.settle_seconds, wait_limit=args.wait_limit, pending=pending)
    except states.Finding as finding:
        _error(str(finding))
        return EXIT_PRIVACY
    except states.Busy as busy:
        _warn(str(busy))
        return EXIT_OFFLINE
    except (states.Refusal, host.Refusal, CheckError) as refusal:
        _error(str(refusal))
        return EXIT_REFUSAL
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return EXIT_REFUSAL
    except OSError as error:
        _error(str(error))
        return EXIT_REFUSAL
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
