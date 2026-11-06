"""Run reports and ``review.json`` (docs/exit-codes.md).

A command with many steps collects what happened in a ``RunReport``. Its exit code
is the heaviest outcome of the run, in the order 4, 1, 3, 6, 0. ``write`` leaves
the report in ``<state>/runs/<command>/<run>.json``, for the next run and for a
person, and the items that need a person or an agent in ``<state>/review.json``.
Both stay on the machine, since they can name packages of the system; they are
never published. ``review.json`` belongs to the last run of a command with items,
and the next run of that command without any removes it: every run works out
again what is left to do.

    run = RunReport("upgrade", state_root)
    run.step("fetch", PARTIAL, detail="offline")
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

from dotsteward_cli import atomic

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
REVIEW_FILE = "review.json"


def _check_code(code: int) -> int:
    if code not in _STATUS:
        raise ValueError(f"not an outcome: {code}")
    return code


def combine(codes: Iterable[int]) -> int:
    """The heaviest outcome of CODES, 0 for none. Raises ValueError for a code
    that is no outcome (2 is a usage error, 5 means something else in contribute)."""
    seen = {_check_code(code) for code in codes}
    return next((code for code in _PRECEDENCE if code in seen), OK)


def status_name(code: int) -> str:
    return _STATUS[_check_code(code)]


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
        """A step of the run and its outcome; DETAILS go into the report."""
        self._codes.append(_check_code(code))
        self.steps.append({"name": name, "status": status_name(code), **details})

    def item(self, code: str, *, pending: bool = True, **fields: Any) -> None:
        """An entry of review.json. PENDING: the run waits for a decision or a
        sudo step (exit 3 unless something heavier holds); without it the item is
        a note for whoever reads the review. FIELDS tell what is needed."""
        if not (isinstance(code, str) and _ITEM_CODE.fullmatch(code)):
            raise ValueError(f"invalid item code: {code!r}")
        if pending:
            self._codes.append(PENDING)
        self.items.append({"code": code, **fields})

    def mark_interrupted(self, signals: Sequence[str]) -> None:
        """A signal arrived (procs.run_protected names them)."""
        self.interrupted = tuple(signals)

    @property
    def exit_code(self) -> int:
        return combine(self._codes)

    @property
    def status(self) -> str:
        return status_name(self.exit_code)

    def _review(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "run": self.run,
            "command": self.command,
            "status": self.status,
            "exit_code": self.exit_code,
            "items": self.items,
        }

    def _report(self) -> dict[str, Any]:
        document = {**self._review(), "started_at": self.started_at, "finished_at": _stamp(_now())}
        document["steps"] = self.steps
        if self.data:
            document["data"] = self.data
        if self.interrupted:
            document["interrupted"] = list(self.interrupted)
        return document

    def write(self) -> ReportPaths:
        """Writes the report and the review of this run, each atomically."""
        directory = self.state_root / _RUNS_DIRECTORY / self.command
        atomic.make_private_dirs(directory)
        report_path = directory / f"{self.run}.json"
        atomic.atomic_write_json(report_path, self._report(), mode=0o600)
        for old in sorted(path for path in directory.glob("*.json"))[:-KEEP_REPORTS]:
            old.unlink(missing_ok=True)
        review_path = self.state_root / REVIEW_FILE
        if self.items:
            atomic.atomic_write_json(review_path, self._review(), mode=0o600)
            return ReportPaths(report_path, review_path)
        current = load_review(self.state_root)
        if current is not None and current.get("command") == self.command:
            review_path.unlink(missing_ok=True)
        return ReportPaths(report_path, None)


def _read_document(path: Path) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return None
    return document if isinstance(document, dict) else None


def load_review(state_root: str | os.PathLike[str]) -> dict[str, Any] | None:
    """The current review.json, None when there is none or it cannot be read."""
    return _read_document(Path(state_root) / REVIEW_FILE)


def load_last(state_root: str | os.PathLike[str], command: str) -> dict[str, Any] | None:
    """The newest readable report of COMMAND, None without one."""
    directory = Path(state_root) / _RUNS_DIRECTORY / command
    for path in sorted(directory.glob("*.json"), reverse=True):
        document = _read_document(path)
        if document is not None:
            return document
    return None
