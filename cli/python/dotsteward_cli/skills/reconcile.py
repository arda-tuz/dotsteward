"""The comparison of the skill roots with what is known about them: no network.

``load_context`` reads what ``skills hooks install`` wrote, so a hook need not look for
the instance. ``reconcile`` looks at every root once:

- a name of the lock, of ``base.json``, of ``[declined]`` or of a pending item is no
  candidate; what remains with a ``plugin.json`` is a plugin, with a ``SKILL.md`` a skill,
  and ``origin`` says what becomes of it;
- what an answer keeps out (``declined``, ``forgotten``) stays out whatever happens to the
  copy, until another answer takes it back;
- an own skill with a file newer than ``reconciled_at`` gets its digest compared with b
  (the full mode digests all of them, for copies that keep their time);
- an own skill that is gone is ``deleted`` after two looks at least 60 seconds apart
  (``missing`` in pending.json), so the window of a refresh is no deletion.

Without a change nothing is written and no process starts: this runs inside every Stop
and SessionStart. ``note_writes`` is the same decision for the paths a file tool wrote.
A plugin is only reported for now: nothing asks about it and nothing captures it.
"""

from __future__ import annotations

import os
import time
from collections.abc import Iterable, Mapping
from typing import Any

from dotsteward_cli.skills import origin, state

CAPTURE = "capture"
ASK = "ask"
CONFLICT = "conflict"
BLOCKED = "blocked"
DELETED = "deleted"
LOCAL_EDIT = "local-edit"
NAME_TAKEN = "name-taken"
NOT_REFRESHED = "not-refreshed"
DECLINED = "declined"
FORGOTTEN = "forgotten"
_KEPT_OUT = frozenset({DECLINED, FORGOTTEN})

SKILL_FILE = "SKILL.md"
DELETED_AFTER_SECONDS = 60
# A reader of the file times: a change within the same tick of a coarse clock counts.
_MTIME_MARGIN_SECONDS = 2.0
_SKIPPED_WHEN_WALKING = frozenset({".git", "__pycache__", "__pypackages__"})
_NOT_OURS_PREFIXES = ("/nix/store/",)
FRAMEWORK_PREFIX = "dotsteward-"


def context_path(env: Mapping[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    config = env.get("XDG_CONFIG_HOME") or os.path.join(env.get("HOME") or os.path.expanduser("~"), ".config")
    return os.path.join(config, "dotsteward", "hook-context.json")


def load_context() -> dict[str, Any] | None:
    """What the hooks know about the instance, None when tracking is not set up."""
    document = state.read_json(context_path(), None)
    if not isinstance(document, dict):
        return None
    for key in ("instance", "state_root", "lock_path"):
        if not isinstance(document.get(key), str):
            return None
    return document


def machine_name(context: Mapping[str, Any]) -> str | None:
    """The name of this machine: DOTSTEWARD_MACHINE, then ``<state>/machine.json``."""
    name = os.environ.get("DOTSTEWARD_MACHINE")
    if name:
        return name
    document = state.read_json(os.path.join(str(context["state_root"]), "machine.json"), None)
    value = document.get("name") if isinstance(document, dict) else None
    return value if isinstance(value, str) and value else None


def _read_lock(context: Mapping[str, Any]) -> list[dict[str, Any]]:
    document = state.read_json(str(context["lock_path"]), None)
    entries = document.get("skills") if isinstance(document, dict) else None
    return [entry for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else []


def _is_own(entry: Mapping[str, Any], context: Mapping[str, Any]) -> bool:
    return entry.get("revision") in (context.get("repo_owned_revisions") or []) and (
        entry.get("deployment", "copy") != "home-manager"
    )


def _excluded_name(name: str, context: Mapping[str, Any]) -> bool:
    return name.startswith((".", FRAMEWORK_PREFIX)) or name in (context.get("exclude") or [])


def _not_ours(path: str, context: Mapping[str, Any]) -> bool:
    """A link into a generation or the store of scoped skills belongs to dotsteward."""
    target = os.path.realpath(path)
    store = context.get("scoped_store")
    return target.startswith(_NOT_OURS_PREFIXES) or (isinstance(store, str) and target.startswith(store + os.sep))


def _scan(context: Mapping[str, Any]) -> dict[str, str]:
    """Name to path of every directory directly in a root; the first root wins."""
    found: dict[str, str] = {}
    for root in context.get("roots") or []:
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    if entry.name in found or _excluded_name(entry.name, context):
                        continue
                    if not entry.is_dir():
                        continue
                    if entry.is_symlink() and _not_ours(entry.path, context):
                        continue
                    found[entry.name] = entry.path
        except OSError:
            continue
    return found


def _changed_since(path: str, since: float) -> bool:
    """Whether a file or directory below PATH is newer than SINCE."""
    pending = [path]
    limit = since - _MTIME_MARGIN_SECONDS
    try:
        if os.stat(path).st_mtime > limit:
            return True
    except OSError:
        return True
    while pending:
        try:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    if entry.name in _SKIPPED_WHEN_WALKING:
                        continue
                    if entry.stat(follow_symlinks=False).st_mtime > limit:
                        return True
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)
        except OSError:
            continue
    return False


def _local_digest(path: str, context: Mapping[str, Any]) -> str:
    from dotsteward_cli.skills import normal

    excludes = os.path.join(str(context["instance"]), ".gitignore")
    return normal.normal_form(os.path.realpath(path), excludes).digest


def declined_in(tree: str, machine: str | None) -> set[str]:
    """``declined.skills`` of ``hosts/<machine>.toml`` in TREE; read only for a candidate."""
    if not machine:
        return set()
    path = os.path.join(tree, "hosts", f"{machine}.toml")
    from dotsteward_cli import tomlfile

    try:
        document = tomlfile.load(path)
    except (OSError, ValueError):
        return set()
    declined = document.get("declined")
    names = declined.get("skills") if isinstance(declined, dict) else None
    return {name for name in names if isinstance(name, str)} if isinstance(names, list) else set()


def _candidate_item(name: str, path: str, evidence: Mapping[str, Any] | None) -> dict[str, Any]:
    kind_plugin = os.path.isfile(os.path.join(path, origin.PLUGIN_MANIFEST))
    where, source = origin.classify(name, path, evidence)
    return {
        "kind": "plugin" if kind_plugin else "skill",
        "name": name,
        "path": path,
        "state": CAPTURE if where == origin.OWN else ASK,
        "origin": where,
        "source": source,
        "evidence": dict(evidence) if evidence else None,
        "detected_at": time.time(),
        "last_asked": None,
        "reason": None,
        "attempts": 0,
    }


def _is_candidate(path: str) -> bool:
    return os.path.isfile(os.path.join(path, origin.PLUGIN_MANIFEST)) or os.path.isfile(os.path.join(path, SKILL_FILE))


def _item_key(path: str, name: str) -> str:
    return f"plugin:{name}" if os.path.isfile(os.path.join(path, origin.PLUGIN_MANIFEST)) else state.skill_key(name)


class Plan:
    """What a look at the roots wants changed; applied to a fresh pending.json."""

    def __init__(self) -> None:
        self.set_items: dict[str, dict[str, Any]] = {}
        self.writers: dict[str, str] = {}
        self.drop_items: list[str] = []
        self.missing: dict[str, float] = {}
        self.not_missing: list[str] = []
        self.looked_at: float | None = None

    def __bool__(self) -> bool:
        return bool(self.set_items or self.drop_items or self.missing or self.not_missing or self.looked_at)

    def apply(self, document: dict[str, Any]) -> bool:
        items = document["items"]
        for key, fields in self.set_items.items():
            known = items.get(key)
            items[key] = {**known, **fields} if isinstance(known, dict) else dict(fields)
        for key, session in self.writers.items():
            item = items.get(key)
            if isinstance(item, dict):
                item["writers"] = sorted({*(item.get("writers") or []), session})
        for key in self.drop_items:
            items.pop(key, None)
        missing = document.setdefault("missing", {})
        missing.update(self.missing)
        for key in self.not_missing:
            missing.pop(key, None)
        if not missing:
            document.pop("missing", None)
        if self.looked_at is not None:
            document["reconciled_at"] = self.looked_at
        return True


def _look_at_own(
    name: str,
    path: str | None,
    base: Mapping[str, Any] | None,
    document: Mapping[str, Any],
    context: Mapping[str, Any],
    plan: Plan,
    *,
    full: bool,
    now: float,
) -> None:
    key = state.skill_key(name)
    item = document["items"].get(key)
    if isinstance(item, dict) and item.get("state") in _KEPT_OUT:
        if key in document.get("missing", {}):
            plan.not_missing.append(key)
        return
    if path is None:
        if base is None:
            return
        since = document.get("missing", {}).get(key)
        if isinstance(item, dict) and item.get("state") == DELETED:
            return
        if not isinstance(since, (int, float)):
            plan.missing[key] = now
        elif now - since >= DELETED_AFTER_SECONDS:
            plan.not_missing.append(key)
            plan.set_items[key] = {
                "kind": "skill",
                "name": name,
                "path": None,
                "state": DELETED,
                "origin": origin.OWN,
                "digest": None,
                "detected_at": now,
                "last_asked": None,
            }
        return
    if key in document.get("missing", {}):
        plan.not_missing.append(key)
    if isinstance(item, dict) and item.get("state") == DELETED:
        plan.drop_items.append(key)
    if base is None:
        return
    since = document.get("reconciled_at")
    if not full and isinstance(since, (int, float)) and not _changed_since(path, float(since)):
        return
    plan.looked_at = now
    digest = _local_digest(path, context)
    if digest == base.get("base_sha256"):
        # A copy that could not take what the repository holds is no local change gone away.
        waits = isinstance(item, dict) and item.get("reason") == NOT_REFRESHED
        if isinstance(item, dict) and item.get("state") in {CAPTURE, BLOCKED, CONFLICT, DELETED} and not waits:
            plan.drop_items.append(key)
        return
    if isinstance(item, dict) and item.get("state") == BLOCKED and item.get("blocked_digest") == digest:
        return
    if isinstance(item, dict) and item.get("state") == CONFLICT and item.get("digest") == digest:
        return
    if isinstance(item, dict) and item.get("state") == CAPTURE and item.get("digest") == digest:
        return
    if isinstance(item, dict) and item.get("state") == CAPTURE and item.get("digest") is None:
        # A file tool wrote it and the delay runs from there; now the content is known.
        plan.set_items[key] = {"digest": digest}
        return
    plan.set_items[key] = {
        "kind": "skill",
        "name": name,
        "path": path,
        "state": CAPTURE,
        "origin": origin.OWN,
        "digest": digest,
        "detected_at": now,
        "reason": None,
        "due": False,
    }


def _look(context: Mapping[str, Any], document: Mapping[str, Any], *, full: bool) -> Plan:
    plan = Plan()
    now = time.time()
    entries = _read_lock(context)
    base = state.load_base(str(context["state_root"]))
    found = _scan(context)
    items = document["items"]
    machine = machine_name(context) if any("machines" in entry for entry in entries) else None
    named: set[str] = set()
    own: set[str] = set()
    for entry in entries:
        name, directory = str(entry.get("name")), str(entry.get("directory") or entry.get("name"))
        legacy = entry.get("legacy_directory")
        names = {name, directory} | ({legacy} if isinstance(legacy, str) else set())
        named |= names
        machines = entry.get("machines")
        if isinstance(machines, list) and machine not in machines:
            record = state.base_entry(base, name)
            if record is None and directory in found and _is_candidate(found[directory]):
                key = state.skill_key(name)
                if not isinstance(items.get(key), dict) or items[key].get("state") != NAME_TAKEN:
                    plan.set_items[key] = {
                        "kind": "skill",
                        "name": name,
                        "path": found[directory],
                        "state": NAME_TAKEN,
                        "origin": origin.UNKNOWN,
                        "detected_at": now,
                        "last_asked": None,
                    }
            continue
        if _is_own(entry, context):
            own.add(name)
            path = _own_path(found, base, name, directory, legacy)
            _look_at_own(name, path, state.base_entry(base, name), document, context, plan, full=full, now=now)
    for key in base:
        name = key.removeprefix("skill:")
        if key.startswith("skill:") and name not in own and name not in named:
            path = _own_path(found, base, name, name, None)
            _look_at_own(name, path, state.base_entry(base, name), document, context, plan, full=full, now=now)
    # A skill whose lock name is not its directory: captured, the checkout not there yet.
    named |= {os.path.basename(str(record.get("local_path"))) for record in base.values() if isinstance(record, dict)}
    fresh = [
        (name, path)
        for name, path in found.items()
        if name not in named
        and state.skill_key(name) not in base
        and _item_key(path, name) not in items
        and _is_candidate(path)
    ]
    if fresh:
        declined = declined_in(str(context["instance"]), machine or machine_name(context))
        for name, path in fresh:
            if name not in declined:
                plan.set_items[_item_key(path, name)] = _candidate_item(name, path, None)
    since = document.get("reconciled_at")
    for key, item in items.items():
        if _vanished(item) and key not in base:
            plan.drop_items.append(key)
        elif key not in base and key not in plan.set_items and _blocked_changed(item, since, full, context):
            plan.looked_at = now
            plan.set_items[key] = {"state": CAPTURE, "reason": None, "detected_at": now}
    if document.get("reconciled_at") is None:
        plan.looked_at = now
    return plan


def _blocked_changed(item: Any, since: Any, full: bool, context: Mapping[str, Any]) -> bool:
    """A new skill that was kept back has another content by now, so it gets a new try."""
    if not isinstance(item, dict) or not isinstance(item.get("path"), str):
        return False
    if item.get("state") != BLOCKED and not (item.get("state") == NAME_TAKEN and item.get("blocked_digest")):
        return False
    path = item["path"]
    if not os.path.isdir(path):
        return False
    if not full and isinstance(since, (int, float)) and not _changed_since(path, float(since)):
        return False
    return _local_digest(path, context) != item.get("blocked_digest")


def _vanished(item: Any) -> bool:
    """A new skill that waits for an answer or a capture and is gone by now."""
    return (
        isinstance(item, dict)
        and item.get("state") in {ASK, CAPTURE}
        and isinstance(item.get("path"), str)
        and not os.path.isdir(item["path"])
    )


def _own_path(found: Mapping[str, str], base: Mapping[str, Any], name: str, directory: str, legacy: Any) -> str | None:
    """The local copy of an own skill: a root first, then where it was last seen."""
    for candidate in (directory, legacy, name):
        if (
            isinstance(candidate, str)
            and candidate in found
            and os.path.isfile(os.path.join(found[candidate], SKILL_FILE))
        ):
            return found[candidate]
    record = state.base_entry(base, name)
    known = record.get("local_path") if record else None
    if isinstance(known, str) and os.path.isfile(os.path.join(known, SKILL_FILE)):
        return known
    return None


def reconcile(context: Mapping[str, Any], *, full: bool = False) -> dict[str, Any]:
    """Looks at the roots and returns pending.json as it is afterwards."""
    state_root = str(context["state_root"])
    document = state.load_pending(state_root)
    plan = _look(context, document, full=full)
    if not plan:
        return document
    state.change_pending(state_root, plan.apply)
    return state.load_pending(state_root)


def note_writes(
    context: Mapping[str, Any],
    hits: Iterable[tuple[str, str, str]],
    agent: str,
    tool: str,
    session: str | None = None,
) -> tuple[bool, dict[str, Any]]:
    """Records what a file tool wrote: HITS are (path of the skill, name, path below
    it), SESSION the session that wrote, whose end publishes it. Returns whether an own
    skill changed, and pending.json afterwards."""
    state_root = str(context["state_root"])
    entries = _read_lock(context)
    base = state.load_base(state_root)
    by_name: dict[str, dict[str, Any]] = {}
    for lock_entry in entries:
        for known_name in (lock_entry.get("name"), lock_entry.get("directory"), lock_entry.get("legacy_directory")):
            if isinstance(known_name, str):
                by_name[known_name] = lock_entry
    now = time.time()
    evidence = {"agent": agent, "tool": tool, "at": now}
    plan = Plan()
    own_changed = False
    document = state.load_pending(state_root)
    declined = declined_in(str(context["instance"]), machine_name(context))
    for path, name, below in hits:
        entry = by_name.get(name)
        own_key = state.skill_key(str(entry["name"]) if entry is not None else name)
        known_item = document["items"].get(own_key)
        if isinstance(known_item, dict) and known_item.get("state") in _KEPT_OUT:
            continue
        if name in declined and own_key not in base:
            continue
        if entry is not None and entry.get("deployment", "copy") != "copy":
            continue
        if entry is not None and not _is_own(entry, context):
            plan.set_items[state.skill_key(str(entry["name"]))] = {
                "kind": "skill",
                "name": str(entry["name"]),
                "path": path,
                "state": LOCAL_EDIT,
                "origin": origin.DOWNLOADED,
                "evidence": evidence,
                "detected_at": now,
            }
            continue
        if entry is not None or state.skill_key(name) in base:
            skill_name = str(entry["name"]) if entry is not None else name
            plan.set_items[state.skill_key(skill_name)] = {
                "kind": "skill",
                "name": skill_name,
                "path": path,
                "state": CAPTURE,
                "origin": origin.OWN,
                "digest": None,
                "evidence": evidence,
                "detected_at": now,
                "reason": None,
                "due": False,
            }
            if session:
                plan.writers[state.skill_key(skill_name)] = session
            own_changed = True
            continue
        key = _item_key(path, name)
        known = document["items"].get(key)
        if below not in (SKILL_FILE, origin.PLUGIN_MANIFEST) or not _is_candidate(path):
            if isinstance(known, dict) and known.get("state") == CAPTURE and known.get("origin") == origin.OWN:
                plan.set_items[key] = {"detected_at": now, "digest": None, "due": False}
                if session:
                    plan.writers[key] = session
                own_changed = True
            continue
        item = _candidate_item(name, path, evidence)
        if isinstance(known, dict) and known.get("state") == item["state"]:
            # Waiting for a capture, a new write starts the delay again.
            for kept in (
                ("attempts", "last_asked") if item["state"] == CAPTURE else ("attempts", "last_asked", "detected_at")
            ):
                if kept in known:
                    item[kept] = known[kept]
        item["due"] = False
        plan.set_items[key] = item
        if session and item["state"] == CAPTURE:
            plan.writers[key] = session
        own_changed = own_changed or (item["state"] == CAPTURE and item["kind"] == "skill")
    if plan:
        state.change_pending(state_root, plan.apply)
    return own_changed, state.load_pending(state_root)
