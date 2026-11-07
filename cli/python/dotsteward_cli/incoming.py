"""What other machines changed, and what this machine makes of it.

The repository always moves forward; what lands on this machine depends on the answer:
install, ask later, or never on this machine. Nothing keeps a cursor or a queue of
questions: every run compares the tree with what this machine holds, so ``waiting`` is a
pure look at the checkout, ``<state>/skills/base.json`` and ``<state>/machine/known.json``:

    skill, own           new: in scope, in the lock, no b, no copy here
                         changed: lock != b and the copy is still b (threeway: incoming)
                         removed: b exists, the lock has no such skill for this machine
    skill, third party   new: in scope, in the lock, not known, no copy here
    plugin               new: in scope, not known
    component            new: enabled, in scope, for this profile, not known

Everything else another machine changes needs no question: the pins of the producer and
the rest of the intent arrive with the next ``rebuild``, as a whole tree. What another
machine scoped away from this one (``machines``) is never new here: ``machine.effective``
takes it out first.

``known.json`` is ``{schema_version, machine, components, plugins, skills: {name: digest},
never: {components, skills, plugins}}``. An accepted skill stands there with the digest it was
accepted at, so ``agents install`` takes it the usual way; ``never`` holds an answer until
the host file in the checkout does. A machine set up before this release has no
known.json: ``agents install`` writes what it holds, and nothing is asked. A machine
without a name has no other machines to hear from, and behaves as it always did.

A change is this machine's own when a commit that is not published yet touches its path,
or when the last commit that did says ``Dotsteward-Machine: <this machine>``: such an
item is accepted without a question. No such line names an unknown machine.

Answers: ``Install`` (``base.json`` or ``known.json``, then ``agents install``; a component
waits for the next rebuild), nothing for ``Ask later``, and ``Never`` (``declined`` in
``hosts/<name>.toml`` with a commit of its own, published without force; without a network
the answer holds here and is published by a later run).

Exit status: 0 done, 1 refusal, 2 usage error; ``incoming`` without a subcommand also 3,
when questions wait and no terminal can answer them (``review.json`` holds them).

Python API: ``waiting``, ``read_known``, ``write_baseline``, ``settle``, ``ask``,
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


def _known_path(state_root: str | os.PathLike[str]) -> Path:
    return Path(state_root) / KNOWN_FILE


def read_known(state_root: str | os.PathLike[str], name: str) -> dict[str, Any] | None:
    """What the machine NAME knows, None when it has not said yet. A file that cannot be
    read says nothing, and so does a file of another name (this state took a new name):
    a question too few is better than a question about everything."""
    try:
        document = json.loads(_known_path(state_root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return document if isinstance(document, dict) and document.get("machine") == name else None


def _write_known(state_root: str | os.PathLike[str], document: Mapping[str, Any]) -> None:
    from dotsteward_cli import atomic

    path = _known_path(state_root)
    atomic.make_private_dirs(state_root)
    atomic.make_private_dirs(path.parent)
    atomic.atomic_write_json(path, document, mode=0o600)


def _table(document: Mapping[str, Any], key: str) -> dict[str, Any]:
    value = document.get(key)
    return dict(value) if isinstance(value, dict) else {}


def _names(document: Mapping[str, Any] | None, key: str) -> set[str]:
    values = document.get(key) if document else None
    return {str(value) for value in values} if isinstance(values, (list, dict)) else set()


def never_answers(state_root: str | os.PathLike[str], name: str) -> dict[str, list[str]]:
    """The answers ``Never`` the host file in the checkout does not hold yet."""
    never = (read_known(state_root, name) or {}).get("never")
    if not isinstance(never, dict):
        return {}
    return {str(key): [str(name) for name in value] for key, value in never.items() if isinstance(value, list)}


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


def _vendor_path(instance: config.Instance, directory: str) -> str:
    return f"{str(instance.config['skills']['vendor_dir']).rstrip('/')}/{directory}"


def _lock_digest(entry: Mapping[str, Any]) -> str:
    return str(entry.get("directory_sha256") or entry.get("skill_sha256") or "")


def _unpublished(root: Path, *where: str, text: str | None = None) -> bool:
    """Whether a commit no remote has seen touches WHERE, or adds or removes TEXT there. Every
    fetch leaves its tip in origin/* or refs/dotsteward/*, so a checkout moved to a tip has no
    such commit."""
    arguments = ["log", "-1", "--format=%H", "HEAD", "--not", "--remotes=origin", "--glob=refs/dotsteward/*"]
    if text is not None:
        arguments.append(f"-S{text}")
    return bool(_git(root, *arguments, "--", *where).strip())


def _source(root: Path, *where: str, text: str | None = None, pattern: str | None = None) -> dict[str, Any]:
    """The last commit that touched WHERE, added or removed TEXT there, or changed a line
    with PATTERN: the machine its message names, and when."""
    arguments = ["log", "-1", "--format=%cI%x00%B"]
    if text is not None:
        arguments.append(f"-S{text}")
    if pattern is not None:
        arguments.append(f"-G{pattern}")
    answer = _git(root, *arguments, "--", *where)
    moment, _, message = answer.partition("\0")
    found = _TRAILER.findall(message)
    return {"by": found[-1] if found else None, "when": moment.strip() or None}


def _pretty_time(moment: str | None) -> str:
    import datetime

    if not moment:
        return "unknown time"
    try:
        return datetime.datetime.fromisoformat(moment).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return moment


# --- what waits --------------------------------------------------------------------------


def _item(
    instance: config.Instance,
    this: str,
    kind: str,
    change: str,
    name: str,
    where: Sequence[str],
    text: str | None = None,
    pattern: str | None = None,
    sources: Sequence[str] | None = None,
    **extra: Any,
) -> dict[str, Any] | None:
    """The question about NAME, None when the change is this machine's own: WHERE are the
    paths of the change, SOURCES (default: the same), TEXT and PATTERN find its commit."""
    root = instance.root
    if _unpublished(root, *where, text=None if sources else text):
        return None
    origin = _source(root, *(sources or where), text=text, pattern=pattern)
    if origin["by"] == this:
        return None
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
    known: Mapping[str, Any],
    reasons: Mapping[str, str],
    lock: Mapping[str, Any],
) -> list[dict[str, Any]]:
    from dotsteward_cli.skills import layout, threeway
    from dotsteward_cli.skills import state as skill_state

    entries = machine.entries_of(lock, "skills")
    base = skill_state.load_base(state_root)
    accepted = _table(known, "skills")
    own = _own_revisions(instance)
    lock_file = str(instance.config["skills"]["lock"])
    where: layout.Layout | None = None
    items: list[dict[str, Any] | None] = []
    in_scope: set[str] = set()
    for entry in entries:
        name, directory = entry.get("name"), entry.get("directory")
        if not isinstance(name, str) or not isinstance(directory, str):
            continue
        reason = reasons.get(f"skill:{name}")
        if reason in (machine.REASON_MACHINES, machine.REASON_DECLINED):
            continue
        in_scope.add(name)
        if entry.get("deployment", "copy") != "copy":
            continue
        digest = _lock_digest(entry)
        record = skill_state.base_entry(base, name) if entry.get("revision") in own else None
        vendor = _vendor_path(instance, directory)
        if record is None:
            if name in accepted:
                continue
            where = where or layout.read(instance)
            if layout.find_copy(where, entry) is not None:
                continue
            items.append(_item(instance, this, "skill", NEW, name, [vendor]))
        elif record["base_sha256"] != digest and accepted.get(name) != digest:
            where = where or layout.read(instance)
            try:
                answer = threeway.assess(name, layout.find_copy(where, entry), digest, str(instance.root), state_root)
            except (OSError, RuntimeError):
                # A copy that cannot be read is no reason for a command to fail; `skills status` says it.
                continue
            if answer["state"] == threeway.INCOMING:
                items.append(_item(instance, this, "skill", CHANGED, name, [vendor], path=answer["path"]))
    for name, record in _left_behind(instance, base, in_scope, reasons):
        local = record.get("local_path")
        if not (isinstance(local, str) and os.path.isfile(os.path.join(local, "SKILL.md"))):
            continue
        vendor = _vendor_path(instance, os.path.basename(local))
        scoped_away = reasons.get(f"skill:{name}") == machine.REASON_MACHINES
        items.append(
            _item(
                instance,
                this,
                "skill",
                REMOVED,
                name,
                [vendor],
                sources=[lock_file] if scoped_away else [vendor, lock_file],
                pattern='"machines"' if scoped_away else None,
                text=None if scoped_away else f'"{name}"',
                path=local,
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
            items.append(_item(instance, this, "plugin", NEW, plugin, [config.CONFIG_FILE], text=plugin))
    for entry in machine.entries_of(lock, "own_plugins"):
        own = entry.get("name")
        if isinstance(own, str) and own not in seen and f"plugin:{own}" not in reasons:
            items.append(_item(instance, this, "plugin", NEW, own, [lock_file], text=own))
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
        items.append(_item(instance, this, "component", NEW, name, [config.CONFIG_FILE], text=f"[components.{name}]"))
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
    known = read_known(state_root, name)
    if known is None:
        return []
    lock = machine.read_lock(instance)
    if not isinstance(lock.get("skills"), list):
        # A lock that cannot be read says nothing about any item, only that it says nothing.
        return []
    return [
        *_skill_items(instance, state_root, name, known, reasons, lock),
        *_plugin_items(instance, name, known, reasons, lock),
        *_component_items(instance, state_root, name, known, reasons),
    ]


def _current(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    return machine.effective(instance, env)


def _current_set(instance: config.Instance, scope: Mapping[str, Any]) -> dict[str, Any]:
    """What is in scope for this machine now, as known.json holds it."""
    reasons = scope["reasons"]
    lock = machine.read_lock(instance)
    skills = {}
    for entry in machine.entries_of(lock, "skills"):
        name = entry.get("name")
        if isinstance(name, str) and reasons.get(f"skill:{name}") not in (
            machine.REASON_MACHINES,
            machine.REASON_DECLINED,
        ):
            skills[name] = _lock_digest(entry)
    plugins = {str(p["spec"]) for p in machine.plugin_entries(instance) if isinstance(p.get("spec"), str)}
    plugins |= {str(p["name"]) for p in machine.entries_of(lock, "own_plugins") if isinstance(p.get("name"), str)}
    plugins = {plugin for plugin in plugins if reasons.get(f"plugin:{plugin}") != machine.REASON_MACHINES}
    components = {name for name, _ in machine.enabled_components(instance)}
    components = {name for name in components if reasons.get(f"component:{name}") != machine.REASON_MACHINES}
    return {"skills": skills, "plugins": sorted(plugins), "components": sorted(components)}


def write_baseline(instance: config.Instance, env: Mapping[str, str] | None = None) -> bool:
    """A named machine without known.json knows what it holds now: no question comes out of
    it. Whether it wrote the file."""
    state_root = config.state_root(instance, env)
    scope = _current(instance, env)
    if scope["name"] is None or read_known(state_root, scope["name"]) is not None:
        return False
    _write_known(
        state_root, {"schema_version": SCHEMA_VERSION, "machine": scope["name"], **_current_set(instance, scope)}
    )
    return True


def _accept(state_root: str, this: str, item: Mapping[str, Any], digest: str | None = None) -> None:
    known = read_known(state_root, this) or {"schema_version": SCHEMA_VERSION, "machine": this}
    if item["kind"] == "skill":
        skills = _table(known, "skills")
        skills[str(item["name"])] = digest or ""
        known["skills"] = skills
    else:
        key = _KIND_KEYS[str(item["kind"])]
        known[key] = sorted(_names(known, key) | {str(item["name"])})
    _write_known(state_root, known)


def settle(instance: config.Instance, env: Mapping[str, str] | None = None) -> None:
    """What an `agents install` leaves behind on a named machine: the baseline of a machine
    that has none, everything of its own in known.json, and the answers of its own that
    took a skill away."""
    from dotsteward_cli.skills import state as skill_state

    if write_baseline(instance, env):
        return
    scope = _current(instance, env)
    if scope["name"] is None:
        return
    state_root = config.state_root(instance, env)
    known = read_known(state_root, scope["name"])
    if known is None:
        return
    current = _current_set(instance, scope)
    open_ids = {item["id"] for item in waiting(instance, scope["name"], scope["reasons"], env)}
    reasons = scope["reasons"]
    held = _table(known, "skills")
    updated = dict(known)
    # What is here and asks nothing is known from now on, so later commits cannot make it new.
    for name, digest in current["skills"].items():
        if f"skill:{name}" not in open_ids and reasons.get(f"skill:{name}") != machine.REASON_INCOMING:
            held.setdefault(name, digest)
    updated["skills"] = held
    for key, kind in (("plugins", "plugin"), ("components", "component")):
        updated[key] = sorted(_names(known, key) | {name for name in current[key] if f"{kind}:{name}" not in open_ids})
    if updated != known:
        _write_known(state_root, updated)
    # A skill this machine removed itself in a commit: its copy goes with the record.
    base = skill_state.load_base(state_root)
    lock = machine.read_lock(instance)
    in_lock = {entry.get("name") for entry in machine.entries_of(lock, "skills")}
    if not isinstance(lock.get("skills"), list):
        return
    for name, record in list(_left_behind(instance, base, current["skills"], reasons)):
        if name not in in_lock and f"skill:{name}" not in open_ids:
            _remove_copy(instance, state_root, name, record)


# --- doing what the answer says ---------------------------------------------------------


def _agents_install(instance: config.Instance, scope: Mapping[str, Any]) -> None:
    """The one way a skill and a plugin land: `agents install`, for the skills, the links and
    the hooks at once."""
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
        check=False,
    )
    if result.returncode != 0:
        raise Refusal(f"agents install failed (exit {result.returncode}); the answer stands, the next rebuild goes on")


def _remove_copy(instance: config.Instance, state_root: str, name: str, record: Mapping[str, Any]) -> None:
    import datetime
    import shutil

    from dotsteward_cli import atomic
    from dotsteward_cli.skills import layout
    from dotsteward_cli.skills import state as skill_state

    local = record.get("local_path")
    if isinstance(local, str) and os.path.isdir(local):
        stamp = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H%M%SZ")
        backups = Path(state_root) / "backups" / f"{stamp}-skills"
        atomic.make_private_dirs(backups.parent)
        atomic.make_private_dirs(backups)
        real = os.path.realpath(local)
        shutil.copytree(real, backups / os.path.basename(real), symlinks=True, dirs_exist_ok=True)
        where = layout.read(instance)
        for root in (*where.link_roots, *where.agent_roots.values()):
            for candidate in (name, os.path.basename(local)):
                path = os.path.join(root, candidate)
                if os.path.islink(path) and os.path.realpath(path) == real:
                    os.unlink(path)
        if os.path.islink(local):
            os.unlink(local)
        if os.path.isdir(real):
            shutil.rmtree(real)
        _say(f"skill {name}: removed; the copy is in {backups}")
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


def _install(
    instance: config.Instance, this: str, item: Mapping[str, Any], *, now: bool, env: Mapping[str, str]
) -> str:
    """Does what Install says for ITEM; what it did, for a person."""
    from dotsteward_cli.skills import state as skill_state

    state_root = config.state_root(instance, env)
    kind, name, change = str(item["kind"]), str(item["name"]), str(item["change"])
    if kind == "skill" and change == REMOVED:
        record = skill_state.base_entry(skill_state.load_base(state_root), name)
        if record is not None:
            _remove_copy(instance, state_root, name, record)
        return f"skill {name}: removed from this machine"
    if kind == "skill":
        entry = _lock_entry(instance, name) or {}
        _accept(state_root, this, item, _lock_digest(entry))
    else:
        _accept(state_root, this, item)
    if kind == "component":
        return f"component {name}: the next 'dotsteward upgrade' or rebuild activates it"
    if not now:
        return f"{kind} {name}: accepted; the next rebuild installs it"
    _agents_install(instance, _current(instance, env))
    if kind == "skill" and change == CHANGED:
        record = skill_state.base_entry(skill_state.load_base(state_root), name)
        if record is None or record["base_sha256"] != _lock_digest(_lock_entry(instance, name) or {}):
            return f"skill {name}: this copy did not take it; see 'dotsteward skills status'"
    return f"installed {kind} {name}"


def _never(instance: config.Instance, this: str, item: Mapping[str, Any], env: Mapping[str, str]) -> str:
    """Does what Never says for ITEM: at once on this machine, in the host file as soon as
    the remote answers."""
    from dotsteward_cli.skills import state as skill_state

    state_root = config.state_root(instance, env)
    kind, name = str(item["kind"]), str(item["name"])
    known = read_known(state_root, this) or {"schema_version": SCHEMA_VERSION, "machine": this}
    never = _table(known, "never")
    key = _KIND_KEYS[kind]
    listed = never.get(key)
    never[key] = sorted({*(str(value) for value in (listed if isinstance(listed, list) else [])), name})
    known["never"] = never
    _write_known(state_root, known)
    if kind == "skill":
        skill_state.forget_base(state_root, name)
        skill_state.drop_item(state_root, skill_state.skill_key(name))
    _publish_never(instance, this, env)
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
    try:
        result = subprocess.run(
            ["nix", "--extra-experimental-features", "nix-command flakes", "eval", "--raw", attribute],
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
    if result.returncode != 0 and "does not provide attribute" not in result.stderr:
        told = [line.strip(" -") for line in result.stderr.splitlines() if "dotsteward:" in line] or [
            result.stderr.strip()
        ]
        raise _NotEvaluated("this machine does not evaluate without it: " + "; ".join(told))


def _publish_never(instance: config.Instance, this: str, env: Mapping[str, str]) -> None:
    """Brings the answers that wait to the host file on the remote, and the checkout along."""
    from dotsteward_cli import host, report

    state_root = config.state_root(instance, env)
    pending = never_answers(state_root, this)
    if not any(pending.values()):
        return
    check = (lambda commit: _evaluates(instance, this, commit)) if pending.get("components") else None
    try:
        code = host.publish(instance, env, declined=pending, check=check)
    except _NotEvaluated:
        # This answer cannot stand: it stays a question.
        known = read_known(state_root, this)
        if known is not None:
            never = {key: value for key, value in _table(known, "never").items() if key != "components"}
            _write_known(state_root, {**known, "never": never})
        raise
    except host.Refusal as refused:
        raise Refusal(f"{refused}; the answer holds here and waits") from refused
    if code != report.OK:
        _say("the answer waits for the remote: it holds here, a later 'dotsteward incoming' publishes it")
        return
    move_forward(instance, quiet=True)
    _clear_never(instance, this, env)


def _clear_never(instance: config.Instance, this: str, env: Mapping[str, str]) -> None:
    """An answer that stands in the host file of the checkout needs no second place."""
    state_root = config.state_root(instance, env)
    known = read_known(state_root, this)
    if known is None or not isinstance(known.get("never"), dict):
        return
    declined = (machine.read_host(instance.root, this) or {}).get("declined", {})
    never = {
        key: [str(value) for value in values if str(value) not in declined.get(key, [])]
        for key, values in known["never"].items()
        if isinstance(values, list)
    }
    if any(never.values()):
        if never != known["never"]:
            _write_known(state_root, {**known, "never": never})
    else:
        _write_known(state_root, {key: value for key, value in known.items() if key != "never"})


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


def describe(item: Mapping[str, Any]) -> str:
    who = f"machine {item['by']}" if item.get("by") else "an unknown machine"
    return f"{item['kind']} {item['name']} ({item['change']}) - {who}, {_pretty_time(item.get('when'))}"


def _prompt(item: Mapping[str, Any]) -> str:
    if item["change"] == REMOVED:
        choices = "[R]emove, keep and ask [L]ater, [N]ever ask again on this machine, show the [D]ifference"
    else:
        choices = "[I]nstall, ask [L]ater, [N]ever on this machine, show the [D]ifference"
    return f"{describe(item)}. {choices}: "


def show_text(instance: config.Instance, item: Mapping[str, Any], env: Mapping[str, str] | None = None) -> str:
    """What an answer is about: what an install would change here."""
    import subprocess

    root = instance.root
    lines = [describe(item)]
    name = str(item["name"])
    if item["kind"] == "skill":
        if item["change"] == REMOVED:
            lines.append(f"the repository holds no {name} for this machine any more; the copy here: {item.get('path')}")
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
        table = instance.config["components"].get(name, {})
        lines.append(json.dumps(table, indent=2, sort_keys=True, ensure_ascii=False, default=str))
    return "\n".join(lines)


def _read_answer(prompt: str) -> str:
    print(prompt, end="", file=sys.stderr, flush=True)
    line = sys.stdin.readline()
    # A closed terminal is the same as no answer at all.
    return line.strip().lower()[:1] if line else "l"


def ask(
    instance: config.Instance,
    run: report.RunReport,
    *,
    terminal: bool,
    install_now: bool = True,
    env: Mapping[str, str] | None = None,
) -> list[dict[str, Any]]:
    """The question about what waits, one item at a time; for `dotsteward incoming` and for
    `upgrade`, which brings the repository forward first. Without a terminal every item is
    Ask later and an entry of RUN, which makes the run end in 3. What still waits comes back."""
    env = os.environ if env is None else env
    write_baseline(instance, env)
    scope = _current(instance, env)
    this = scope["name"]
    if this is None:
        return []
    try:
        _publish_never(instance, this, env)
    except Refusal as refused:
        _say(f"ERROR: {refused}")
    scope = _current(instance, env)
    items: list[dict[str, Any]] = list(scope["incoming"])
    state_root = config.state_root(instance, env)
    if not terminal:
        for item in items:
            run.item(_REVIEW_CODE, **{key: item[key] for key in item if key in _REVIEW_FIELDS})
        return items
    left: list[dict[str, Any]] = []
    for item in items:
        removal = item["change"] == REMOVED
        accepted = ("r" if removal else "i", "l", "n", "")
        while True:
            answer = _read_answer(_prompt(item))
            if answer == "d":
                print(show_text(instance, item, env), file=sys.stderr, flush=True)
            elif answer in accepted:
                break
        if answer == accepted[0]:
            print(
                f"[dotsteward] {_install(instance, this, item, now=install_now, env=env)}", file=sys.stderr, flush=True
            )
            _drop_review(state_root, str(item["id"]))
        elif answer == "n":
            try:
                print(f"[dotsteward] {_never(instance, this, item, env)}", file=sys.stderr, flush=True)
            except Refusal as refused:
                _say(f"ERROR: {refused}")
                left.append(item)
                continue
            _drop_review(state_root, str(item["id"]))
        else:
            left.append(item)
    return left


_REVIEW_FIELDS = ("id", "kind", "change", "name", "by", "when", "show", "answer")


def answer(instance: config.Instance, item_id: str, *, never: bool, env: Mapping[str, str] | None = None) -> str:
    """The answer to one question, for a person or an agent: what it did."""
    env = os.environ if env is None else env
    scope = _current(instance, env)
    if scope["name"] is None:
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    state_root = config.state_root(instance, env)
    item = _find(scope["incoming"], item_id)
    this = scope["name"]
    said = _never(instance, this, item, env) if never else _install(instance, this, item, now=True, env=env)
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
            "machine, and leaves a component to the next upgrade or rebuild; --never records the answer in the host "
            "file of this machine. To ask later, do nothing."
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


def _ask_command(args: Any, instance: config.Instance, env: Mapping[str, str]) -> int:
    from dotsteward_cli import atomic, locks, report

    state_root = config.state_root(instance, env)
    scope = _current(instance, env)
    if scope["name"] is None:
        _say("this machine has no name, so nothing is asked; 'dotsteward host init' names it")
        return report.OK
    lock = locks.FileLock(Path(state_root) / "machine" / "incoming.lock")
    atomic.make_private_dirs(state_root)
    atomic.make_private_dirs(Path(state_root) / "machine")
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

    if list(sys.argv[1:] if argv is None else argv) == ["settle"]:
        # For `agents install`, not for a person.
        try:
            settle(config.load_instance())
        except (config.DotstewardError, OSError) as failure:
            print(f"[dotsteward] WARNING: incoming: {failure}", file=sys.stderr)
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
        said = answer(instance, args.id, never=args.never, env=env)
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
