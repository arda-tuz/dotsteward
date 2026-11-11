"""A shared lock that goes red on a machine that is not the producer (T19, docs/upgrade.md).

Only the producer moves the shared lock: the pins of ``versions.lock.json``, ``flake.lock``, the
skills lock and the vendored skills, the npm locks and the hash-pinned requirements. A consumer
takes a new lock when it follows the remote. When E2E goes red after that and the
generation of the commit before is green again, the consumer stays there: it leaves the marker
``<state>/upgrade/held-at.json`` (the commit it went back to, the commit of the red lock, the digest of
that lock and the components that went red), and no commit whose shared lock is that one becomes
active here. The record of its state carries the marker as ``held``, so the producer reads it from
``state/<name>``. The producer puts the pins of those components back (``pins apply --restore``) to
a value every consumer that holds them back was green on, and holds them locally; anything else
waits for a person. A later lock is tried here only when it moves what the marker watches.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import re
from collections.abc import Collection, Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic
from dotsteward_cli import publish as publishing

MARKER = "held-at.json"
SCHEMA_VERSION = 1
PIN_FILE = "versions.lock.json"
FLAKE_LOCK = "flake.lock"
SKILLS_LOCK = "agent/skills.lock.json"
SKILLS_DIR = "agent/skills"
# The other files of the shared lock (design: what the producer alone moves), by pattern: the skills
# lock and the vendored skills, the npm locks, the hash-pinned Python requirements.
_SHARED_FILES = re.compile(
    r"(agent/skills\.lock\.json|packages/[^/]+/package-lock\.json|components/.+/requirements[^/]*\.txt)", re.ASCII
)
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


def _shared_files(root: Path, commit: str) -> dict[str, str]:
    """The other files of the shared lock at COMMIT, by path: the object id of each, and of each
    vendored skill directory (``agent/skills/<name>``)."""
    done = publishing.git(root, "ls-tree", "-r", "-t", "--full-tree", commit, "--", "agent", "packages", "components")
    found: dict[str, str] = {}
    for line in done.stdout.splitlines() if done.code == 0 else ():
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) != 3:
            continue
        kind, oid = parts[1], parts[2]
        file = kind == "blob" and _SHARED_FILES.fullmatch(path) is not None
        skill = kind == "tree" and path.startswith(f"{SKILLS_DIR}/") and path.count("/") == 2
        if file or skill:
            found[path] = oid
    return found


def lock_digest(root: Path, commit: str) -> str | None:
    """What the shared lock of COMMIT (a commit or a tree) says, whatever else it holds: the pins of
    the pin file, the locked inputs of flake.lock and the other files of the shared lock (the skills
    lock and skills, the npm locks, the hash-pinned requirements); None when COMMIT is not here."""
    if publishing.git(root, "cat-file", "-e", f"{commit}^{{tree}}").code != 0:
        return None
    payload = {"pins": _pins(root, commit), "flake": _flake_nodes(root, commit), "files": _shared_files(root, commit)}
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


def _pin_path(document: Mapping[str, Any], pin: str) -> list[str]:
    """Where the pin id PIN is in the pin file: a top-level key of that name, else its dotted path."""
    return [pin] if pin in document else pin.split(".")


def moved_pins(root: Path, before: str, after: str, pins: Collection[str]) -> list[dict[str, Any]]:
    """The pins of PINS whose value the pin file moved from BEFORE to AFTER: {id, path, from, to}. A
    pin it adds is no move."""
    old, new = _pins(root, before), _pins(root, after)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return []
    rows = []
    for pin in sorted(pins):
        keys = _pin_path(old, pin)
        had, was = _at(old, keys)
        has, now = _at(new, keys)
        if had and has and was != now:
            rows.append({"id": pin, "path": keys, "from": was, "to": now})
    return rows


def moved_paths(root: Path, before: str, after: str) -> list[str]:
    """Every value the pin file moved from BEFORE to AFTER, by its dotted path, and each input of
    flake.lock that moved, as flake.lock.NAME: what a person looks at."""
    old, new = _pins(root, before), _pins(root, after)
    paths = []
    if isinstance(old, dict) and isinstance(new, dict):
        for keys, value in _leaves(old):
            present, now = _at(new, keys)
            if keys and present and now != value:
                paths.append(".".join(keys))
    old_nodes, new_nodes = _flake_nodes(root, before), _flake_nodes(root, after)
    paths += [
        f"flake.lock.{name}" for name in sorted(old_nodes) if name in new_nodes and new_nodes[name] != old_nodes[name]
    ]
    old_files, new_files = _shared_files(root, before), _shared_files(root, after)
    paths += [path for path in sorted({*old_files, *new_files}) if old_files.get(path) != new_files.get(path)]
    return paths


def watched_values(root: Path, commit: str, paths: Sequence[str]) -> dict[str, str]:
    """For each path of moved_paths (or a pin id), a digest of what COMMIT holds there ("" for
    nothing): what a held consumer compares to know whether the lock moved what went red."""
    pins = _pins(root, commit)
    nodes = _flake_nodes(root, commit)
    files = _shared_files(root, commit)
    values: dict[str, str] = {}
    for path in paths:
        if path.startswith("flake.lock."):
            value: Any = nodes.get(path.removeprefix("flake.lock."))
        elif path in files or "/" in path:
            value = files.get(path)
        else:
            value = _at(pins, _pin_path(pins, path))[1] if isinstance(pins, dict) else None
        values[path] = "" if value is None else hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    return values


def watch_moved(root: Path, marker: Mapping[str, Any], commit: str) -> bool:
    """Whether COMMIT moved what the marker watches. A marker without a watch list (of an older run)
    watches the whole lock."""
    watch = marker.get("watch")
    if not isinstance(watch, dict):
        return True
    return watched_values(root, commit, [str(path) for path in watch]) != watch


def pin_values(root: Path, commit: str) -> dict[str, Any] | None:
    """The pins of the pin file at COMMIT (None when it has none): what pins_at reads a value from."""
    pins = _pins(root, commit)
    return pins if isinstance(pins, dict) else None


def pin_value(pins: Mapping[str, Any] | None, pin: str) -> Any:
    """The value of the pin id PIN in PINS, None without it."""
    if pins is None:
        return None
    return _at(pins, _pin_path(pins, pin))[1]


def same_value(pins: Mapping[str, Any] | None, path: Sequence[str], value: Any) -> bool:
    """Whether PINS hold VALUE at PATH (a path of moved_pins)."""
    if pins is None:
        return False
    present, found = _at(pins, [str(key) for key in path])
    return present and found == value


def version_of(value: Any) -> str:
    """The text a local hold keeps of a pin value."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("version", "minimum_version", "expected", "rev", "revision"):
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


def write_marker(
    state_root: str,
    *,
    commit: str,
    lock_commit: str,
    lock: str,
    components: Sequence[str],
    watch: Mapping[str, str] | None = None,
) -> None:
    """The marker: WATCH holds what a later lock must move before this machine tries it (the pins of
    what went red, or every path the lock moved when none of them is a pin), by watched_values."""
    at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    atomic.make_private_dirs(Path(state_root) / "upgrade")
    document: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "commit": commit,
        "lock_commit": lock_commit,
        "lock": lock,
        "components": sorted(set(components)),
        "at": at,
    }
    if watch is not None:
        document["watch"] = dict(sorted(watch.items()))
    atomic.atomic_write_json(_path(state_root), document, mode=0o600)


def refusal(root: Path, state_root: str, treeish: str, role: str) -> str | None:
    """Why TREEISH must not become active on this machine: its shared lock is the one that went red
    here and this machine (of ROLE, facts.role) is a consumer that holds it back. None otherwise,
    and at once without a marker."""
    marker = read_marker(state_root)
    if marker is None or role in ("this-machine", "unnamed", "nobody"):
        return None
    if lock_digest(root, treeish) != marker["lock"]:
        return None
    components = ", ".join(str(name) for name in marker.get("components") or ()) or "its checks named none"
    return (
        f"this machine holds back the shared lock of {str(marker['lock_commit'])[:12]}: it went red here "
        f"({components}), and the generation of {str(marker['commit'])[:12]} stays until {role} moves what "
        "went red; `dotsteward upgrade` takes the next lock"
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
