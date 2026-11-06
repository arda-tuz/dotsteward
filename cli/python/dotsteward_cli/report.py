"""Run reports and ``review.json`` (docs/exit-codes.md).

A command with many steps collects what happened in a ``RunReport``. Its exit code
is the heaviest outcome of the run, in the order 4, 1, 3, 6, 0. ``write`` leaves
the report in ``<state>/runs/<command>/<run>.json``, for the next run and for a
person, and the items that need a person or an agent in ``<state>/review.json``.
Both stay on the machine, since they can name packages of the system; they are
never published.

``review.json`` is one file for every command, so that a run started by the end of
another does not hide what that one left. A run replaces the items of its own
command and leaves the others; the last item gone removes the file. Every run works
out again what is left to do, so this is all it takes to stay current.

Reports are ordered by a sequence number in each report, not by the clock or the
name of the run: a clock that is behind must not make a new report look old.

    run = RunReport("upgrade", state_root)
    run.step("fetch", PARTIAL, detail="offline")
    run.step("rebuild", status_of_the_child)
    run.item("sudo-required", run="dotsteward upgrade")
    run.item("series-available", pending=False, series="example-2")
    run.write()
    return run.exit_code
"""

from __future__ import annotations

import datetime
import json
import os
import re
import secrets
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, locks

OK = 0
FAILED = 1
PENDING = 3
PRIVACY_STOP = 4
PARTIAL = 6

SCHEMA_VERSION = 1
# The newest reports of a command that stay.
KEEP_REPORTS = 20

_PRECEDENCE = (PRIVACY_STOP, FAILED, PENDING, PARTIAL, OK)
_STATUS = {OK: "ok", FAILED: "failed", PENDING: "pending", PRIVACY_STOP: "privacy-stop", PARTIAL: "partial"}
_COMMAND = re.compile(r"[a-z0-9][a-z0-9._-]*")
_RUN = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]*")
_ITEM_CODE = re.compile(r"[a-z0-9][a-z0-9-]*")
_RUNS_DIRECTORY = "runs"
_RUNS_LOCK = ".lock"
REVIEW_FILE = "review.json"
_REVIEW_LOCK = "review.lock"


def _check_code(code: int) -> int:
    if isinstance(code, bool) or code not in _STATUS:
        raise ValueError(f"not an outcome: {code}")
    return code


def combine(codes: Iterable[int]) -> int:
    """The heaviest outcome of CODES, 0 for none. Raises ValueError for a code
    that is no outcome (2 is a usage error, 5 means something else in contribute)."""
    seen = {_check_code(code) for code in codes}
    return next((code for code in _PRECEDENCE if code in seen), OK)


def status_name(code: int) -> str:
    return _STATUS[_check_code(code)]


def outcome_of(status: int) -> int:
    """The outcome of a child that exited with STATUS: 0, 3, 4 and 6 as they are,
    any other status (127, 137, the 2 of a usage error) failed."""
    if isinstance(status, bool) or not isinstance(status, int):
        raise ValueError(f"not an exit status: {status!r}")
    return status if status in _STATUS else FAILED


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.UTC)


def _stamp(moment: datetime.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class ReportPaths:
    report: Path
    review: Path | None


class RunReport:
    """What one run of COMMAND did; see the module documentation."""

    def __init__(self, command: str, state_root: str | os.PathLike[str], *, run: str | None = None) -> None:
        if not _COMMAND.fullmatch(command):
            raise ValueError(f"invalid command name: {command}")
        started = _now()
        self.command = command
        self.state_root = Path(state_root)
        self.run = run if run is not None else f"{started.strftime('%Y-%m-%dT%H%M%SZ')}-{secrets.token_hex(2)}"
        if not _RUN.fullmatch(self.run):
            raise ValueError(f"invalid run name: {self.run}")
        self.started_at = _stamp(started)
        self.steps: list[dict[str, Any]] = []
        self.items: list[dict[str, Any]] = []
        self.data: dict[str, Any] = {}
        self.interrupted: tuple[str, ...] = ()
        self._codes: list[int] = []

    def step(self, name: str, code: int = OK, **details: Any) -> None:
        """A step of the run and its outcome; DETAILS go into the report. CODE is an
        outcome or the status of a child, which outcome_of maps and the step keeps as
        exit_status. "status" is the report's own field."""
        if "status" in details:
            raise ValueError(f"step {name}: status is a field of the report")
        outcome = outcome_of(code)
        if outcome != code:
            details = {"exit_status": code, **details}
        self._codes.append(outcome)
        self.steps.append({"name": name, "status": status_name(outcome), **details})

    def item(self, code: str, *, pending: bool = True, **fields: Any) -> None:
        """An entry of review.json. PENDING: the run waits for a decision or a
        sudo step (exit 3 unless something heavier holds); without it the item is
        a note for whoever reads the review. FIELDS tell what is needed."""
        if not (isinstance(code, str) and _ITEM_CODE.fullmatch(code)):
            raise ValueError(f"invalid item code: {code!r}")
        if not isinstance(pending, bool):
            raise ValueError(f"item {code}: pending must be true or false, not {pending!r}")
        if "command" in fields:
            raise ValueError(f"item {code}: command is a field of the review")
        if pending:
            self._codes.append(PENDING)
        self.items.append({"code": code, **fields})

    def mark_interrupted(self, signals: Sequence[str]) -> None:
        """Signals arrived (procs.run_protected names them); they add up over a run."""
        self.interrupted += tuple(name for name in signals if name not in self.interrupted)

    @property
    def exit_code(self) -> int:
        return combine(self._codes)

    @property
    def status(self) -> str:
        return status_name(self.exit_code)

    def _report(self, sequence: int) -> dict[str, Any]:
        document: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "run": self.run,
            "command": self.command,
            "sequence": sequence,
            "status": self.status,
            "exit_code": self.exit_code,
            "started_at": self.started_at,
            "finished_at": _stamp(_now()),
            "steps": self.steps,
            "items": self.items,
        }
        if self.data:
            document["data"] = self.data
        if self.interrupted:
            document["interrupted"] = list(self.interrupted)
        return document

    def _write_report(self) -> Path:
        """The next number of this command, the report and the retention, one at a time."""
        directory = self.state_root / _RUNS_DIRECTORY / self.command
        atomic.make_private_dirs(self.state_root)
        atomic.make_private_dirs(directory.parent)
        atomic.make_private_dirs(directory)
        report_path = directory / f"{self.run}.json"
        lock = locks.FileLock(directory / _RUNS_LOCK)
        lock.acquire()
        try:
            known = _reports(directory)
            sequence = max((number for number, _, _ in known), default=0) + 1
            _write_document(report_path, self._report(sequence))
            kept = [entry for entry in known if entry[1] != report_path]
            for _, old, _ in kept[: max(len(kept) + 1 - KEEP_REPORTS, 0)]:
                old.unlink(missing_ok=True)
        finally:
            lock.release()
        return report_path

    def _update_review(self) -> Path | None:
        """Replaces the items of this command in review.json. The path, if it left any."""
        path = self.state_root / REVIEW_FILE
        lock = locks.FileLock(self.state_root / _REVIEW_LOCK)
        lock.acquire()
        try:
            current = load_review(self.state_root) or {}
            runs = current.get("runs")
            runs = {name: run for name, run in runs.items() if name != self.command} if isinstance(runs, dict) else {}
            items = current.get("items")
            items = [item for item in items if item.get("command") != self.command] if isinstance(items, list) else []
            if self.items:
                runs[self.command] = {"run": self.run, "status": self.status, "exit_code": self.exit_code}
                items += [{"command": self.command, **item} for item in self.items]
            if not items:
                path.unlink(missing_ok=True)
                return None
            code = combine(run["exit_code"] for run in runs.values())
            document = {
                "schema_version": SCHEMA_VERSION,
                "status": status_name(code),
                "exit_code": code,
                "runs": dict(sorted(runs.items())),
                "items": items,
            }
            _write_document(path, document)
        finally:
            lock.release()
        return path if self.items else None

    def write(self) -> ReportPaths:
        """Writes the report and updates the review, each atomically."""
        report_path = self._write_report()
        return ReportPaths(report_path, self._update_review())


def _read_document(path: Path) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return None
    return document if isinstance(document, dict) else None


def _write_document(path: Path, document: dict[str, Any]) -> None:
    """A value without a JSON form becomes its text, and text that is no valid Unicode
    (a file name, perhaps) an escape: neither loses a report at the end of a long run."""
    text = json.dumps(document, indent=2, ensure_ascii=False, default=str) + "\n"
    atomic.atomic_write(path, text.encode("utf-8", "backslashreplace"), mode=0o600)


def _reports(directory: Path) -> list[tuple[int, Path, dict[str, Any]]]:
    """(sequence, path, document) of the readable reports in DIRECTORY, oldest first;
    a report without a number, damaged for instance, counts as the oldest."""
    found = []
    for path in directory.glob("*.json"):
        document = _read_document(path) or {}
        number = document.get("sequence")
        found.append((number if type(number) is int else 0, path, document))
    return sorted(found, key=lambda entry: (entry[0], entry[1].name))


def load_review(state_root: str | os.PathLike[str]) -> dict[str, Any] | None:
    """The current review.json, None when there is none or it cannot be read."""
    return _read_document(Path(state_root) / REVIEW_FILE)


def load_last(state_root: str | os.PathLike[str], command: str) -> dict[str, Any] | None:
    """The last readable report of COMMAND, None without one."""
    directory = Path(state_root) / _RUNS_DIRECTORY / command
    for number, _, document in reversed(_reports(directory)):
        if number:
            return document
    return None
