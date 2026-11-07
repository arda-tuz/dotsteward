"""The debounce of a capture: one sleeping process and a deadline file.

Arming writes ``now + delay`` to ``deadline`` and starts ``skills capture --wait``
detached. The first of those takes ``sleeper.lock``, the others end at once. The sleeper
reads the deadline on every wake, so a later write just moves it; it wakes at least every
30 seconds, and the wall clock counts, so a machine that slept fires on waking up. A
deadline that moved during the capture sends it back to sleep. A deadline is for the items
that are due by then: one that waits for a retry does not take a fresh one along, which
gets a deadline of its own. The end of a session runs a capture for what that session
wrote; everything else keeps its delay, because other sessions may still be writing. A
killed sleeper leaves pending.json and the deadline: the next hook starts another, which
runs at once when the time has passed.

No systemd and no flock binary, so this works on macOS as well.
"""

from __future__ import annotations

import contextlib
import math
import os
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from dotsteward_cli.skills import state

DEADLINE_FILE = "deadline"
DEADLINE_LOCK = "deadline.lock"
SLEEPER_LOCK = "sleeper.lock"
LOG_FILE = "capture.log"
_LONGEST_NAP_SECONDS = 30.0
_DEADLINE_LOCK_WAIT_SECONDS = 1.0
_LOG_LIMIT_BYTES = 256 * 1024
RETRY_REASONS = frozenset({"offline", "race", "checks-unavailable", "capture-failed"})


def delay_seconds(context: Mapping[str, Any]) -> float:
    """``DOTSTEWARD_CAPTURE_DELAY``, then ``[skills] capture_delay_seconds``."""
    for value in (os.environ.get("DOTSTEWARD_CAPTURE_DELAY"), context.get("capture_delay_seconds")):
        try:
            return max(0.0, float(value))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            continue
    return 600.0


def _deadline_path(state_root: str) -> str:
    return os.path.join(state.directory(state_root), DEADLINE_FILE)


def read_deadline(state_root: str) -> float | None:
    try:
        with open(_deadline_path(state_root), encoding="ascii") as handle:
            deadline = float(handle.read().strip())
    except (OSError, ValueError):
        return None
    return deadline if math.isfinite(deadline) else None


def _deadline_lock(state_root: str) -> Any:
    """Held while the deadline changes: a capture that ends clears the deadline it served,
    and a write that comes in at that moment must not lose its own."""
    from dotsteward_cli import atomic, locks

    atomic.make_private_dirs(state.directory(state_root))
    lock = locks.FileLock(os.path.join(state.directory(state_root), DEADLINE_LOCK))
    lock.try_acquire(wait=_DEADLINE_LOCK_WAIT_SECONDS)
    return lock


def write_deadline(state_root: str, when: float) -> None:
    from dotsteward_cli import atomic

    lock = _deadline_lock(state_root)
    try:
        atomic.atomic_write(_deadline_path(state_root), f"{when:.3f}\n", mode=0o600)
    finally:
        if lock.held:
            lock.release()


def clear_deadline(state_root: str, served: float) -> bool:
    """Removes the deadline when it is still SERVED; whether it did."""
    lock = _deadline_lock(state_root)
    try:
        if read_deadline(state_root) != served:
            return False
        with contextlib.suppress(OSError):
            os.unlink(_deadline_path(state_root))
        return True
    finally:
        if lock.held:
            lock.release()


def log(state_root: str, message: str) -> None:
    """One line of ``capture.log``: it stays small, and no failure reaches anyone."""
    path = os.path.join(state.directory(state_root), LOG_FILE)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with contextlib.suppress(OSError):
        state.append_log(path, f"{stamp} {message}", _LOG_LIMIT_BYTES)


def spawn(context: Mapping[str, Any], *arguments: str) -> None:
    """Starts ``skills ARGUMENT...`` detached from the session: it outlives the agent,
    and the agent never waits for its output."""
    import subprocess

    env = dict(os.environ)
    env["DOTSTEWARD_INSTANCE"] = str(context["instance"])
    env["DOTSTEWARD_STATE_ROOT"] = str(context["state_root"])
    subprocess.Popen(
        [sys.executable, "-s", "-P", "-m", "dotsteward_cli.skills.cli", *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        cwd="/",
        env=env,
    )


def arm(context: Mapping[str, Any]) -> None:
    """A write happened: the deadline moves, and a sleeper makes sure it is met."""
    state_root = str(context["state_root"])
    write_deadline(state_root, time.time() + delay_seconds(context))
    spawn(context, "capture", "--wait")


def sleeper_alive(state_root: str) -> bool:
    from dotsteward_cli import locks

    lock = locks.FileLock(os.path.join(state.directory(state_root), SLEEPER_LOCK))
    if lock.try_acquire():
        lock.release()
        return False
    return True


def resume(context: Mapping[str, Any], items: Sequence[Mapping[str, Any]]) -> None:
    """ITEMS wait for a capture: a sleeper must be on its way, also after one died, and
    a later change moves the deadline. A deadline that has passed stays: it runs at once."""
    state_root = str(context["state_root"])
    now = time.time()
    deadline = read_deadline(state_root)
    retries = any(item.get("reason") in RETRY_REASONS for item in items)
    wanted = max(float(item.get("detected_at") or 0) for item in items) + delay_seconds(context)
    if deadline is None:
        write_deadline(state_root, now if retries else max(now, wanted))
    elif not retries and deadline > now and wanted > deadline:
        write_deadline(state_root, wanted)
    if not sleeper_alive(state_root):
        spawn(context, "capture", "--wait")


def is_due(item: Mapping[str, Any], now: float, delay: float) -> bool:
    """Whether the sleeper takes this item now: it waited long enough, or it is a retry,
    an answer, or the end of the session that wrote it."""
    if item.get("answer") or item.get("due") or item.get("reason") in RETRY_REASONS:
        return True
    return float(item.get("detected_at") or 0) + delay <= now


def _next_deadline(context: Mapping[str, Any]) -> float | None:
    """When what still waits for its delay is due, None when nothing does."""
    now = time.time()
    delay = delay_seconds(context)
    later = [
        float(item.get("detected_at") or 0) + delay
        for item in state.load_pending(str(context["state_root"]))["items"].values()
        if isinstance(item, dict) and item.get("state") == "capture" and not is_due(item, now, delay)
    ]
    return max(later) if later else None


def wait(context: Mapping[str, Any], capture: Callable[[], int]) -> int:
    """The sleeping process: at most one per machine."""
    from dotsteward_cli import atomic, locks

    state_root = str(context["state_root"])
    atomic.make_private_dirs(state.directory(state_root))
    lock = locks.FileLock(os.path.join(state.directory(state_root), SLEEPER_LOCK))
    if not lock.try_acquire():
        return 0
    log(state_root, f"sleeper pid {os.getpid()}")
    log(state_root, "sleeper start")
    status = 0
    try:
        while True:
            deadline = read_deadline(state_root)
            if deadline is None:
                break
            remaining = deadline - time.time()
            if remaining > 0:
                time.sleep(min(remaining, _LONGEST_NAP_SECONDS))
                continue
            status = capture()
            if clear_deadline(state_root, deadline):
                later = _next_deadline(context)
                if later is None:
                    break
                write_deadline(state_root, later)
    finally:
        log(state_root, "sleeper end")
        lock.release()
    return status
