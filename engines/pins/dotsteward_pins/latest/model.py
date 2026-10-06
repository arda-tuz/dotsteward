"""Report rows, the status model and the report document.

A row (one JSON object of the report's ``items``)::

    {"id", "kind", "current", "latest", "status", "source", "details"}

Statuses: ``update`` (a newer version in the same major series),
``review`` (a newer major version, a moved channel series, changed watched
paths, a newer framework release), ``held`` (newer, but the pin declares a
holdback), ``manual`` (no automatic source), ``error`` (the upstream could
not be read or changed format), ``current`` and ``follows`` (the version is
derived from another pin). The first five need attention and sort first,
in that order; rows sort by id within a status group, ``current`` and
``follows`` rows together.

Report: ``{"schema_version": "1.0", "researched_at": "<UTC>Z", "items":
[...]}`` serialized like the lock files.
"""

from __future__ import annotations

import datetime
import re
from collections.abc import Iterable
from typing import Any

SCHEMA_VERSION = "1.0"
ATTENTION = ("update", "review", "held", "manual", "error")
ERROR_LIMIT = 300
LINE_LIMIT = 220
# A stable release tag: digits separated by dots, an optional leading v.
STABLE_TAG = re.compile(r"v?\d+(?:\.\d+)+")
# A version read from an upstream (stable or not): it must start like one.
VERSION_TEXT = re.compile(r"v?\d+(?:\.\d+)+(?:[-+~][0-9A-Za-z.+~-]*)?")

Row = dict[str, Any]


def version_key(value: Any) -> tuple[int, ...]:
    """The numeric parts of a version, compared as a tuple."""
    return tuple(int(part) for part in re.findall(r"\d+", str(value)))


def newest(versions: Iterable[str]) -> str | None:
    """The highest version, or None for an empty set."""
    candidates = list(versions)
    return max(candidates, key=version_key) if candidates else None


def classify(current: Any, latest: Any, held: bool = False) -> str:
    """The status of a version row: a newer major version (the minor one in
    0.x series) is a review, a newer one otherwise an update, unless held."""
    if latest is None:
        return "error"
    old, new = version_key(current), version_key(latest)
    if new <= old:
        return "current"
    if held:
        return "held"
    major = 1 if old and old[0] == 0 else 0
    if len(old) > major and len(new) > major and new[major] != old[major]:
        return "review"
    return "update"


def item(
    identifier: str,
    kind: str,
    current: Any,
    latest: Any = None,
    status: str | None = None,
    source: str = "",
    **details: Any,
) -> Row:
    """One report row; ``note`` is left out of the details when it is None."""
    if details.get("note") is None:
        details.pop("note", None)
    return {
        "id": identifier,
        "kind": kind,
        "current": current,
        "latest": latest,
        "status": status or classify(current, latest),
        "source": source,
        "details": details,
    }


def error_item(identifier: str, kind: str, message: str, current: Any = None, source: str = "", **details: Any) -> Row:
    """An error row; the message is cut to ERROR_LIMIT characters."""
    return item(identifier, kind, current, None, "error", source, error=message[:ERROR_LIMIT], **details)


def sort_key(row: Row) -> tuple[int, str]:
    status = row["status"]
    rank = ATTENTION.index(status) if status in ATTENTION else len(ATTENTION)
    return rank, row["id"]


def researched_at(now: datetime.datetime) -> str:
    return now.astimezone(datetime.UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def report(rows: list[Row], researched: str) -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "researched_at": researched, "items": rows}


def line(row: Row) -> str:
    """The human line of a row."""
    details = row["details"]
    note = details.get("error") or details.get("note") or ", ".join(details.get("changed_paths", [])[:4])
    text = f"{row['status']:8} {row['id']:44} {row['current']!s:>30} -> {row['latest']!s:<30} {note}"
    return text[:LINE_LIMIT]
