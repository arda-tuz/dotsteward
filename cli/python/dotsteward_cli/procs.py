"""Child processes of a command that must stay until the child has ended.

``run_protected`` is for a child that must not be interrupted half way, such as
a package manager that holds half a transaction. It starts it in a process group
of its own, so Ctrl-C at the terminal does not reach it, and keeps SIGINT, SIGTERM
and SIGHUP in the parent until the child has ended. The caller writes "interrupted"
into its report. The child is in the background of the terminal: its standard
input is empty unless the caller gives one, and a read of the terminal fails
instead of stopping it, so a password prompt cannot hang the run. Ask for
credentials before. It writes to the terminal unless the caller gives other
streams, and when the terminal closes such a write fails: a child that stops on a
failed write stops half way. A child that has to finish writes to a file.

``run_attached`` is for a child under a lock: the child decides about Ctrl-C, and
the parent stays to let go of the lock.

The hot path of a hook loads this module for ``process_exists``, so what only a
child needs loads with the first child.
"""

from __future__ import annotations

import os

TYPE_CHECKING = False
if TYPE_CHECKING:
    import subprocess
    from collections.abc import Mapping, Sequence
    from typing import IO

# subprocess.DEVNULL, without loading subprocess for a default value.
DEVNULL = -3


def process_exists(pid: int) -> bool:
    """Whether a process with this id exists, whoever it belongs to. A number no
    process can have (a damaged record) is an answer too."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, OverflowError):
        return False
    except OSError:
        return True
    return True


def _status_of(returncode: int) -> int:
    """A status as a shell gives it: 128 + N after signal N."""
    return 128 - returncode if returncode < 0 else returncode


def run_attached(
    argv: Sequence[str], env: Mapping[str, str] | None = None, cwd: str | os.PathLike[str] | None = None
) -> int:
    """Runs ARGV in this process group with this terminal and returns its status.
    SIGINT from the terminal reaches the child by itself; SIGTERM and SIGHUP reach
    it through this process. A signal before the child exists waits for it. Raises
    the OSError of a command that cannot start."""
    import signal
    import subprocess

    child: subprocess.Popen[bytes] | None = None
    early: list[int] = []

    # A handler for SIGINT too, not SIG_IGN: exec resets a handler for the child,
    # SIG_IGN stays. The terminal has told a child that exists already.
    def forward(signum: int, frame: object) -> None:
        if child is None:
            early.append(signum)
        elif signum != signal.SIGINT:
            child.send_signal(signum)

    previous = {number: signal.signal(number, forward) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        child = subprocess.Popen(argv, env=env, cwd=cwd)
        for signum in early:
            child.send_signal(signum)
        returncode = child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return _status_of(returncode)


class ProtectedResult:
    """The status of the child (128 + N after signal N) and the names of the
    signals that reached the parent while it ran, in order, each once."""

    __slots__ = ("interrupted", "returncode")

    def __init__(self, returncode: int, interrupted: tuple[str, ...]) -> None:
        self.returncode = returncode
        self.interrupted = interrupted

    def __repr__(self) -> str:
        return f"ProtectedResult(returncode={self.returncode}, interrupted={self.interrupted})"


def run_protected(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike[str] | None = None,
    env: Mapping[str, str] | None = None,
    stdin: int | IO[bytes] | None = DEVNULL,
    stdout: int | IO[bytes] | None = None,
    stderr: int | IO[bytes] | None = None,
) -> ProtectedResult:
    """Runs ARGV to its end and returns its result; raises the OSError of a
    command that cannot start. STDOUT and STDERR are files or descriptors; nothing
    reads a pipe while it runs. Call it in the main thread."""
    import signal
    import subprocess

    received: list[str] = []

    def note(signum: int, frame: object) -> None:
        name = signal.Signals(signum).name
        if name not in received:
            received.append(name)

    previous = {number: signal.signal(number, note) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    # The child inherits these two: a background process that touches the terminal
    # gets an error rather than being stopped for good.
    previous.update({number: signal.signal(number, signal.SIG_IGN) for number in (signal.SIGTTIN, signal.SIGTTOU)})
    try:
        with subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=stdin, stdout=stdout, stderr=stderr, process_group=0
        ) as child:
            returncode = child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return ProtectedResult(_status_of(returncode), tuple(received))
