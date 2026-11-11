"""A shared lock that goes red on a machine that is not the producer (T19, docs/upgrade.md).

Only the producer moves the shared lock: the pins of ``versions.lock.json`` and ``flake.lock``. A
consumer takes a new lock when it follows the remote. When E2E goes red after that and the
generation of the commit before is green again, the consumer stays there: it leaves the marker
``<state>/upgrade/held-at.json`` (the commit it went back to, the commit of the red lock, the digest of
that lock and the components that went red), and no commit whose shared lock is that one becomes
active here. The record of its state carries the marker as ``held``, so the producer reads it from
``state/<name>``. The producer puts the pins of those components back to the values of the commit
the consumer went back to and holds them locally; the lock that comes of it is another one, so the
consumer drops the marker and tries it.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import re
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic
from dotsteward_cli import publish as publishing

MARKER = "held-at.json"
SCHEMA_VERSION = 1
PIN_FILE = "versions.lock.json"
FLAKE_LOCK = "flake.lock"
# Free on every machine: the time a writer last ran. No pin.
_FREE_KEYS = frozenset({"generated_at", "schema_version"})
_HEX40 = re.compile(r"[0-9a-f]{40}", re.ASCII)
_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,62}", re.ASCII)
_INSTANT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", re.ASCII)


def _show(root: Path, commit: str, path: str) -> str | None:
    done = publishing.git(root, "show", f"{commit}:{path}")
    return done.stdout if done.code == 0 else None


def _json(text: str | None) -> Any:
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def _pins(root: Path, commit: str) -> Any:
    document = _json(_show(root, commit, PIN_FILE))
    if isinstance(document, dict):
        return {key: value for key, value in document.items() if key not in _FREE_KEYS}
    return document


def _flake_nodes(root: Path, commit: str) -> dict[str, Any]:
    """The locked inputs of flake.lock, by node."""
    document = _json(_show(root, commit, FLAKE_LOCK))
    nodes = document.get("nodes") if isinstance(document, dict) else None
    return (
        {name: node.get("locked") for name, node in nodes.items() if isinstance(node, dict)}
        if isinstance(nodes, dict)
        else {}
    )


def lock_digest(root: Path, commit: str) -> str | None:
    """What the shared lock of COMMIT says, whatever else the commit holds; None when COMMIT is not here."""
    if publishing.git(root, "cat-file", "-e", f"{commit}^{{commit}}").code != 0:
        return None
    payload = {"pins": _pins(root, commit), "flake": _flake_nodes(root, commit)}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def _leaves(value: Any, keys: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], Any]]:
    if isinstance(value, dict) and value:
        for key, inner in value.items():
            yield from _leaves(inner, (*keys, str(key)))
    else:
        yield keys, value


def _at(value: Any, keys: Sequence[str]) -> tuple[bool, Any]:
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return False, None
        value = value[key]
    return True, value


def moved_pins(root: Path, before: str, after: str) -> list[dict[str, Any]]:
    """The pins the pin file moved from BEFORE to AFTER: {id, path, from, to}. A pin is the object a
    changed value is in (``agent_tools.codex.linux``, ``flake_inputs.nixpkgs``), or the value itself
    at the top; a new one is no move."""
    old, new = _pins(root, before), _pins(root, after)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return []
    paths: dict[tuple[str, ...], None] = {}
    for keys, value in _leaves(old):
        present, now = _at(new, keys)
        if keys and present and now != value:
            paths[keys[:-1] if len(keys) > 1 else keys] = None
    rows = []
    for keys in sorted(paths):
        _, was = _at(old, keys)
        _, now = _at(new, keys)
        rows.append({"id": ".".join(keys), "path": list(keys), "from": was, "to": now})
    return rows


def owned_by(rows: Sequence[Mapping[str, Any]], components: Sequence[str], owners: Mapping[str, str]) -> list[str]:
    """The ids of ROWS that belong to one of COMPONENTS: by the pin of its binary (OWNERS: pin id to
    component) or by its name as a part of the id."""
    wanted = set(components)
    return [
        str(row["id"])
        for row in rows
        if owners.get(str(row["id"])) in wanted or wanted & set(str(row["id"]).split("."))
    ]


def flake_input(row: Mapping[str, Any]) -> bool:
    """A flake input moves with flake.nix and flake.lock, which only the writer writes."""
    return str(row["id"]).startswith("flake_inputs.")


def put_back(work: Path, rows: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """Writes the value each pin of ROWS had before (``from``) into the pin file of the clone WORK, all
    but the flake inputs: the rows it put back."""
    done = [row for row in rows if not flake_input(row)]
    if not done:
        return []
    path = work / PIN_FILE
    document = json.loads(path.read_text(encoding="utf-8"))
    for row in done:
        keys = [str(key) for key in row["path"]]
        target = document
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = row["from"]
    atomic.atomic_write(path, json.dumps(document, indent=2) + "\n")
    return done


def version_of(value: Any) -> str:
    """The text a local hold keeps of a pin value."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("version", "rev", "revision"):
            if isinstance(value.get(key), str):
                return str(value[key])
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:16]


# --- the marker ---------------------------------------------------------------------------------


def _path(state_root: str) -> Path:
    return Path(state_root) / "upgrade" / MARKER


def read_marker(state_root: str) -> dict[str, Any] | None:
    """The marker of this machine, None when it holds no lock back."""
    try:
        document = json.loads(_path(state_root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict) or document.get("schema_version") != SCHEMA_VERSION:
        return None
    if not all(isinstance(document.get(key), str) for key in ("commit", "lock_commit", "lock", "at")):
        return None
    return document


def write_marker(state_root: str, *, commit: str, lock_commit: str, lock: str, components: Sequence[str]) -> None:
    at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    atomic.make_private_dirs(Path(state_root) / "upgrade")
    atomic.atomic_write_json(
        _path(state_root),
        {
            "schema_version": SCHEMA_VERSION,
            "commit": commit,
            "lock_commit": lock_commit,
            "lock": lock,
            "components": sorted(set(components)),
            "at": at,
        },
        mode=0o600,
    )


def drop_marker(state_root: str) -> None:
    _path(state_root).unlink(missing_ok=True)


def held(state_root: str, names: Sequence[str]) -> dict[str, Any] | None:
    """The ``held`` field of a state record: the marker in the fixed form of the schema, with only
    the components of NAMES (the intent); None without a marker."""
    marker = read_marker(state_root)
    if marker is None:
        return None
    commits = (marker["commit"], marker["lock_commit"])
    if not all(_HEX40.fullmatch(commit) for commit in commits) or not _INSTANT.fullmatch(marker["at"]):
        return None
    known = set(names)
    components = [
        str(name)
        for name in marker.get("components") or ()
        if isinstance(name, str) and name in known and _NAME.fullmatch(name)
    ]
    return {
        "commit": marker["commit"],
        "lock_commit": marker["lock_commit"],
        "components": sorted(set(components)),
        "at": marker["at"],
    }
