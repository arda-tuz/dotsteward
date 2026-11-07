"""The red path of the first release: ``<state>/holds.json``, local to this machine.

A hold says that a version of something went red here: the writer leaves that pin alone until
upstream has something newer, and the way out for a package is named. It is no intent, so nothing
of it enters the repository or the TOML. Later releases write holds to the machine layer.
"""

from __future__ import annotations

import datetime
import json
import os
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic

_FILE = "holds.json"
SCHEMA_VERSION = 1


def _path(state_root: str) -> Path:
    return Path(state_root) / _FILE


def read(state_root: str) -> list[dict[str, Any]]:
    try:
        document = json.loads(_path(state_root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    holds = document.get("holds") if isinstance(document, dict) else None
    return [hold for hold in holds if isinstance(hold, dict)] if isinstance(holds, list) else []


def write(state_root: str, holds: Iterable[Mapping[str, Any]]) -> None:
    text = json.dumps({"schema_version": SCHEMA_VERSION, "holds": list(holds)}, indent=2, sort_keys=True) + "\n"
    atomic.make_private_dirs(state_root)
    atomic.atomic_write(_path(state_root), text, mode=0o600)


def add(state_root: str, component: str, identifier: str, version: str, reason: str) -> None:
    """Records a hold, the same one once."""
    holds = read(state_root)
    if any(hold.get("id") == identifier and hold.get("version") == version for hold in holds):
        return
    since = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    holds.append({"component": component, "id": identifier, "version": version, "reason": reason, "since": since})
    write(state_root, holds)


def _latest_rows(latest: str | os.PathLike[str]) -> dict[str, str]:
    try:
        document = json.loads(Path(latest).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    rows = document.get("items") if isinstance(document, dict) else None
    found: dict[str, str] = {}
    for row in rows if isinstance(rows, list) else ():
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            found[row["id"]] = str(row.get("latest"))
    return found


def skip_patterns(state_root: str, latest: str | os.PathLike[str]) -> list[str]:
    """The pins the writer leaves alone. A hold of a version upstream no longer calls the newest
    is over: what comes now gets its own chance. A package holds until the person lets it go."""
    rows = _latest_rows(latest)
    kept, skips = [], []
    for hold in read(state_root):
        identifier = hold.get("id")
        if isinstance(identifier, str) and identifier in rows and rows[identifier] != hold.get("version"):
            continue
        kept.append(hold)
        if isinstance(identifier, str) and not identifier.startswith("apt:"):
            skips.append(identifier)
    if len(kept) != len(read(state_root)):
        write(state_root, kept)
    return skips
