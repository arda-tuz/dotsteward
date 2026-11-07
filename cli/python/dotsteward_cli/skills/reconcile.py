"""The comparison of the skill roots with what is known about them: no network.

``load_context`` reads what ``skills hooks install`` wrote, so a hook need not look for
the instance. ``reconcile`` looks at every root once:

- a name of the lock (its skills and its own plugins), of ``base.json``, of ``[declined]``
  or of a pending item is no candidate; what remains directly in ``~/.claude/skills`` with a
  ``.claude-plugin/plugin.json`` is a plugin, with a ``SKILL.md`` a skill, and ``origin``
  says what becomes of it;
- what an answer keeps out (``declined``, ``forgotten``) stays out whatever happens to the
  copy, until another answer takes it back;
- an own skill or own plugin with a file newer than ``reconciled_at`` gets its digest
  compared with b (the full mode digests all of them, for copies that keep their time);
- an own skill that is gone is ``deleted`` after two looks at least 60 seconds apart
  (``missing`` in pending.json), so the window of a refresh is no deletion.

- a plugin of a marketplace that Claude Code installed is a question (``plugins``); its
  files are read again only after a change.

Without a change nothing is written and no process starts: this runs inside every Stop
and SessionStart. ``note_writes`` is the same decision for the paths a file tool wrote.
"""

from __future__ import annotations

import os
import time
from collections.abc import Iterable, Mapping
from typing import Any

from dotsteward_cli.skills import origin, plugins, state

CAPTURE = "capture"
ASK = "ask"
CONFLICT = "conflict"
BLOCKED = "blocked"
DELETED = "deleted"
LOCAL_EDIT = "local-edit"
NAME_TAKEN = "name-taken"
NOT_REFRESHED = "not-refreshed"
# The place of an own plugin is taken here by something else.
OCCUPIED = "occupied"
# An own plugin of another agent holds the name of a tracked one.
OTHER_AGENT = "other-agent"
# What kept a skill back belongs to the tree, not to the skill.
TREE_REASONS = frozenset({"checks-red", "commit-refused"})
_TREE_RETRY_SECONDS = 6 * 3600
DECLINED = "declined"
FORGOTTEN = "forgotten"
KEPT_OUT = frozenset({DECLINED, FORGOTTEN})

SKILL_FILE = "SKILL.md"
DELETED_AFTER_SECONDS = 60
# A reader of the file times: a change within the same tick of a coarse clock counts.
_MTIME_MARGIN_SECONDS = 2.0
_SKIPPED_WHEN_WALKING = frozenset({".git", "__pycache__", "__pypackages__"})
_NOT_OURS_PREFIXES = ("/nix/store/",)
FRAMEWORK_PREFIX = "dotsteward-"
DEFAULT_MAX_MIB = 100
TOO_LARGE_PREFIX = "too-large:"


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


def _is_own(entry: Mapping[str, Any], context: Mapping[str, Any]) -> bool:
    return entry.get("revision") in (context.get("repo_owned_revisions") or []) and (
        entry.get("deployment", "copy") != "home-manager"
    )


def _excluded_name(name: str, context: Mapping[str, Any]) -> bool:
    return name.startswith((".", FRAMEWORK_PREFIX)) or name in (context.get("exclude") or [])


def _not_ours(path: str, context: Mapping[str, Any]) -> bool:
    """A link into a generation, the store of scoped skills or the checkout belongs to
    dotsteward."""
    target = os.path.realpath(path)
    if target.startswith(_NOT_OURS_PREFIXES):
        return True
    for place in (context.get("scoped_store"), context.get("instance")):
        if isinstance(place, str) and target.startswith(os.path.realpath(place) + os.sep):
            return True
    return False


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


def limit_bytes(context: Mapping[str, Any]) -> int:
    """``[skills] capture_max_mib``: above it a skill is not read at all."""
    return int(context.get("capture_max_mib") or DEFAULT_MAX_MIB) * 1024 * 1024


def _local_digest(path: str, context: Mapping[str, Any]) -> str:
    """The digest of the copy. A skill above the limit answers with what stands for its
    content, so a hook does not spend its time limit on reading it."""
    from dotsteward_cli.skills import normal

    excludes = os.path.join(str(context["instance"]), ".gitignore")
    try:
        return normal.normal_form(os.path.realpath(path), excludes, limit_bytes(context)).digest
    except normal.TooLarge as large:
        return TOO_LARGE_PREFIX + large.marker


def declined_of(document: Mapping[str, Any]) -> set[str]:
    """``declined.skills`` of a host file."""
    declined = document.get("declined")
    names = declined.get("skills") if isinstance(declined, dict) else None
    return {name for name in names if isinstance(name, str)} if isinstance(names, list) else set()


def declined_in(tree: str, machine: str | None) -> set[str]:
    """``declined.skills`` of ``hosts/<machine>.toml`` in TREE; read only for a candidate."""
    if not machine:
        return set()
    path = os.path.join(tree, "hosts", f"{machine}.toml")
    from dotsteward_cli import tomlfile

    try:
        return declined_of(tomlfile.load(path))
    except (OSError, ValueError):
        return set()


def _candidate_item(name: str, path: str, evidence: Mapping[str, Any] | None) -> dict[str, Any]:
    where, source = origin.classify(name, path, evidence)
    return {
        "kind": _kind_of(path) or state.SKILL,
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


def _kind_of(path: str) -> str | None:
    """A plugin of Claude Code's skills directory, a skill, or nothing tracking knows."""
    if plugins.is_own_plugin_dir(path):
        return state.PLUGIN
    return state.SKILL if os.path.isfile(os.path.join(path, SKILL_FILE)) else None


def _is_candidate(path: str) -> bool:
    return _kind_of(path) is not None


def _item_key(path: str, name: str) -> str:
    return state.item_key(_kind_of(path) or state.SKILL, name)


class Plan:
    """What a look at the roots wants changed; applied to a fresh pending.json."""

    def __init__(self) -> None:
        self.set_items: dict[str, dict[str, Any]] = {}
        self.writers: dict[str, str] = {}
        self.drop_items: list[str] = []
        self.missing: dict[str, float] = {}
        self.not_missing: list[str] = []
        self.looked_at: float | None = None
        self.plugin_files: list[float | None] | None = None
        self.forget_base: list[str] = []

    def __bool__(self) -> bool:
        return bool(
            self.set_items
            or self.drop_items
            or self.missing
            or self.not_missing
            or self.looked_at
            or self.plugin_files is not None
            or self.forget_base
        )

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
        if self.plugin_files is not None:
            document["plugin_files"] = self.plugin_files
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
    kind: str = state.SKILL,
) -> None:
    key = state.item_key(kind, name)
    item = document["items"].get(key)
    if isinstance(item, dict) and item.get("state") in KEPT_OUT:
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
                "kind": kind,
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
    try:
        digest = _local_digest(path, context)
    except (OSError, RuntimeError):
        # This skill cannot be read now, and takes no other one down with it.
        return
    if digest.startswith(TOO_LARGE_PREFIX):
        if not (isinstance(item, dict) and item.get("state") == BLOCKED and item.get("blocked_digest") == digest):
            plan.set_items[key] = {
                "kind": kind,
                "name": name,
                "path": path,
                "state": BLOCKED,
                "origin": origin.OWN,
                "reason": "too-large",
                "blocked_digest": digest,
                "digest": digest,
                "detected_at": now,
                "last_asked": None,
            }
        return
    if isinstance(item, dict) and item.get("state") == NAME_TAKEN:
        # It waits for a rename or for the other copy to go; this one is not news.
        where = item.get("path")
        same = isinstance(where, str) and os.path.realpath(where) == os.path.realpath(path)
        if isinstance(where, str) and os.path.isdir(where) and (not same or item.get("blocked_digest") == digest):
            return
    if digest == base.get("base_sha256"):
        # A copy that could not take what the repository holds is no local change gone away.
        waits = isinstance(item, dict) and item.get("reason") == NOT_REFRESHED
        if (
            isinstance(item, dict)
            and item.get("state") in {CAPTURE, BLOCKED, CONFLICT, DELETED, NAME_TAKEN}
            and not waits
        ):
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
        "kind": kind,
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
    entries = state.lock_entries(str(context["lock_path"]))
    if entries is None:
        return plan
    base = state.load_base(str(context["state_root"]))
    found = _scan(context)
    items = document["items"]
    plugin_entries = state.lock_entries(str(context["lock_path"]), "own_plugins") or []
    with_machines = any("machines" in entry for entry in [*entries, *plugin_entries])
    machine = machine_name(context) if with_machines else None
    named: set[str] = set()
    own: set[str] = set()
    for entry in entries:
        name, directory = str(entry.get("name")), str(entry.get("directory") or entry.get("name"))
        legacy = entry.get("legacy_directory")
        names = {name, directory} | ({legacy} if isinstance(legacy, str) else set())
        named |= names
        machines = entry.get("machines")
        if isinstance(machines, list) and machine not in machines:
            if directory in found:
                _name_taken(name, found[directory], base, items, plan, now, state.SKILL)
            continue
        if _is_own(entry, context):
            own.add(name)
            path = _own_path(found, base, name, directory, legacy)
            _look_at_own(name, path, state.base_entry(base, name), document, context, plan, full=full, now=now)
    plugin_names: set[str] = set()
    own_plugins: set[str] = set()
    for entry in plugin_entries:
        name, directory = str(entry.get("name")), str(entry.get("directory") or entry.get("name"))
        plugin_names |= {name, directory}
        machines = entry.get("machines")
        if isinstance(machines, list) and machine not in machines:
            if directory in found:
                _name_taken(name, found[directory], base, items, plan, now, state.PLUGIN)
            continue
        own_plugins.add(name)
        agents = _agents_of(entry)
        path = _own_plugin_path(base, name, directory, agents)
        record = state.base_entry(base, name, state.PLUGIN)
        _other_agents(name, directory, agents, path, context, items, plan, now)
        place = os.path.join(plugins.plugin_root(agents[0]), directory)
        if path is None and record is None and os.path.lexists(place):
            # Its place is taken here by something that is no plugin: said, not installed.
            _name_taken(name, place, base, items, plan, now, state.PLUGIN, occupied=True)
            continue
        taken = items.get(state.plugin_key(name))
        if isinstance(taken, dict) and taken.get("state") == NAME_TAKEN and taken.get("reason") == OCCUPIED:
            plan.drop_items.append(state.plugin_key(name))
        _look_at_own(name, path, record, document, context, plan, full=full, now=now, kind=state.PLUGIN)
    for key in base:
        kind, _, name = key.partition(":")
        if kind == state.SKILL and name not in own and name not in named:
            path = _own_path(found, base, name, name, None)
            _look_at_own(name, path, state.base_entry(base, name), document, context, plan, full=full, now=now)
        elif kind == state.PLUGIN and name not in own_plugins and name not in plugin_names:
            record = state.base_entry(base, name, state.PLUGIN)
            if record is not None:
                agents = _recorded_agents(base, name) or [plugins.AGENT]
                path = _own_plugin_path(base, name, name, agents)
                _other_agents(name, name, agents, path, context, items, plan, now)
                _look_at_own(name, path, record, document, context, plan, full=full, now=now, kind=state.PLUGIN)
    # A skill whose lock name is not its directory: captured, the checkout not there yet.
    named |= {
        os.path.basename(str(record["local_path"]))
        for record in base.values()
        if isinstance(record, dict) and isinstance(record.get("local_path"), str)
    }
    fresh = [
        (name, path)
        for name, path in found.items()
        # A name of the lock keeps out its own kind only.
        if name not in (plugin_names if _kind_of(path) == state.PLUGIN else named)
        and _item_key(path, name) not in base
        and _item_key(path, name) not in items
        and _is_candidate(path)
    ]
    if fresh:
        here = machine or machine_name(context)
        declined = {
            state.SKILL: declined_in(str(context["instance"]), here),
            state.PLUGIN: plugins.declined_in(str(context["instance"]), here),
        }
        for name, path in fresh:
            if name not in declined[_kind_of(path) or state.SKILL]:
                plan.set_items[_item_key(path, name)] = _candidate_item(name, path, None)
    marketplace_items, gone, stamp, plan.forget_base = plugins.look(
        context, document, base, lambda: machine or machine_name(context), full=full, now=now
    )
    plan.set_items.update(marketplace_items)
    plan.drop_items += gone
    if stamp is not None and stamp != document.get("plugin_files"):
        plan.plugin_files = stamp
    since = document.get("reconciled_at")
    for key, item in items.items():
        answered = _answered_by_the_lock(item, plugin_names if key.startswith("plugin:") else named)
        if (_vanished(item) and key not in base) or (answered and key not in plan.set_items):
            plan.drop_items.append(key)
        elif key not in base and key not in plan.set_items and _blocked_changed(item, since, full, context):
            plan.looked_at = now
            plan.set_items[key] = {"state": CAPTURE, "reason": None, "detected_at": now}
        elif key not in plan.set_items and _tree_may_have_moved(item, now, full):
            plan.set_items[key] = {"state": CAPTURE}
    if document.get("reconciled_at") is None:
        plan.looked_at = now
    return plan


def _name_taken(
    name: str,
    path: str,
    base: Mapping[str, Any],
    items: Mapping[str, Any],
    plan: Plan,
    now: float,
    kind: str,
    *,
    occupied: bool = False,
) -> None:
    """A copy at PATH under the name of an entry that is for other machines only: it holds the
    name, so it is said, never captured. OCCUPIED: the entry is for this machine, and its
    place is taken by something of another kind."""
    if state.base_entry(base, name, kind) is not None:
        return
    if (_kind_of(path) == kind) == occupied:
        return
    key = state.item_key(kind, name)
    item = items.get(key)
    if isinstance(item, dict) and item.get("state") in {NAME_TAKEN, *KEPT_OUT}:
        return
    plan.set_items[key] = {
        "kind": kind,
        "name": name,
        "path": path,
        "state": NAME_TAKEN,
        "origin": origin.UNKNOWN,
        "reason": OCCUPIED if occupied else None,
        "detected_at": now,
        "last_asked": None,
    }


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
    try:
        return _local_digest(path, context) != item.get("blocked_digest")
    except (OSError, RuntimeError):
        return False


def _answered_by_the_lock(item: Any, named: set[str]) -> bool:
    """A question about a skill that is in the lock by now has an answer."""
    return isinstance(item, dict) and item.get("state") == ASK and item.get("name") in named


def _tree_may_have_moved(item: Any, now: float, full: bool) -> bool:
    """A red check waits for another tree. Whether there is one takes a fetch, which is the
    business of a capture, so a skill goes there every few hours; it does not run the checks
    again on the same tip."""
    if not isinstance(item, dict) or item.get("state") != BLOCKED or item.get("reason") not in TREE_REASONS:
        return False
    blocked_at = item.get("blocked_at")
    return full or not isinstance(blocked_at, (int, float)) or now - blocked_at >= _TREE_RETRY_SECONDS


def _vanished(item: Any) -> bool:
    """A new skill that waits for an answer or a capture and is gone by now."""
    return (
        isinstance(item, dict)
        and item.get("state") in {ASK, CAPTURE}
        and isinstance(item.get("path"), str)
        and not os.path.isdir(item["path"])
    )


def _agents_of(entry: Mapping[str, Any]) -> list[str]:
    agents = entry.get("agents")
    return [str(agent) for agent in agents] if isinstance(agents, list) and agents else [plugins.AGENT]


def _recorded_agents(base: Mapping[str, Any], name: str) -> list[str] | None:
    """The agent of the copy this machine last had in sync, for a checkout behind its lock."""
    record = state.base_entry(base, name, state.PLUGIN)
    known = record.get("local_path") if record else None
    if not isinstance(known, str):
        return None
    root = os.path.dirname(os.path.normpath(known))
    if root == plugins.codex_plugins_dir():
        return [plugins.CODEX_AGENT]
    return [plugins.AGENT] if root == plugins.claude_skills_dir() else None


def shadow_key(name: str, agent: str) -> str:
    """The item of an own plugin of AGENT that holds the name of a tracked one of another
    agent: no plain name, so it never meets a real one."""
    return state.plugin_key(f"{name}/{agent}")


def _other_agents(
    name: str,
    directory: str,
    agents: list[str],
    path: str | None,
    context: Mapping[str, Any],
    items: Mapping[str, Any],
    plan: Plan,
    now: float,
) -> None:
    """A name is one own plugin: a plugin of another agent under it is name-taken
    (other-agent), never captured, and the item goes once the name is free there."""
    roots = context.get("roots") or []
    for agent in (plugins.AGENT, plugins.CODEX_AGENT):
        if agent in agents:
            continue
        key = shadow_key(name, agent)
        other = os.path.join(plugins.plugin_root(agent), directory)
        held = plugins.plugin_root(agent) in roots and plugins.agent_of(other) == agent and other != path
        item = items.get(key)
        if held and not (isinstance(item, dict) and item.get("path") == other):
            plan.set_items[key] = {
                "kind": state.PLUGIN,
                "name": name,
                "path": other,
                "state": NAME_TAKEN,
                "origin": origin.UNKNOWN,
                "reason": OTHER_AGENT,
                "detected_at": now,
                "last_asked": None,
            }
        elif not held and isinstance(item, dict):
            plan.drop_items.append(key)


def _own_plugin_path(base: Mapping[str, Any], name: str, directory: str, agents: list[str]) -> str | None:
    """The local copy of an own plugin, in the root of one of its AGENTS, then where it was
    last seen; a copy of another agent is none."""
    for candidate in (directory, name):
        copy = plugins.own_copy(candidate, agents)
        if copy is not None:
            return copy
    record = state.base_entry(base, name, state.PLUGIN)
    known = record.get("local_path") if record else None
    if isinstance(known, str) and plugins.agent_of(known) in agents:
        return known
    return None


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
    for key in plan.forget_base:
        kind, _, name = key.partition(":")
        state.forget_base(state_root, name, kind)
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
    entries = state.lock_entries(str(context["lock_path"]))
    if entries is None:
        # Nothing says what these names are; the next look at the roots does.
        return False, state.load_pending(state_root)
    base = state.load_base(state_root)
    plugin_by_name: dict[str, dict[str, Any]] = {}
    for listed in state.lock_entries(str(context["lock_path"]), "own_plugins") or []:
        for known_name in (listed.get("name"), listed.get("directory")):
            if isinstance(known_name, str):
                plugin_by_name[known_name] = listed
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
    machine = machine_name(context)
    declined = declined_in(str(context["instance"]), machine)
    declined_plugins: set[str] | None = None
    for path, name, below in hits:
        plugin_entry = plugin_by_name.get(name)
        # Only a plugin directory is a plugin: a write of a skill at that place is the skill's.
        if plugins.is_own_plugin_dir(path):
            plugin_name = str(plugin_entry["name"]) if plugin_entry is not None else name
            key = state.plugin_key(plugin_name)
            known_item = document["items"].get(key)
            if isinstance(known_item, dict) and known_item.get("state") in {*KEPT_OUT, NAME_TAKEN}:
                continue
            agents = _agents_of(plugin_entry) if plugin_entry is not None else _recorded_agents(base, plugin_name)
            if agents is not None and plugins.agent_of(path) not in agents:
                # One name, one own plugin: the copy of another agent is told, never captured.
                if not isinstance(document["items"].get(shadow_key(plugin_name, str(plugins.agent_of(path)))), dict):
                    plan.set_items[shadow_key(plugin_name, str(plugins.agent_of(path)))] = {
                        "kind": state.PLUGIN,
                        "name": plugin_name,
                        "path": path,
                        "state": NAME_TAKEN,
                        "origin": origin.UNKNOWN,
                        "reason": OTHER_AGENT,
                        "detected_at": now,
                        "last_asked": None,
                    }
                continue
            machines = plugin_entry.get("machines") if plugin_entry is not None else None
            if isinstance(machines, list) and machine not in machines:
                continue
            if plugin_entry is not None or state.base_entry(base, plugin_name, state.PLUGIN) is not None:
                plan.set_items[key] = {
                    "kind": state.PLUGIN,
                    "name": plugin_name,
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
                    plan.writers[key] = session
                own_changed = True
                continue
            if declined_plugins is None:
                declined_plugins = plugins.declined_in(str(context["instance"]), machine)
            if name in declined_plugins:
                continue
        entry = by_name.get(name)
        own_key = state.skill_key(str(entry["name"]) if entry is not None else name)
        known_item = document["items"].get(own_key)
        if isinstance(known_item, dict) and known_item.get("state") in KEPT_OUT:
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
        if below not in (SKILL_FILE, plugins.PLUGIN_MANIFEST, *plugins.CODEX_MANIFESTS) or not _is_candidate(path):
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
        own_changed = own_changed or item["state"] == CAPTURE
    if plan:
        state.change_pending(state_root, plan.apply)
    return own_changed, state.load_pending(state_root)
