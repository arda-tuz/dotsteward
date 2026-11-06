"""File locks, and the instance lock of the commands that change a machine.

``FileLock`` is an exclusive ``flock(2)`` of one file, with ``fcntl`` so that no
flock binary is needed (Linux and macOS). The kernel drops it when the holder
dies. A child does not inherit it across exec: a process a command leaves behind
must not keep every other command out. A lock file is never replaced or removed:
the lock lives on its inode.

``InstanceLock`` is ``<state>/instance.lock``, shared by ``apply``, ``upgrade``,
``bootstrap`` and ``observe``. ``acquire`` never queues: it takes the lock, or
fails at once with ``LockBusy`` naming the holder, or (with ``wait``) tries for
a while. With ``pending`` it leaves a marker in ``<state>/instance.pending/``
when the lock is busy, and the holder starts that command when it lets go.
Without a holder to do that, the next one does.

    with instance_lock("upgrade", state_root=root):
        ...

A pending command runs with what ``pending_environment`` keeps from the command
that asked and with its ``pending_env``. Nothing of the holder's reaches it, and
the whole environment is never written to a marker, so no secret lands on disk.

The protocol of a marker. The contender writes it after a failed try and then
tries once more; the holder lets go first and reads the markers afterwards. So
either the holder was still there at the second try and will see the marker, or
the second try succeeds. Then whoever gets the marker first, by removing or by
renaming it, wins: a contender that finds it gone stands aside, since the holder
has started the request. A claimed marker goes back when the command could not
start for a passing reason, and the next holder takes back the marker of a claimer
that died. So a request runs once. A request is at most one per name, and a run of
a name answers the request of that name made before it.

Nesting. The holder puts a token into its environment and into the lock file. A
child that asks for the lock while its holder still holds it runs nested: it
gets no lock and starts nothing on release. A stale token opens nothing, since
the token must be the one in the lock file of a lock that is held. Other locks,
such as the gate's, nest inside; the order is always this lock first.
"""

from __future__ import annotations

import contextlib
import datetime
import fcntl
import json
import os
import re
import secrets
import subprocess
import sys
import time
from collections.abc import Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, procs

INSTANCE_LOCK_FILE = "instance.lock"
PENDING_DIRECTORY = "instance.pending"
HELD_VARIABLE = "DOTSTEWARD_INSTANCE_LOCK_HELD"
_SCHEMA_VERSION = 1
_HOLDER_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*")
_POLL_SECONDS = 0.01
# How long a busy lock whose holder has not named itself is tried again.
_UNNAMED_GRACE_SECONDS = 0.1
_RECORD_BYTES = 4096
# What a pending command keeps of the environment of the command that asked.
_PENDING_VARIABLES = frozenset(
    {
        "DBUS_SESSION_BUS_ADDRESS",
        "DISPLAY",
        "DOTFILES_ROOT",
        "DOTFILES_STATE_ROOT",
        "DOTSTEWARD_INSTANCE",
        "DOTSTEWARD_STATE_ROOT",
        "HOME",
        "LANG",
        "LANGUAGE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "SSH_AUTH_SOCK",
        "TMPDIR",
        "TZ",
        "USER",
        "WAYLAND_DISPLAY",
    }
)
_PENDING_PREFIXES = ("LC_", "XDG_")


class FileLock:
    """An exclusive lock of the file at PATH; see the module documentation."""

    def __init__(self, path: str | os.PathLike[str]) -> None:
        self.path = Path(path)
        self._descriptor: int | None = None

    @property
    def held(self) -> bool:
        return self._descriptor is not None

    @property
    def descriptor(self) -> int:
        if self._descriptor is None:
            raise ValueError(f"{self.path} is not held")
        return self._descriptor

    def _open(self) -> int:
        """Creates the file (0600) and missing directories (0700)."""
        if self.held:
            raise ValueError(f"{self.path} is already held")
        atomic.make_private_dirs(self.path.parent)
        return os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)

    def acquire(self) -> None:
        """Blocks until this object holds the lock."""
        descriptor = self._open()
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        self._descriptor = descriptor

    def try_acquire(self, wait: float = 0.0) -> bool:
        """True once this object holds the lock, False when another still does
        after WAIT seconds."""
        descriptor = self._open()
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    os.close(descriptor)
                    return False
                time.sleep(min(remaining, _POLL_SECONDS))
                continue
            self._descriptor = descriptor
            return True

    def release(self) -> None:
        """Lets go, also when a child forked without exec shares the open file."""
        if self._descriptor is not None:
            descriptor, self._descriptor = self._descriptor, None
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)


@dataclass(frozen=True)
class Holder:
    """Who holds the instance lock."""

    name: str
    pid: int
    since: str
    token: str = field(default="", repr=False)


@dataclass(frozen=True)
class LockStatus:
    """HOLDER is None when a held lock names nobody; PENDING_SINCE gives when each
    pending command asked, as far as its marker says."""

    held: bool
    holder: Holder | None
    pending: list[str]
    pending_since: dict[str, str]


class LockBusy(Exception):
    """Another command holds the lock. HOLDER is None when it has not named
    itself yet; PENDING_RECORDED says a marker for this command was left."""

    def __init__(self, holder: Holder | None, pending_recorded: bool) -> None:
        self.holder = holder
        self.pending_recorded = pending_recorded
        who = "unknown" if holder is None else f"{holder.name} (pid {holder.pid}, since {holder.since})"
        super().__init__(f"another command holds the instance lock: {who}")


def _read_holder(path: Path) -> Holder | None:
    try:
        with open(path, "rb") as handle:
            record = json.loads(handle.read(_RECORD_BYTES))
        return Holder(record["name"], int(record["pid"]), record["since"], record["token"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _pending_directory(state_root: Path) -> Path:
    return state_root / PENDING_DIRECTORY


def _pending_names(state_root: Path) -> list[str]:
    try:
        names = os.listdir(_pending_directory(state_root))
    except OSError:
        return []
    return sorted(name.removesuffix(".json") for name in names if name.endswith(".json"))


def _pending_since(state_root: Path, names: Sequence[str]) -> dict[str, str]:
    since = {}
    for name in names:
        try:
            with open(_pending_directory(state_root) / f"{name}.json", encoding="utf-8") as handle:
                created = json.load(handle)["created_at"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if isinstance(created, str):
            since[name] = created
    return since


def _live_holder(path: Path) -> Holder | None:
    """The holder the lock file names, unless it died without letting go."""
    holder = _read_holder(path)
    return holder if holder is not None and procs.process_exists(holder.pid) else None


def lock_status(state_root: str | os.PathLike[str]) -> LockStatus:
    """Whether the instance lock is held, by whom, and the pending commands.
    Creates nothing. The answer can be stale at once: to act on a free lock,
    acquire it. A file nobody can open raises the OSError. An empty file is not
    checked with a lock of the file, so that asking almost never disturbs a command
    that is about to take it."""
    root = Path(state_root)
    holder = None
    held = False
    try:
        descriptor = os.open(root / INSTANCE_LOCK_FILE, os.O_RDONLY | os.O_CLOEXEC)
    except FileNotFoundError:
        pass
    else:
        try:
            if os.fstat(descriptor).st_size > 0:
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            held = True
            holder = _read_holder(root / INSTANCE_LOCK_FILE)
        finally:
            os.close(descriptor)
    names = _pending_names(root)
    return LockStatus(held, holder, names, _pending_since(root, names))


def pending_environment(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """What a pending command keeps of ENV (the environment of this process):
    where it is, who runs it and how to reach the session. Everything that decides
    how a command behaves stays out, unless it is given as pending_env."""
    source = os.environ if env is None else env
    return {
        name: value
        for name, value in source.items()
        if name in _PENDING_VARIABLES or name.startswith(_PENDING_PREFIXES)
    }


def pending_log(state_root: str | os.PathLike[str], name: str) -> Path:
    """The file with the output of the last pending run of NAME."""
    return _pending_directory(Path(state_root)) / f"{name}.log"


def _warn(text: str) -> None:
    # The terminal of a holder may be gone by now.
    with contextlib.suppress(OSError):
        print(f"[dotsteward] WARNING: {text}", file=sys.stderr)


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _give_back(claimed: Path, marker: Path) -> None:
    """A claimed request is a request again, unless a newer one of its name came."""
    with contextlib.suppress(FileExistsError):
        os.link(claimed, marker)
    os.unlink(claimed)


def _recover_claimed(state_root: Path) -> None:
    """Gives back the requests of claimers that died before they started them."""
    directory = _pending_directory(state_root)
    with contextlib.suppress(OSError):
        for name in os.listdir(directory):
            if name.startswith(".") and name.endswith(".claimed"):
                marker, _, pid = name[1 : -len(".claimed")].rpartition(".")
                if marker.endswith(".json") and pid.isdecimal() and not procs.process_exists(int(pid)):
                    _give_back(directory / name, directory / marker)


def _start_request(state_root: Path, marker: Path, claimed: Path) -> None:
    """Starts the command of the CLAIMED request as a process of its own, with the
    output of this run in a log next to the markers."""
    with open(claimed, encoding="utf-8") as handle:
        request: Any = json.load(handle)
    if os.stat(claimed).st_uid != os.geteuid():
        raise ValueError("it belongs to another user")
    if not isinstance(request, dict):
        raise ValueError("it is not a request")
    argv = request.get("argv")
    if not (isinstance(argv, list) and argv and all(isinstance(word, str) and word for word in argv)):
        raise ValueError("it names no command")
    env = request.get("env", {})
    if not (isinstance(env, dict) and all(isinstance(value, str) for value in env.values())):
        raise ValueError("its environment is not a table of strings")
    env.pop(HELD_VARIABLE, None)
    directory = request.get("cwd")
    if not (isinstance(directory, str) and os.path.isdir(directory)):
        directory = str(state_root)
    log = os.open(marker.with_suffix(".log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o600)
    try:
        subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=directory,
            start_new_session=True,
        )
    finally:
        os.close(log)


def _start_pending(state_root: Path, marker: Path) -> str | None:
    """Claims MARKER by renaming it and starts its command; the name, if it started.
    A request that can never start is dropped with a warning. One that met a passing
    failure, such as a full disk or no more processes, stays for the next holder."""
    name = marker.name.removesuffix(".json")
    claimed = marker.with_name(f".{marker.name}.{os.getpid()}.claimed")
    try:
        os.rename(marker, claimed)
    except OSError:  # another process claimed it
        return None
    started = None
    try:
        _start_request(state_root, marker, claimed)
    except (FileNotFoundError, NotADirectoryError, PermissionError, ValueError, TypeError) as error:
        _warn(f"the pending command {name} did not start: {error}")
    except OSError as error:
        _warn(f"the pending command {name} did not start and stays for the next holder: {error}")
        with contextlib.suppress(OSError):
            _give_back(claimed, marker)
        return None
    else:
        started = name
    with contextlib.suppress(OSError):
        os.unlink(claimed)
    return started


class InstanceLock:
    """The lock of the instance on this machine; see the module documentation.
    NAME names the holder (a command name) in messages and in markers."""

    def __init__(self, state_root: str | os.PathLike[str], name: str) -> None:
        if not _HOLDER_NAME.fullmatch(name):
            raise ValueError(f"invalid lock holder name: {name}")
        self.state_root = Path(state_root)
        self.name = name
        self.nested = False
        self._lock = FileLock(self.state_root / INSTANCE_LOCK_FILE)
        self._previous_token: str | None = None

    @property
    def held(self) -> bool:
        return self.nested or self._lock.held

    def _marker(self) -> Path:
        return _pending_directory(self.state_root) / f"{self.name}.json"

    def _take(self) -> None:
        """The lock is this object's: names the holder and shares the token with
        children. When that fails, it lets go again."""
        token = secrets.token_hex(16)
        record = json.dumps({"name": self.name, "pid": os.getpid(), "since": _now(), "token": token}) + "\n"
        descriptor = self._lock.descriptor
        try:
            os.ftruncate(descriptor, 0)
            os.pwrite(descriptor, record.encode(), 0)
        except BaseException:
            self._lock.release()
            raise
        self._previous_token = os.environ.get(HELD_VARIABLE)
        os.environ[HELD_VARIABLE] = token
        _recover_claimed(self.state_root)

    def _answer_marker(self) -> bool:
        """Removes the request of this name. False when there is none (any more)."""
        try:
            self._marker().unlink()
        except FileNotFoundError:
            return False
        return True

    def _try_take(self) -> bool:
        """Takes a free lock. A busy lock whose holder has not named itself is
        tried again for a moment: that holder has only just got it or is gone
        already, or lock_status looked at the very moment."""
        taken = self._lock.try_acquire()
        if not taken and _live_holder(self._lock.path) is None:
            taken = self._lock.try_acquire(_UNNAMED_GRACE_SECONDS)
        if taken:
            self._take()
        return taken

    def _leave_marker(self, argv: Sequence[str], env: Mapping[str, str] | None) -> None:
        atomic.make_private_dirs(_pending_directory(self.state_root))
        request = {
            "schema_version": _SCHEMA_VERSION,
            "name": self.name,
            "argv": list(argv),
            "cwd": os.getcwd(),
            "created_at": _now(),
            "env": {**pending_environment(), **(env or {})},
        }
        atomic.atomic_write_json(self._marker(), request, mode=0o600)

    def acquire(
        self,
        *,
        pending: Sequence[str] | None = None,
        pending_env: Mapping[str, str] | None = None,
        wait: float = 0.0,
    ) -> None:
        """Takes the lock or runs nested in the holder that started this
        process; otherwise raises LockBusy. WAIT tries for that many seconds.
        PENDING is the command for the holder to start when it lets go, with
        pending_environment() and PENDING_ENV as its environment; it has to ask
        for the lock itself."""
        if self._try_take():
            self._answer_marker()
            return
        path = self._lock.path
        holder = _read_holder(path)
        if holder is not None and holder.token and os.environ.get(HELD_VARIABLE) == holder.token:
            self.nested = True
            return
        if wait > 0 and self._lock.try_acquire(wait):
            self._take()
            self._answer_marker()
            return
        if pending is None:
            raise LockBusy(_live_holder(path), False)
        self._leave_marker(pending, pending_env)
        if not self._try_take():
            raise LockBusy(_live_holder(path), True)
        if self._answer_marker():
            return
        # The holder that let go meanwhile has started this request.
        self.release()
        raise LockBusy(None, True)

    def release(self) -> list[str]:
        """Lets go, then starts the pending commands. The names it started."""
        if self.nested:
            self.nested = False
            return []
        if not self._lock.held:
            return []
        with contextlib.suppress(OSError):  # a stale record names a holder that lets go below
            os.ftruncate(self._lock.descriptor, 0)
        if self._previous_token is None:
            os.environ.pop(HELD_VARIABLE, None)
        else:
            os.environ[HELD_VARIABLE] = self._previous_token
        self._lock.release()
        _recover_claimed(self.state_root)
        directory = _pending_directory(self.state_root)
        started = []
        for name in _pending_names(self.state_root):
            command = _start_pending(self.state_root, directory / f"{name}.json")
            if command is not None:
                started.append(command)
        return started


@contextmanager
def instance_lock(
    name: str,
    *,
    state_root: str | os.PathLike[str] | None = None,
    pending: Sequence[str] | None = None,
    pending_env: Mapping[str, str] | None = None,
    wait: float = 0.0,
) -> Iterator[InstanceLock]:
    """Holds the instance lock for the block (see InstanceLock.acquire). Without
    STATE_ROOT it is config.required_state_root(), which raises DotstewardError
    outside an instance: two commands must not hold two locks."""
    if state_root is None:
        from dotsteward_cli import config

        state_root = config.required_state_root()
    lock = InstanceLock(state_root, name)
    lock.acquire(pending=pending, pending_env=pending_env, wait=wait)
    try:
        yield lock
    finally:
        lock.release()
