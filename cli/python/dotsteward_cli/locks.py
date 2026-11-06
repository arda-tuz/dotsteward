"""File locks, and the instance lock of the commands that change a machine.

``FileLock`` is an exclusive ``flock(2)`` of one file, with ``fcntl`` so that no
flock binary is needed (Linux and macOS). The kernel drops it when the holder
dies. Children never inherit it: a process a command leaves behind must not keep
every other command out. For that reason a lock file is never replaced or
removed: the lock lives on its inode.

``InstanceLock`` is ``<state>/instance.lock``, shared by ``apply``, ``upgrade``,
``bootstrap`` and ``observe``. ``acquire`` never queues: it takes the lock, or
fails at once with ``LockBusy`` naming the holder, or (with ``wait``) tries for
a while. With ``pending`` it leaves a marker in ``<state>/instance.pending/``
when the lock is busy, and the holder starts that command when it lets go.

    with instance_lock("upgrade", state_root=root):
        ...

The protocol of a marker. The contender writes it after a failed try and then
tries once more; the holder lets go first and reads the markers afterwards. So
either the holder was still there at the second try and will see the marker, or
the second try succeeds. Then whoever gets the marker first, by removing or by
renaming it, wins: a contender that finds it gone stands aside, since the holder
has started the request. So a request is lost by nothing but a crash in between,
and runs once. A request is at most one per name, and a run of a name answers the
request of that name made before it.

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
        if self._descriptor is not None:
            descriptor, self._descriptor = self._descriptor, None
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
    held: bool
    holder: Holder | None
    pending: list[str]


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


def _live_holder(path: Path) -> Holder | None:
    """The holder the lock file names, unless it died without letting go."""
    holder = _read_holder(path)
    return holder if holder is not None and procs.process_exists(holder.pid) else None


def lock_status(state_root: str | os.PathLike[str]) -> LockStatus:
    """Whether the instance lock is held, by whom, and the pending commands.
    Creates nothing. The answer can be stale at once: to act on a free lock,
    acquire it. Only a holder the file names is checked with a lock of the file,
    so that asking almost never disturbs a command that is about to take it."""
    root = Path(state_root)
    path = root / INSTANCE_LOCK_FILE
    holder = _live_holder(path)
    if holder is not None:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            holder = None
        except BlockingIOError:
            pass
        finally:
            os.close(descriptor)
    return LockStatus(holder is not None, holder, _pending_names(root))


def _warn(text: str) -> None:
    print(f"[dotsteward] WARNING: {text}", file=sys.stderr)


def _start_pending(state_root: Path, marker: Path) -> str | None:
    """Claims MARKER by renaming it, then starts its command as a process of its
    own, with the output of this run in a log next to the markers. The name, if
    it started."""
    name = marker.name.removesuffix(".json")
    claimed = marker.with_name(f".{marker.name}.{os.getpid()}.claimed")
    try:
        os.rename(marker, claimed)
    except OSError:  # another process claimed it
        return None
    try:
        with open(claimed, encoding="utf-8") as handle:
            request: Any = json.load(handle)
        if os.stat(claimed).st_uid != os.geteuid():
            raise ValueError("it belongs to another user")
        if not isinstance(request, dict):
            raise ValueError("it is not a request")
        argv = request.get("argv")
        if not (isinstance(argv, list) and argv and all(isinstance(word, str) and word for word in argv)):
            raise ValueError("it names no command")
        env = {**os.environ, **request.get("env", {})}
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
    except (OSError, ValueError, TypeError) as error:
        _warn(f"the pending command {name} did not start: {error}")
        return None
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(claimed)
    return name


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
        children."""
        token = secrets.token_hex(16)
        since = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        record = json.dumps({"name": self.name, "pid": os.getpid(), "since": since, "token": token}) + "\n"
        descriptor = self._lock.descriptor
        os.ftruncate(descriptor, 0)
        os.pwrite(descriptor, record.encode(), 0)
        self._previous_token = os.environ.get(HELD_VARIABLE)
        os.environ[HELD_VARIABLE] = token

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
        request = {"schema_version": _SCHEMA_VERSION, "name": self.name, "argv": list(argv), "cwd": os.getcwd()}
        if env:
            request["env"] = dict(env)
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
        PENDING_ENV added to the holder's environment; it has to ask for the
        lock itself."""
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
        os.ftruncate(self._lock.descriptor, 0)
        if self._previous_token is None:
            os.environ.pop(HELD_VARIABLE, None)
        else:
            os.environ[HELD_VARIABLE] = self._previous_token
        self._lock.release()
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
    """Holds the instance lock for the block (see InstanceLock.acquire). The
    state root is the one discovery finds when it is not given."""
    if state_root is None:
        from dotsteward_cli import config

        state_root = config.discovered_state_root()
    lock = InstanceLock(state_root, name)
    lock.acquire(pending=pending, pending_env=pending_env, wait=wait)
    try:
        yield lock
    finally:
        lock.release()
