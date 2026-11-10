"""What other machines changed, and what this machine makes of it.

The repository always moves forward; what lands on this machine depends on the answer:
install, ask later, or never on this machine. Nothing keeps a cursor or a queue of
questions: every run compares the tree with what this machine holds, so ``waiting`` is a
pure look at the checkout, ``<state>/skills/base.json``, the copies and
``<state>/machine/known.json``:

    skill, own           new: in scope, in the lock, no b, no copy here
                         changed: lock != b and the copy is still b (threeway: incoming)
                         removed: b exists, the lock has no such skill for this machine
    skill, third party   new: in scope, in the lock, no copy here
                         clash: `agents install` found a copy that never was a pin of the lock
    plugin               new: in scope, not known
    component            new: enabled, in scope, for this profile, not known

Everything else another machine changes needs no question: the pins of the producer and
the rest of the intent arrive with the next ``rebuild``, as a whole tree. What another
machine scoped away from this one (``machines``) is never new here: ``machine.effective``
takes it out first, and also settles ``requires``.

``known.json`` is ``{schema_version, components, plugins}``: only what has no copy to look at.
A machine set up before this release has no such file: ``agents install`` writes what is for it
now, and nothing is asked. A machine without a name has no other machines to hear from, and
behaves as it always did.

A change is this machine's own when a commit that is not published yet makes it, or when the
commit that made it says ``Dotsteward-Machine: <this machine>`` (``publish.stamp`` puts that on
everything that leaves): such an item is accepted without a question. No such line names an
unknown machine. A new skill goes by the commit that added its SKILL.md, so a later batch commit
of a producer neither answers the question nor renames it.

Answers: ``Install`` (one `agents install` that takes the item, DOTSTEWARD_INCOMING_ACCEPT: an
install that fails stays a question; a component is written to known.json and waits for the next
rebuild), nothing for ``Ask later``, and ``Never`` (``declined`` in ``hosts/<name>.toml`` with a
commit of its own, published without force; without a network the answer holds through
``machine/never.json`` and a later run publishes it).

Exit status: 0 done, 1 refusal, 2 usage error; ``incoming`` without a subcommand also 3,
when questions wait and no terminal can answer them (``review.json`` holds them).

Python API: ``waiting``, ``read_known``, ``forget_state``, ``write_baseline``, ``settle``, ``ask``,
``answer``, ``move_forward``.

Command line (``cli/commands/incoming.sh``)::

    python3 -m dotsteward_cli.incoming [ask|list|show ID|answer ID --install|--never] [--json]
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Collection, Iterator, Mapping, Sequence
from pathlib import Path
from typing import TYPE_CHECKING, Any

from dotsteward_cli import config, machine

if TYPE_CHECKING:
    from dotsteward_cli import report

KNOWN_FILE = os.path.join("machine", "known.json")
SCHEMA_VERSION = 1
EXIT_REFUSAL = 1
EXIT_USAGE = 2

NEW = "new"
CHANGED = "changed"
REMOVED = "removed"
_KIND_KEYS = {"skill": "skills", "plugin": "plugins", "component": "components"}
NEVER_FILE = os.path.join("machine", "never.json")
ACCEPT_ENV = "DOTSTEWARD_INCOMING_ACCEPT"
CLASH = "clash"
_FETCH_SCOPE = "incoming"
# `machine.effective` asks `waiting` in every command: what no question needs is imported
# where it is used, so a machine without a question pays for reading two files.
_TRAILER = re.compile(r"^Dotsteward-Machine:[ \t]*([a-z0-9][a-z0-9-]*)[ \t]*$", re.MULTILINE)
_REVIEW_CODE = "incoming"
_SHOW_LINES = 80


class UsageError(Exception):
    """A usage error: exit status 2."""


class Refusal(Exception):
    """A refusal: exit status 1."""


class _NotEvaluated(Refusal):
    """Nix does not evaluate this machine with the answer."""


def _say(message: str) -> None:
    print(f"[dotsteward] {message}", file=sys.stderr, flush=True)


# --- known.json -------------------------------------------------------------------------


def read_known(state_root: str | os.PathLike[str]) -> dict[str, Any] | None:
    """What this machine knows, None when it has not said yet. A file that cannot be read says
    nothing: a question too few is better than a question about everything."""
    try:
        document = json.loads((Path(state_root) / KNOWN_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return document if isinstance(document, dict) else None


def _write_machine_file(state_root: str | os.PathLike[str], name: str, document: Mapping[str, Any]) -> None:
    from dotsteward_cli import atomic

    path = Path(state_root) / name
    atomic.make_private_dirs(state_root)
    atomic.make_private_dirs(path.parent)
    atomic.atomic_write_json(path, document, mode=0o600)


def _names(document: Mapping[str, Any] | None, key: str) -> set[str]:
    values = document.get(key) if document else None
    return {str(value) for value in values} if isinstance(values, list) else set()


def forget_state(state_root: str | os.PathLike[str]) -> None:
    """A new start under a name: what the instance holds then is the base of it."""
    for name in (KNOWN_FILE, NEVER_FILE):
        (Path(state_root) / name).unlink(missing_ok=True)


def never_answers(state_root: str | os.PathLike[str]) -> dict[str, list[str]]:
    """The answers ``Never`` the host file in the checkout does not hold yet."""
    try:
        document = json.loads((Path(state_root) / NEVER_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict):
        return {}
    return {key: [str(name) for name in value] for key, value in document.items() if isinstance(value, list)}


def _write_never(state_root: str | os.PathLike[str], never: Mapping[str, list[str]]) -> None:
    kept = {key: names for key, names in never.items() if names}
    if kept:
        _write_machine_file(state_root, NEVER_FILE, kept)
    else:
        (Path(state_root) / NEVER_FILE).unlink(missing_ok=True)


def _accepted(env: Mapping[str, str] | None) -> set[str]:
    """The ids the `agents install` of an answer is told to take."""
    env = os.environ if env is None else env
    try:
        value = json.loads(env.get(ACCEPT_ENV) or "[]")
    except ValueError:
        return set()
    return {str(item) for item in value} if isinstance(value, list) else set()


# --- the facts of the tree --------------------------------------------------------------


def _git(root: str | os.PathLike[str], *arguments: str) -> str:
    """The output of a git command, empty when it fails."""
    from dotsteward_cli import publish as publishing

    result = publishing.git(root, *arguments)
    return result.stdout if result.code == 0 else ""


def _own_revisions(instance: config.Instance) -> set[str]:
    from dotsteward_cli.skills import state as skill_state

    revisions = {skill_state.REPO_OWNED_REVISION, instance.config["compat"].get("repo_owned_revision")}
    return {str(revision) for revision in revisions if revision}


def _lock_broken(instance: config.Instance) -> bool:
    """A lock that is there and cannot be read says nothing about any item: a merge in
    progress, a clone being replaced. An instance without a lock has no skills."""
    try:
        document = json.loads((instance.root / instance.config["skills"]["lock"]).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True
    return not (isinstance(document, dict) and isinstance(document.get("skills", []), list))


def _vendor_path(instance: config.Instance, directory: str) -> str:
    return f"{str(instance.config['skills']['vendor_dir']).rstrip('/')}/{directory}"


def _lock_digest(entry: Mapping[str, Any]) -> str:
    return str(entry.get("directory_sha256") or entry.get("skill_sha256") or "")


def _unpublished(root: Path, where: Sequence[str], pick: Sequence[str] = ()) -> bool:
    """Whether a commit no remote has seen makes the change: PICK (log options) among those that
    touch WHERE. Every fetch leaves its tip in origin/* or refs/dotsteward/*, so a checkout moved to
    a tip has no such commit."""
    arguments = ["log", "-1", "--format=%H", "HEAD", "--not", "--remotes=origin", "--glob=refs/dotsteward/*"]
    return bool(_git(root, *arguments, *pick, "--", *where).strip())


def _source(root: Path, where: Sequence[str], pick: Sequence[str] = ()) -> dict[str, Any]:
    """The commit that made the change: the machine its message names, and when."""
    answer = _git(root, "log", "-1", "--format=%cI%x00%B", *pick, "--", *where)
    moment, _, message = answer.partition("\0")
    found = _TRAILER.findall(message)
    return {"by": found[-1] if found else None, "when": moment.strip() or None}


def _pretty_time(moment: str | None) -> str:
    import datetime

    if not moment:
        return "unknown time"
    try:
        return datetime.datetime.fromisoformat(moment).astimezone(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return moment


# --- what waits --------------------------------------------------------------------------


def _question(kind: str, change: str, name: str, origin: Mapping[str, Any], **extra: Any) -> dict[str, Any]:
    item_id = f"{kind}:{name}"
    return {
        "id": item_id,
        "kind": kind,
        "change": change,
        "name": name,
        **origin,
        "show": f"dotsteward incoming show {item_id}",
        "answer": f"dotsteward incoming answer {item_id} --install|--never",
        **extra,
    }


def _item(
    instance: config.Instance,
    this: str,
    kind: str,
    change: str,
    name: str,
    where: Sequence[str],
    pick: Sequence[str] = (),
    mine: Sequence[str] | None = None,
    **extra: Any,
) -> dict[str, Any] | None:
    """The question about NAME, None when the change is this machine's own: WHERE and PICK find the
    commit that made it, MINE (default: WHERE and PICK) a commit that is not published yet."""
    root = instance.root
    if _unpublished(root, *((mine, ()) if mine is not None else (where, pick))):
        return None
    origin = _source(root, where, pick)
    if origin["by"] == this:
        return None
    return _question(kind, change, name, origin, **extra)


def _left_behind(
    instance: config.Instance,
    base: Mapping[str, Any],
    in_scope: Collection[str],
    reasons: Mapping[str, str],
) -> Iterator[tuple[str, dict[str, Any]]]:
    """The own skills in BASE the checkout holds nothing for on this machine. A capture
    pushes and leaves the checkout alone, so a record from a commit the checkout has not
    reached is a skill that is too new for its lock, not one that left it."""
    from dotsteward_cli.skills import state as skill_state
    from dotsteward_cli.skills import threeway

    for key in sorted(base):
        name = key.removeprefix("skill:")
        record = skill_state.base_entry(base, name) if key.startswith("skill:") else None
        if record is None or name in in_scope or reasons.get(key) == machine.REASON_DECLINED:
            continue
        if not threeway.is_behind(str(instance.root), str(record.get("base_commit") or "")):
            yield name, record


def _skill_items(
    instance: config.Instance,
    state_root: str,
    this: str,
    reasons: Mapping[str, str],
    lock: Mapping[str, Any],
) -> list[dict[str, Any]]:
    from dotsteward_cli.skills import layout, threeway
    from dotsteward_cli.skills import state as skill_state

    entries = machine.entries_of(lock, "skills")
    base = skill_state.load_base(state_root)
    own = _own_revisions(instance)
    lock_file = str(instance.config["skills"]["lock"])
    roots = layout.read(instance)
    pending = skill_state.load_pending(state_root)["items"]
    items: list[dict[str, Any] | None] = []
    in_scope: set[str] = set()
    for entry in entries:
        name, directory = entry.get("name"), entry.get("directory")
        if not isinstance(name, str) or not isinstance(directory, str):
            continue
        if reasons.get(f"skill:{name}") in (machine.REASON_MACHINES, machine.REASON_DECLINED):
            continue
        in_scope.add(name)
        if entry.get("deployment", "copy") != "copy":
            continue
        digest = _lock_digest(entry)
        record = skill_state.base_entry(base, name) if entry.get("revision") in own else None
        vendor = _vendor_path(instance, directory)
        if record is None:
            copy = layout.find_copy(roots, entry)
            if copy is None:
                added = f"{vendor}/SKILL.md"
                items.append(_item(instance, this, "skill", NEW, name, [added], ["--diff-filter=A"]))
                continue
            noted = pending.get(skill_state.skill_key(name))
            if isinstance(noted, dict) and noted.get("state") == CLASH and noted.get("digest") != digest:
                origin = _source(instance.root, [f"{vendor}/SKILL.md"], ["--diff-filter=A"])
                items.append(_question("skill", CLASH, name, origin, path=copy))
        elif record["base_sha256"] != digest:
            try:
                answer = threeway.assess(name, layout.find_copy(roots, entry), digest, str(instance.root), state_root)
            except (OSError, RuntimeError):
                # A copy that cannot be read is no reason for a command to fail; `skills status` says it.
                continue
            if answer["state"] == threeway.INCOMING:
                items.append(_item(instance, this, "skill", CHANGED, name, [vendor], path=answer["path"]))
    for name, record in _left_behind(instance, base, in_scope, reasons):
        local = record.get("local_path")
        if not (isinstance(local, str) and os.path.isdir(local)):
            continue
        vendor = _vendor_path(instance, os.path.basename(local))
        if reasons.get(f"skill:{name}") == machine.REASON_MACHINES:
            items.append(
                _item(
                    instance,
                    this,
                    "skill",
                    REMOVED,
                    name,
                    [lock_file],
                    ['-G"machines"'],
                    [lock_file],
                    path=local,
                    scoped_away=True,
                )
            )
        else:
            items.append(
                _item(
                    instance, this, "skill", REMOVED, name, [vendor, lock_file], [f'-S"{name}"'], [vendor], path=local
                )
            )
    return [item for item in items if item is not None]


def _plugin_items(
    instance: config.Instance, this: str, known: Mapping[str, Any], reasons: Mapping[str, str], lock: Mapping[str, Any]
) -> list[dict[str, Any]]:
    seen = _names(known, "plugins")
    items: list[dict[str, Any] | None] = []
    lock_file = str(instance.config["skills"]["lock"])
    for plugin in sorted({str(p["spec"]) for p in machine.plugin_entries(instance) if isinstance(p.get("spec"), str)}):
        if plugin not in seen and f"plugin:{plugin}" not in reasons:
            items.append(_item(instance, this, "plugin", NEW, plugin, [config.CONFIG_FILE], [f"-S{plugin}"]))
    for entry in machine.entries_of(lock, "own_plugins"):
        own = entry.get("name")
        if isinstance(own, str) and own not in seen and f"plugin:{own}" not in reasons:
            items.append(_item(instance, this, "plugin", NEW, own, [lock_file], [f"-S{own}"]))
    return [item for item in items if item is not None]


def _component_items(
    instance: config.Instance, state_root: str, this: str, known: Mapping[str, Any], reasons: Mapping[str, str]
) -> list[dict[str, Any]]:
    """An enabled component this machine does not know, for its profile: one for another
    profile is no business of this machine yet."""
    seen = _names(known, "components")
    profile = machine.machine_profile(instance, state_root, this)
    items: list[dict[str, Any] | None] = []
    for name, table in machine.enabled_components(instance):
        if name in seen or f"component:{name}" in reasons:
            continue
        profiles = table.get("profiles")
        if profiles is not None and profile not in profiles:
            continue
        items.append(_item(instance, this, "component", NEW, name, [config.CONFIG_FILE], [f"-S[components.{name}]"]))
    return [item for item in items if item is not None]


def waiting(
    instance: config.Instance,
    name: str | None,
    reasons: Mapping[str, str],
    env: Mapping[str, str] | None = None,
) -> list[dict[str, Any]]:
    """What waits for an answer on the machine NAME. REASONS: what it leaves out so far, so
    an entry for other machines or a declined one never gets here. Writes nothing."""
    if name is None:
        return []
    state_root = config.state_root(instance, env)
    known = read_known(state_root)
    if known is None or _lock_broken(instance):
        return []
    lock = machine.read_lock(instance)
    items = [
        *_skill_items(instance, state_root, name, reasons, lock),
        *_plugin_items(instance, name, known, reasons, lock),
        *_component_items(instance, state_root, name, known, reasons),
    ]
    accepted = _accepted(env)
    return [item for item in items if item["id"] not in accepted]


def _current(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    return machine.effective(instance, env)


def _current_set(instance: config.Instance, scope: Mapping[str, Any], state_root: str) -> dict[str, list[str]]:
    """The components and plugins that are for this machine now, as known.json holds them. What is
    out of scope stays out of it, so a wider scope is a question later."""
    reasons = scope["reasons"]
    lock = machine.read_lock(instance)
    plugins = {str(p["spec"]) for p in machine.plugin_entries(instance) if isinstance(p.get("spec"), str)}
    plugins |= {str(p["name"]) for p in machine.entries_of(lock, "own_plugins") if isinstance(p.get("name"), str)}
    profile = machine.machine_profile(instance, state_root, scope["name"])
    components = {
        name
        for name, table in machine.enabled_components(instance)
        if reasons.get(f"component:{name}") in (None, machine.REASON_NOT_ACTIVATED, machine.REASON_REQUIRES)
        and (table.get("profiles") is None or profile in table["profiles"])
    }
    return {
        "plugins": sorted(plugin for plugin in plugins if f"plugin:{plugin}" not in reasons),
        "components": sorted(components),
    }


def write_baseline(instance: config.Instance, env: Mapping[str, str] | None = None) -> bool:
    """A named machine without known.json knows what is for it now: no question comes out of
    it. Whether it wrote the file."""
    state_root = config.state_root(instance, env)
    scope = _current(instance, env)
    if scope["name"] is None or read_known(state_root) is not None or _lock_broken(instance):
        return False
    _write_machine_file(
        state_root, KNOWN_FILE, {"schema_version": SCHEMA_VERSION, **_current_set(instance, scope, state_root)}
    )
    return True


def _accept_components(state_root: str, names: Collection[str]) -> None:
    known = read_known(state_root) or {"schema_version": SCHEMA_VERSION}
    known["components"] = sorted(_names(known, "components") | set(names))
    _write_machine_file(state_root, KNOWN_FILE, known)


def settle(instance: config.Instance, env: Mapping[str, str] | None = None) -> None:
    """What an `agents install` leaves behind on a named machine: the baseline of a machine
    that has none, what asks nothing in known.json, and the skills it removed itself."""
    from dotsteward_cli.skills import state as skill_state

    if write_baseline(instance, env):
        return
    scope = _current(instance, env)
    state_root = config.state_root(instance, env)
    known = read_known(state_root)
    if scope["name"] is None or known is None or _lock_broken(instance):
        return
    current = _current_set(instance, scope, state_root)
    open_ids = {item["id"] for item in scope["incoming"]}
    updated = dict(known)
    for key, kind in (("plugins", "plugin"), ("components", "component")):
        updated[key] = sorted(_names(known, key) | {name for name in current[key] if f"{kind}:{name}" not in open_ids})
    if updated != known:
        _write_machine_file(state_root, KNOWN_FILE, updated)
    # A skill this machine removed itself in a commit: its copy goes with the record. One it only
    # scoped away stays: that says nothing about the copy.
    entries = machine.entries_of(machine.read_lock(instance), "skills")
    in_scope = {
        str(entry.get("name")) for entry in entries if scope["reasons"].get(f"skill:{entry.get('name')}") is None
    }
    in_lock = {entry.get("name") for entry in entries}
    base = skill_state.load_base(state_root)
    for name, record in list(_left_behind(instance, base, in_scope, scope["reasons"])):
        if name not in in_lock and f"skill:{name}" not in open_ids:
            _remove_copy(instance, state_root, name, record)


def clash(instance: config.Instance, name: str, digest: str, path: str, *, record: bool, this: str = "") -> bool:
    """Whether the copy at PATH of a third party skill, with DIGEST, is something else than an older
    pin of the lock: a name another machine brought and this machine already used. Only a machine
    that has a base can tell; the history of the lock says what the name ever was. A skill that
    THIS machine brought into the lock is no such name: its copy that differs is drift."""
    from dotsteward_cli.skills import state as skill_state

    state_root = config.state_root(instance)
    if read_known(state_root) is None or f"skill:{name}" in _accepted(None):
        return False
    root = instance.root
    if _git(root, "rev-parse", "--is-shallow-repository").strip() == "true":
        return False
    lock_file = str(instance.config["skills"]["lock"])
    if _git(root, "log", "-1", "--format=%H", f"-S{digest}", "--", lock_file).strip():
        return False
    if this and _brought_here(instance, name, this):
        return False
    if record:
        skill_state.set_item(
            state_root,
            skill_state.skill_key(name),
            {"kind": "skill", "name": name, "path": path, "state": CLASH, "origin": "unknown", "digest": digest},
        )
    return True


def _brought_here(instance: config.Instance, name: str, this: str) -> bool:
    """Whether the commit that vendored the skill NAME is this machine's: its trace line names THIS,
    or no remote has it yet."""
    for entry in machine.entries_of(machine.read_lock(instance), "skills"):
        directory = entry.get("directory")
        if entry.get("name") != name or not isinstance(directory, str):
            continue
        where, pick = [f"{_vendor_path(instance, directory)}/SKILL.md"], ["--diff-filter=A"]
        return _unpublished(instance.root, where, pick) or _source(instance.root, where, pick)["by"] == this
    return False


# --- doing what the answer says ---------------------------------------------------------


def _agents_install(instance: config.Instance, scope: Mapping[str, Any], accepted: Sequence[str]) -> None:
    """The one way a skill and a plugin land: `agents install`, for the skills, the links and
    the hooks at once, told what it may take. An install that fails stays a question."""
    import subprocess

    profile = scope["profile"] or instance.config["profiles"]["check"]
    result = subprocess.run(
        [
            str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"),
            "--instance",
            str(instance.root),
            "agents",
            "install",
            "--profile",
            str(profile),
            "--skip-validation",
        ],
        stdin=subprocess.DEVNULL,
        stdout=sys.stderr,
        env={**os.environ, ACCEPT_ENV: json.dumps(list(accepted))},
        check=False,
    )
    if result.returncode != 0:
        raise Refusal(f"agents install failed (exit {result.returncode}); it stays a question")


def _remove_copy(instance: config.Instance, state_root: str, name: str, record: Mapping[str, Any]) -> None:
    """The copy goes, after a backup, with the links to it. A copy that is a link out of the skill
    roots is the user's tree: only the link goes."""
    import datetime
    import shutil

    from dotsteward_cli import atomic
    from dotsteward_cli.skills import layout
    from dotsteward_cli.skills import state as skill_state

    local = record.get("local_path")
    if isinstance(local, str) and os.path.lexists(local):
        real = os.path.realpath(local)
        where = layout.read(instance)
        managed = (*where.search_roots, *where.link_roots, where.scoped_store)
        inside = any(real.startswith(os.path.realpath(root) + os.sep) for root in managed)
        for root in (*where.link_roots, *where.agent_roots.values()):
            for candidate in (name, os.path.basename(local)):
                path = os.path.join(root, candidate)
                if os.path.islink(path) and path != local and os.path.realpath(path) == real:
                    os.unlink(path)
        if os.path.islink(local):
            os.unlink(local)
        if inside and os.path.isdir(real):
            stamp = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H%M%SZ")
            backups = Path(state_root) / "backups" / f"{stamp}-skills"
            atomic.make_private_dirs(backups.parent)
            atomic.make_private_dirs(backups)
            shutil.copytree(real, backups / os.path.basename(real), symlinks=True, dirs_exist_ok=True)
            shutil.rmtree(real)
            _say(f"skill {name}: removed; the copy is in {backups}")
        else:
            _say(f"skill {name}: the link is gone; {real} stays")
    skill_state.forget_base(state_root, name)
    skill_state.drop_item(state_root, skill_state.skill_key(name))


def _drop_review(state_root: str, item_id: str) -> None:
    """A question that has its answer leaves the review, whichever command put it there."""
    from dotsteward_cli import report

    report.drop_items(state_root, _REVIEW_CODE, item_id)


def _find(items: Sequence[Mapping[str, Any]], item_id: str) -> Mapping[str, Any]:
    for item in items:
        if item["id"] == item_id:
            return item
    raise Refusal(f"nothing waits under {item_id}; 'dotsteward incoming list' names what does")


def _lock_entry(instance: config.Instance, name: str) -> dict[str, Any] | None:
    for entry in machine.entries_of(machine.read_lock(instance), "skills"):
        if entry.get("name") == name:
            return entry
    return None


def _install(instance: config.Instance, item: Mapping[str, Any], env: Mapping[str, str]) -> str:
    """Does what Install says for ITEM; what it did, for a person."""
    from dotsteward_cli.skills import layout
    from dotsteward_cli.skills import state as skill_state

    state_root = config.state_root(instance, env)
    kind, name, change = str(item["kind"]), str(item["name"]), str(item["change"])
    if change == REMOVED:
        record = skill_state.base_entry(skill_state.load_base(state_root), name)
        if record is not None:
            _remove_copy(instance, state_root, name, record)
        return f"skill {name}: removed from this machine"
    if kind == "component":
        taken = [name, *item.get("needs", [])]
        _accept_components(state_root, taken)
        return f"component {', '.join(taken)}: the next 'dotsteward upgrade' or rebuild activates it"
    _agents_install(instance, _current(instance, env), [str(item["id"])])
    if kind == "skill":
        entry = _lock_entry(instance, name) or {}
        if change == CHANGED:
            record = skill_state.base_entry(skill_state.load_base(state_root), name)
            if record is None or record["base_sha256"] != _lock_digest(entry):
                return f"skill {name}: this copy did not take it; see 'dotsteward skills status'"
        elif layout.find_copy(layout.read(instance), entry) is None:
            raise Refusal(f"skill {name} did not land; it stays a question")
        if change == CLASH:
            skill_state.drop_item(state_root, skill_state.skill_key(name))
    return f"installed {kind} {name}"


def _never(instance: config.Instance, this: str, item: Mapping[str, Any], env: Mapping[str, str]) -> str:
    """Does what Never says for ITEM: at once on this machine, in the host file as soon as
    the remote answers. A skill also says so in pending.json, where skill tracking looks: a copy
    that stays is no new skill of this machine."""
    from dotsteward_cli.skills import state as skill_state

    state_root = config.state_root(instance, env)
    kind, name = str(item["kind"]), str(item["name"])
    never = never_answers(state_root)
    key = _KIND_KEYS[kind]
    never[key] = sorted({*never.get(key, []), name})
    _write_never(state_root, never)
    if kind == "skill":
        skill_state.forget_base(state_root, name)
        skill_state.set_item(
            state_root,
            skill_state.skill_key(name),
            {"kind": "skill", "name": name, "path": item.get("path"), "state": "declined", "origin": "own"},
        )
    try:
        _publish_never(instance, this, env)
    except _NotEvaluated:
        # This answer cannot stand: it stays a question. Others in the file are not about it.
        now = never_answers(state_root)
        now[key] = [other for other in now.get(key, []) if other != name]
        _write_never(state_root, now)
        raise
    return f"{kind} {name}: never on this machine"


def _evaluates(instance: config.Instance, this: str, commit: str) -> None:
    """A component this machine leaves out must leave a machine that evaluates, or its
    no: tag breaks hosts-eval in the gate of every other machine. A framework pin older
    than the tags has no such output and nothing to say; neither has a machine without Nix."""
    import subprocess

    from dotsteward_cli import publish as publishing

    root = instance.root
    ref = f"refs/dotsteward/{_FETCH_SCOPE}/evaluate"
    publishing.git(root, "update-ref", ref, commit)
    flake = f"git+file://{root}?ref={ref}&rev={commit}"
    attribute = f"{flake}#hostConfigurations.{this}.activationPackage.drvPath"
    override = os.environ.get("DOTSTEWARD_FRAMEWORK_OVERRIDE")
    arguments = ["--no-write-lock-file", "--override-input", "dotsteward", override] if override else []
    try:
        result = subprocess.run(
            ["nix", "--extra-experimental-features", "nix-command flakes", "eval", "--raw", attribute, *arguments],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            check=False,
        )
    except OSError:
        return
    finally:
        publishing.git(root, "update-ref", "-d", ref)
    if result.returncode == 0 or "does not provide attribute" in result.stderr:
        return
    told = [line.strip(" -") for line in result.stderr.splitlines() if "dotsteward:" in line]
    if told or "Failed assertions" in result.stderr:
        raise _NotEvaluated("this machine does not evaluate without it: " + "; ".join(told or [result.stderr.strip()]))
    # Not a word about the answer: the store, the network. It stays a question, and says why.
    last = result.stderr.strip().splitlines()[-1:] or ["no message"]
    raise _NotEvaluated(f"could not check this answer with Nix: {last[0]}")


def _publish_never(instance: config.Instance, this: str, env: Mapping[str, str]) -> None:
    """Brings the answers that wait to the host file on the remote, and the checkout along."""
    from dotsteward_cli import host, report

    state_root = config.state_root(instance, env)
    pending = never_answers(state_root)
    if not any(pending.values()):
        return
    check = (lambda commit: _evaluates(instance, this, commit)) if pending.get("components") else None
    try:
        code = host.publish(instance, env, declined=pending, check=check)
    except host.Refusal as refused:
        raise Refusal(f"{refused}; the answer holds here and waits") from refused
    if code == report.PRIVACY_STOP:
        _say("the privacy scan stopped the host file: the answer holds here; look at the finding above")
        return
    if code != report.OK:
        _say("the answer waits for the remote: it holds here, a later 'dotsteward incoming' publishes it")
        return
    move_forward(instance, quiet=True)
    _clear_never(instance, this, env)


def _clear_never(instance: config.Instance, this: str, env: Mapping[str, str]) -> None:
    """An answer that stands in the host file of the checkout needs no second place."""
    state_root = config.state_root(instance, env)
    declined = (machine.read_host(instance.root, this) or {}).get("declined", {})
    _write_never(
        state_root,
        {
            key: [name for name in names if name not in declined.get(key, [])]
            for key, names in never_answers(state_root).items()
        },
    )


def move_forward(instance: config.Instance, *, quiet: bool = False) -> None:
    """The repository moves forward whatever the answers are: a fast-forward of a clean
    checkout. Anything else is said, and the command goes on with the checkout it has."""
    from dotsteward_cli import publish as publishing

    root = instance.root
    branch = str(instance.config["instance"]["branch"])
    outcome, tip, detail = publishing.fetch_tip(root, branch, _FETCH_SCOPE)
    if outcome != publishing.OK:
        if not quiet:
            _say(f"no network or no answer from the remote ({detail or 'timeout'}): looking at this checkout as it is")
        return
    head = publishing.git(root, "rev-parse", "HEAD").stdout.strip()
    if head == tip or publishing.is_ancestor(root, tip, head):
        return
    if _git(root, "status", "--porcelain").strip():
        _say("the checkout has uncommitted changes: it stays where it is, behind the remote")
        return
    if not publishing.is_ancestor(root, head, tip):
        _say("the checkout and the remote went apart: it stays where it is; publish its commits first")
        return
    moved = publishing.git(root, "merge", "--quiet", "--ff-only", tip)
    if moved.code != 0:
        _say(f"cannot fast-forward the checkout: {moved.stderr.strip()}")


# --- the question ------------------------------------------------------------------------


_CHANGE_WORDS = {CLASH: "a copy here has this name"}
_WHY_LEFT = {
    "declined": "which this machine declined",
    "machines": "which is for other machines",
    "tags": "which is for other machine tags",
    "disabled": "which the instance does not enable",
}


def describe(item: Mapping[str, Any]) -> str:
    who = f"machine {item['by']}" if item.get("by") else "an unknown machine"
    change = (
        "no longer for this machine" if item.get("scoped_away") else _CHANGE_WORDS.get(item["change"], item["change"])
    )
    related = ""
    if item.get("needs"):
        related += f", needs {', '.join(item['needs'])}"
    if item.get("needed_by"):
        related += f", needed by {', '.join(item['needed_by'])}"
    return f"{item['kind']} {item['name']} ({change}{related}) - {who}, {_pretty_time(item.get('when'))}"


def _prompt(item: Mapping[str, Any]) -> str:
    if item["change"] == REMOVED:
        choices = "[R]emove, keep and ask [L]ater, [N]ever ask again on this machine, show [D]etails"
    elif item["change"] == CLASH:
        choices = "[I]nstall over it with a backup, ask [L]ater, [N]ever on this machine, show [D]etails"
    else:
        choices = "[I]nstall, ask [L]ater, [N]ever on this machine, show [D]etails"
    return f"{describe(item)}. {choices}: "


def _component_text(instance: config.Instance, name: str) -> list[str]:
    from dotsteward_cli.skills import layout

    table = instance.config["components"].get(name, {})
    lines = [
        f"{key}: {value}" for key, value in table.items() if value not in (None, {}, [], False) and key != "enable"
    ]
    for entry in layout.manifest(instance).get("components") or []:
        if entry.get("name") == name:
            lines.append(f"method: {entry.get('method')}")
            lines += [f"needs: {', '.join(entry['requires'])}"] if entry.get("requires") else []
    return lines


def show_text(instance: config.Instance, item: Mapping[str, Any], env: Mapping[str, str] | None = None) -> str:
    """What an answer is about: what an install would change here."""
    import subprocess

    from dotsteward_cli.skills import normal
    from dotsteward_cli.skills import state as skill_state

    root = instance.root
    lines = [describe(item)]
    name = str(item["name"])
    if item["kind"] == "skill":
        if item["change"] == REMOVED:
            lines.append(f"the repository holds no {name} for this machine any more; the copy here: {item.get('path')}")
            record = skill_state.base_entry(skill_state.load_base(config.state_root(instance, env)), name)
            try:
                digest = normal.normal_form(os.path.realpath(str(item.get("path"))), None).digest
            except (OSError, RuntimeError):
                digest = None
            if record is not None and digest != record["base_sha256"]:
                lines.append("it was edited here since it was last in sync; a removal keeps a backup")
        else:
            entry = _lock_entry(instance, name) or {}
            source = root / _vendor_path(instance, str(entry.get("directory") or name))
            if item["change"] == NEW:
                files = sorted(str(path.relative_to(source)) for path in source.rglob("*") if path.is_file())
                lines.append("files: " + ", ".join(files))
                text = (source / "SKILL.md").read_text(encoding="utf-8", errors="replace").splitlines()
                lines += text[:_SHOW_LINES]
            else:
                answer = subprocess.run(
                    ["git", "--no-pager", "diff", "--no-index", "--", str(item.get("path")), str(source)],
                    capture_output=True,
                    text=True,
                    errors="replace",
                    check=False,
                )
                lines += answer.stdout.splitlines()
    elif item["kind"] == "plugin":
        for plugin in machine.plugin_entries(instance):
            if plugin.get("spec") == name:
                lines.append(json.dumps(plugin, indent=2, sort_keys=True, ensure_ascii=False))
    else:
        lines += _component_text(instance, name)
    return "\n".join(lines)


def _read_answer(prompt: str) -> str:
    print(prompt, end="", file=sys.stderr, flush=True)
    line = sys.stdin.readline()
    # A closed terminal is the same as no answer at all.
    return line.strip().lower()[:1] if line else "l"


def _tell(run: report.RunReport, requires: Mapping[str, Sequence[Mapping[str, str]]]) -> None:
    """What `requires` means here is for the person here: said now and kept as a note."""
    for entry in requires["arriving"]:
        text = f"component {entry['component']} comes with this tree: {entry['needed_by']} needs it"
        _say(text)
        run.item("component-needed", pending=False, message=text, **entry)
    for entry in requires["unmet"]:
        why = _WHY_LEFT.get(entry["why"], f"which this machine leaves out ({entry['why']})")
        text = f"component {entry['component']} is left out: it needs {entry['needs']}, {why}"
        _say(text)
        run.item("requires-unmet", pending=False, message=text, **entry)


def ask(
    instance: config.Instance,
    run: report.RunReport,
    *,
    terminal: bool,
    env: Mapping[str, str] | None = None,
) -> list[dict[str, Any]]:
    """The question about what waits, one item at a time; for `dotsteward incoming` and for
    `upgrade`, which brings the repository forward first. Without a terminal every item is
    Ask later and an entry of RUN, which makes the run end in 3. What still waits comes back."""
    env = os.environ if env is None else env
    write_baseline(instance, env)
    this = _current(instance, env)["name"]
    if this is None:
        return []
    try:
        _publish_never(instance, this, env)
    except _NotEvaluated as refused:
        _say(f"ERROR: {refused}; these answers are questions again")
        state_root = config.state_root(instance, env)
        _write_never(state_root, {**never_answers(state_root), "components": []})
    except Refusal as refused:
        _say(f"ERROR: {refused}")
    scope = _current(instance, env)
    _tell(run, scope["requires"])
    items: list[dict[str, Any]] = list(scope["incoming"])
    state_root = config.state_root(instance, env)
    if not terminal:
        for item in items:
            run.item(_REVIEW_CODE, **{key: item[key] for key in item if key in _REVIEW_FIELDS})
        return items
    if items:
        _say(f"{len(items)} change{'s' if len(items) != 1 else ''} from other machines wait for an answer")
    left: list[dict[str, Any]] = []
    for item in items:
        accepted = ("r" if item["change"] == REMOVED else "i", "l", "n", "")
        while True:
            given = _read_answer(_prompt(item))
            if given == "d":
                print(show_text(instance, item, env), file=sys.stderr, flush=True)
            elif given in accepted:
                break
        try:
            if given == accepted[0]:
                said = _install(instance, item, env)
            elif given == "n":
                said = _never(instance, this, item, env)
            else:
                left.append(item)
                continue
        except Refusal as refused:
            # One answer that does not stand keeps the others.
            _say(f"ERROR: {refused}")
            left.append(item)
            continue
        print(f"[dotsteward] {said}", file=sys.stderr, flush=True)
        _drop_review(state_root, str(item["id"]))
    return left


_REVIEW_FIELDS = ("id", "kind", "change", "name", "by", "when", "show", "answer", "needs", "needed_by")


def answer(instance: config.Instance, item_id: str, *, never: bool, env: Mapping[str, str] | None = None) -> str:
    """The answer to one question, for a person or an agent: what it did."""
    env = os.environ if env is None else env
    scope = _current(instance, env)
    if scope["name"] is None:
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    state_root = config.state_root(instance, env)
    item = _find(scope["incoming"], item_id)
    said = _never(instance, scope["name"], item, env) if never else _install(instance, item, env)
    _drop_review(state_root, item_id)
    return said


# --- command line --------------------------------------------------------------------------


def _parser() -> Any:
    import argparse

    parser = argparse.ArgumentParser(
        prog="dotsteward incoming",
        description=(
            "What other machines changed. The repository moves forward by itself; a new or changed skill, plugin "
            "or component lands on this machine only when the answer says so: install, ask later, or never on "
            "this machine. Without a subcommand: brings the checkout forward and asks, one item at a time; without "
            "a terminal every item is ask later, review.json holds the questions and the exit status is 3."
        ),
        epilog="Exit status: 0 done, 1 refusal, 2 usage error, 3 questions wait and no terminal can answer them.",
        allow_abbrev=False,
    )
    parser.add_argument("--json", action="store_true", help="print one JSON document")
    commands = parser.add_subparsers(dest="subcommand", metavar="SUBCOMMAND")
    listing = commands.add_parser("list", help="what waits, without a fetch", allow_abbrev=False)
    listing.add_argument("--json", action="store_true", help="print one JSON document")
    show = commands.add_parser("show", help="what an item is about", allow_abbrev=False)
    show.add_argument("id", metavar="ID")
    show.add_argument("--json", action="store_true", help="print one JSON document")
    reply = commands.add_parser(
        "answer",
        help="answer one item",
        description=(
            "--install installs a skill or a plugin at once, removes what the repository no longer holds for this "
            "machine, and leaves a component to the next upgrade or rebuild, with what it needs; --never records the "
            "answer in the host file of this machine. To ask later, do nothing."
        ),
        allow_abbrev=False,
    )
    reply.add_argument("id", metavar="ID")
    choice = reply.add_mutually_exclusive_group(required=True)
    choice.add_argument("--install", action="store_true", help="take the change")
    choice.add_argument("--never", action="store_true", help="never on this machine")
    reply.add_argument("--json", action="store_true", help="print one JSON document")
    return parser


def _print_items(items: Sequence[Mapping[str, Any]]) -> None:
    if not items:
        print("[dotsteward] nothing waits")
    for item in items:
        print(describe(item))
        print(f"  {item['show']}")
        print(f"  {item['answer']}")


def _answers_lock(state_root: str) -> Any:
    """One answer at a time on a machine."""
    from dotsteward_cli import atomic, locks

    atomic.make_private_dirs(state_root)
    atomic.make_private_dirs(Path(state_root) / "machine")
    return locks.FileLock(Path(state_root) / "machine" / "incoming.lock")


def _ask_command(args: Any, instance: config.Instance, env: Mapping[str, str]) -> int:
    from dotsteward_cli import report

    state_root = config.state_root(instance, env)
    scope = _current(instance, env)
    if scope["name"] is None:
        _say("this machine has no name, so nothing is asked; 'dotsteward host init' names it")
        return report.OK
    lock = _answers_lock(state_root)
    lock.acquire()
    try:
        move_forward(instance)
        instance = config.load_instance()
        run = report.RunReport("incoming", state_root)
        terminal = sys.stdin.isatty() and not args.json
        left = ask(instance, run, terminal=terminal, env=env)
        run.step("ask", report.OK, waiting=len(left))
        run.write()
    finally:
        lock.release()
    if args.json:
        print(json.dumps({"machine": scope["name"], "items": left}, indent=2, ensure_ascii=False))
    elif not terminal:
        _print_items(left)
    return run.exit_code


def main(argv: Sequence[str] | None = None) -> int:
    from dotsteward_cli import locks, report

    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments == ["settle"]:
        # For `agents install`, not for a person.
        try:
            settle(config.load_instance())
        except (config.DotstewardError, OSError) as failure:
            print(f"[dotsteward] WARNING: incoming: {failure}", file=sys.stderr)
        return report.OK
    if arguments[:1] == ["clash"]:
        # For `agents install` and `agents check`, not for a person.
        name, digest, path, mode = arguments[2], arguments[4], arguments[6], arguments[8]
        this = arguments[10] if arguments[9:10] == ["--machine"] and len(arguments) > 10 else ""
        found = clash(config.load_instance(), name, digest, path, record=mode == "install", this=this)
        print("clash" if found else "no")
        return report.OK
    parser = _parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as stopped:
        return EXIT_USAGE if stopped.code == 2 else int(stopped.code or 0)
    env = os.environ
    try:
        instance = config.load_instance()
        if args.subcommand is None:
            return _ask_command(args, instance, env)
        scope = _current(instance, env)
        items = scope["incoming"]
        if args.subcommand == "list":
            if args.json:
                print(json.dumps({"machine": scope["name"], "items": items}, indent=2, ensure_ascii=False))
            else:
                _print_items(items)
            return report.OK
        if args.subcommand == "show":
            item = _find(items, args.id)
            text = show_text(instance, item, env)
            print(json.dumps({**item, "text": text}, indent=2, ensure_ascii=False) if args.json else text)
            return report.OK
        lock = _answers_lock(config.state_root(instance, env))
        lock.acquire()
        try:
            said = answer(instance, args.id, never=args.never, env=env)
        finally:
            lock.release()
        print(json.dumps({"id": args.id, "done": said}) if args.json else f"[dotsteward] {said}")
        return report.OK
    except UsageError as usage:
        print(f"[dotsteward] ERROR: {usage}", file=sys.stderr)
        return EXIT_USAGE
    except (Refusal, locks.LockBusy) as refusal:
        print(f"[dotsteward] ERROR: {refusal}", file=sys.stderr)
        return EXIT_REFUSAL
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return EXIT_REFUSAL
    except OSError as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return EXIT_REFUSAL
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
