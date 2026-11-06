"""Child processes of a command that must stay until the child has ended.

``run_protected`` is for a child that must not be interrupted half way, such as
a package manager that holds half a transaction. It starts it in a process group
of its own, so Ctrl-C at the terminal does not reach it, and keeps SIGINT, SIGTERM
and SIGHUP in the parent until the child has ended. The caller writes "interrupted"
into its report. The child is in the background of the terminal: its standard
input is empty unless the caller gives one, and a read of the terminal fails
instead of stopping it, so a password prompt cannot hang the run. Ask for
credentials before.

``run_attached`` is for a child under a lock: the child decides about Ctrl-C, and
the parent stays to let go of the lock.
"""

from __future__ import annotations

import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import IO


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


def _do_nothing(signum: int, frame: object) -> None:
    """A handler, not SIG_IGN: exec resets a handler for the child, SIG_IGN stays."""


def run_attached(argv: Sequence[str], env: Mapping[str, str] | None = None) -> int:
    """Runs ARGV in this process group with this terminal and returns its status.
    SIGINT from the terminal reaches the child by itself; SIGTERM and SIGHUP reach
    it through this process. Raises the OSError of a command that cannot start."""
    child: subprocess.Popen[bytes] | None = None

    def forward(signum: int, frame: object) -> None:
        if child is not None:
            child.send_signal(signum)

    previous = {
        signal.SIGINT: signal.signal(signal.SIGINT, _do_nothing),
        signal.SIGTERM: signal.signal(signal.SIGTERM, forward),
        signal.SIGHUP: signal.signal(signal.SIGHUP, forward),
    }
    try:
        child = subprocess.Popen(argv, env=env)
        returncode = child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return _status_of(returncode)


@dataclass(frozen=True)
class ProtectedResult:
    """The status of the child (128 + N after signal N) and the names of the
    signals that reached the parent while it ran, in order, each once."""

    returncode: int
    interrupted: tuple[str, ...]


def run_protected(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike[str] | None = None,
    env: Mapping[str, str] | None = None,
    stdin: int | IO[bytes] | None = subprocess.DEVNULL,
) -> ProtectedResult:
    """Runs ARGV to its end and returns its result; raises the OSError of a
    command that cannot start. Call it in the main thread."""
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
        with subprocess.Popen(argv, cwd=cwd, env=env, stdin=stdin, process_group=0) as child:
            returncode = child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return ProtectedResult(_status_of(returncode), tuple(received))
