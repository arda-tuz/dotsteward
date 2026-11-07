"""The machine state of skill tracking: ``<state root>/skills/`` (mode 0700).

    base.json          {"skill:<name>" | "plugin:<name>": {base_sha256, base_commit,
                       local_path}}: what this machine last had in sync with the
                       repository; a plugin of a marketplace has a record without a
                       digest, {tracked: "marketplace", base_commit}
    pending.json       {schema_version, reconciled_at, items: {"skill:<name>" |
                       "plugin:<name>": item}}: what waits for a capture, a question or
                       an answer
    last-capture.json  the last capture: redacted findings, dropped files

A file is replaced atomically, so a reader sees a whole one. A change of
``pending.json`` holds ``pending.lock`` and a change of ``base.json`` holds ``base.lock``,
so parallel tool calls and a rebuild next to a capture lose nothing. The state belongs to
this machine and never enters the repository.

This module is on the path of a hook without a change, so it imports the primitives
(which bring ``pathlib`` and ``subprocess``) only for a write.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable, Mapping
from typing import Any

SCHEMA_VERSION = 1
# The revision that marks a skill as the user's own; [compat] repo_owned_revision names
# another one for an instance that started with its own word for it.
REPO_OWNED_REVISION = "same-as-instance-checkout"
BASE_FILE = "base.json"
PENDING_FILE = "pending.json"
PENDING_LOCK = "pending.lock"
BASE_LOCK = "base.lock"
LAST_CAPTURE_FILE = "last-capture.json"
# A name that may reach an agent, a desktop notification or a file name.
PLAIN_NAME = re.compile(r"[A-Za-z0-9._-]+")
# A plugin of a marketplace goes by its spec, NAME@MARKETPLACE.
PLUGIN_SPEC = re.compile(r"[A-Za-z0-9._-]+@[A-Za-z0-9._-]+")
SKILL = "skill"
PLUGIN = "plugin"
MARKETPLACE_RECORD = "marketplace"
# How long a change of pending.json waits for the lock before it gives up: a hook
# must not stall, and the next reconcile finds what a lost change would have said.
_PENDING_WAIT_SECONDS = 2.0
# A record of base.json is no hook's business and must not get lost: it waits longer, and
# writes in the end, because a process stuck on this lock is the greater harm.
_BASE_WAIT_SECONDS = 10.0


def directory(state_root: str) -> str:
    """``<state root>/skills``."""
    return os.path.join(state_root, "skills")


def item_key(kind: str, name: str) -> str:
    """The key of an item and of a record: ``skill:<name>`` or ``plugin:<name>``."""
    return f"{kind}:{name}"


def skill_key(name: str) -> str:
    return item_key(SKILL, name)


def plugin_key(name: str) -> str:
    return item_key(PLUGIN, name)


def shown_name(name: str) -> bool:
    """Whether NAME may reach an agent or the desktop: a plain name or a plugin spec."""
    return bool(PLAIN_NAME.fullmatch(name) or PLUGIN_SPEC.fullmatch(name))


def read_json(path: str, default: Any) -> Any:
    """The JSON document at PATH, DEFAULT when it is missing or no JSON: a broken
    state file must not stop a hook, and no b only means "ask" for a decision."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path: str, value: Any) -> None:
    """Replaces the private file at PATH, with its directory when it is missing."""
    from dotsteward_cli import atomic

    atomic.make_private_dirs(os.path.dirname(path))
    atomic.atomic_write_json(path, value, mode=0o600)


def lock_entries(path: str | os.PathLike[str], key: str = "skills") -> list[dict[str, Any]] | None:
    """The entries of the skills lock at PATH, None when it cannot be read: a merge in
    progress or a clone being replaced says nothing about any skill. KEY ``own_plugins``:
    the own plugins, an empty list when the lock has none."""
    document = read_json(os.fspath(path), None)
    if not isinstance(document, dict) or not isinstance(document.get("skills"), list):
        return None
    entries = document.get(key, [])
    return [entry for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else None


def load_base(state_root: str) -> dict[str, Any]:
    document = read_json(os.path.join(directory(state_root), BASE_FILE), {})
    return document if isinstance(document, dict) else {}


def change_base(state_root: str, change: Callable[[dict[str, Any]], bool]) -> None:
    """Reads base.json under its lock, runs CHANGE and writes it when CHANGE returns True."""
    from dotsteward_cli import atomic, locks

    root = directory(state_root)
    atomic.make_private_dirs(root)
    lock = locks.FileLock(os.path.join(root, BASE_LOCK))
    lock.try_acquire(wait=_BASE_WAIT_SECONDS)
    try:
        base = load_base(state_root)
        if change(base):
            write_json(os.path.join(root, BASE_FILE), base)
    finally:
        if lock.held:
            lock.release()


def base_entry(base: Mapping[str, Any], name: str, kind: str = SKILL) -> dict[str, Any] | None:
    """The record of the skill (or plugin) NAME in BASE, None without a digest."""
    entry = base.get(item_key(kind, name))
    if isinstance(entry, dict) and isinstance(entry.get("base_sha256"), str) and entry["base_sha256"]:
        return entry
    return None


def record_base(state_root: str, name: str, digest: str, commit: str, local_path: str, kind: str = SKILL) -> None:
    """Records that this machine had NAME in sync, unless it is known already."""
    _record(state_root, item_key(kind, name), {"base_sha256": digest, "base_commit": commit, "local_path": local_path})


def record_marketplace(state_root: str, spec: str, commit: str) -> None:
    """Records that the remote tracks the plugin SPEC of a marketplace since COMMIT, which
    the checkout may not have yet: it is no question meanwhile."""
    _record(state_root, plugin_key(spec), {"tracked": MARKETPLACE_RECORD, "base_commit": commit})


def _record(state_root: str, key: str, entry: Mapping[str, Any]) -> None:
    def change(base: dict[str, Any]) -> bool:
        if base.get(key) == entry:
            return False
        base[key] = dict(entry)
        return True

    change_base(state_root, change)


def forget_base(state_root: str, name: str, kind: str = SKILL) -> None:
    """This machine no longer has anything in sync for NAME."""
    key = item_key(kind, name)
    if key in load_base(state_root):
        change_base(state_root, lambda base: base.pop(key, None) is not None)


def empty_pending() -> dict[str, Any]:
    return {"schema_version": SCHEMA_VERSION, "reconciled_at": None, "items": {}}


def append_log(path: str, line: str, limit_bytes: int) -> None:
    """LINE at the end of a log of this state, which is as private as the rest of it, also
    when it was there before. A log past LIMIT_BYTES starts over. OSError when it cannot."""
    try:
        too_long = os.path.getsize(path) > limit_bytes
    except OSError:
        too_long = False
    flags = os.O_WRONLY | os.O_CREAT | os.O_CLOEXEC | (os.O_TRUNC if too_long else os.O_APPEND)
    with os.fdopen(os.open(path, flags, 0o600), "w", encoding="utf-8") as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(f"{line}\n")


def load_pending(state_root: str) -> dict[str, Any]:
    document = read_json(os.path.join(directory(state_root), PENDING_FILE), None)
    if not isinstance(document, dict) or not isinstance(document.get("items"), dict):
        return empty_pending()
    return document


def change_pending(state_root: str, change: Callable[[dict[str, Any]], bool]) -> bool:
    """Reads pending.json under its lock, runs CHANGE and writes the document when
    CHANGE returns True. False when the lock stayed busy: nothing happened."""
    from dotsteward_cli import atomic, locks

    root = directory(state_root)
    atomic.make_private_dirs(root)
    lock = locks.FileLock(os.path.join(root, PENDING_LOCK))
    if not lock.try_acquire(wait=_PENDING_WAIT_SECONDS):
        return False
    try:
        document = load_pending(state_root)
        if change(document):
            write_json(os.path.join(root, PENDING_FILE), document)
    finally:
        lock.release()
    return True


def set_item(state_root: str, key: str, fields: Mapping[str, Any]) -> bool:
    """Merges FIELDS into the item KEY of pending.json, creating it."""

    def change(document: dict[str, Any]) -> bool:
        item = document["items"].get(key)
        merged = {**item, **fields} if isinstance(item, dict) else dict(fields)
        if merged == item:
            return False
        document["items"][key] = merged
        return True

    return change_pending(state_root, change)


def drop_item(state_root: str, key: str) -> bool:
    """Removes the item KEY of pending.json."""
    if key not in load_pending(state_root)["items"]:
        return True

    def change(document: dict[str, Any]) -> bool:
        return document["items"].pop(key, None) is not None

    return change_pending(state_root, change)
