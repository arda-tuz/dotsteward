"""Routes every row of a ``pins latest`` report; reads the instance and writes
nothing.

| Row | Route |
| --- | --- |
| ``current``, ``follows``, or the pin is already there | nothing |
| ``--skip`` | line ``skipped`` |
| ``held``, ``manual`` | line |
| ``error`` | line; the group it belongs to does not move |
| marketplace ``git-compare`` (``observed_marketplace_revision``, T7-b) | line ``self-updating`` |
| other ``git-compare`` | item ``pins-review``: moving it is an inspection |
| framework | a major is item ``framework-major``, else group ``framework`` |
| channel input | a newer series is item ``series-available``; a moved branch is group ``channel`` |
| constrained pin | item ``pins-constrained`` |
| skill | a recorded transform is item ``skill-transform``, else group ``skill:<name>`` |
| any other ``update`` or ``review`` | the group its declarations name, else item ``pins-no-writer`` |

A group can still wait when it runs: ``npm-audit``, and for a skill
``skill-local-delta``, ``skill-source-missing``, ``skill-scan-finding``.

Constrained (T18-a keeps these for a person): a field ``*_reason`` on the pin, a
version another rule derives, a ``version`` in ``[components.<name>]`` of the
configuration, a new major of a security override.
"""

from __future__ import annotations

import fnmatch
import json
import subprocess
from dataclasses import dataclass, field
from typing import Any

from dotsteward_cli import versions

from ..checker import GROUP_ERRORS
from ..instance import Instance
from ..latest import model
from ..latest.adapters import CURRENT_FIELDS, Adapter, Planned, Request
from ..latest.adapters.framework import INPUT as FRAMEWORK_INPUT
from ..latest.adapters.framework import ROW_ID as FRAMEWORK_ROW
from ..lockfile import SKILLS, VERSIONS, DeclarationError, LockPath, Locks, Placeholder, load_json, parse_path
from ..rules import Context, Rule, build_rules
from .tools import GroupFailure, Tools, nix_system

MARKETPLACE_FIELD = "observed_marketplace_revision"
HASH_SUFFIX = "_nix_sha256"
ORDER = ("restore", "framework", "channel", "flake", "nix-package", "download", "pypi", "npm", "skill")
Row = dict[str, Any]


@dataclass
class Move:
    """One row that moves: the pin its declaration names, when it has one."""

    row: Row
    path: LockPath | None = None
    component: str = ""
    adapter: Adapter | None = None
    request: Request | None = None

    @property
    def id(self) -> str:
        return str(self.row["id"])

    @property
    def latest(self) -> str:
        return str(self.row["latest"])

    @property
    def details(self) -> dict[str, Any]:
        details: dict[str, Any] = self.row.get("details") or {}
        return details


@dataclass
class Group:
    name: str
    kind: str
    key: str = ""
    moves: list[Move] = field(default_factory=list)
    blocked: list[str] = field(default_factory=list)


@dataclass
class Plan:
    groups: list[Group] = field(default_factory=list)
    lines: list[dict[str, Any]] = field(default_factory=list)
    items: list[dict[str, Any]] = field(default_factory=list)


@dataclass(frozen=True)
class Bundle:
    """A pin of an npm-bundle rule: its dependency, or its security override."""

    rule: Rule
    dependency: str
    override: bool


class Declared:
    """What the rules of the instance say about the lock paths."""

    def __init__(self, instance: Instance, locks: Locks) -> None:
        self.instance = instance
        self.locks = locks
        self.downloads: dict[str, Rule] = {}
        self.derived: dict[str, str] = {}
        self.bundles: dict[str, Bundle] = {}
        self.guards: dict[str, str] = {}
        self.regenerators: dict[str, dict[str, Any]] = {}
        ctx = Context(instance, locks)
        for rule in build_rules(instance):
            try:
                self._read(rule, ctx)
            except GROUP_ERRORS:
                # A rule that cannot be evaluated is what `pins check` reports; it
                # explains no pin here.
                continue

    def _read(self, rule: Rule, ctx: Context) -> None:
        locks = self.locks
        if rule.kind == "download-pin":
            for scope in rule.scopes(ctx):
                if scope.base is not None:
                    self.downloads[scope.base.text()] = rule
        elif rule.kind == "derive" and rule.values["from"] is not None:
            for scope in rule.scopes(ctx):
                target = locks.resolve(rule.values["to"], scope).text()
                self.derived[target] = locks.resolve(rule.values["from"], scope).text()
        elif rule.kind == "derive":
            for scope in rule.scopes(ctx):
                self.derived[locks.resolve(rule.values["to"], scope).text()] = rule.values["template"].source
        elif rule.kind == "npm-bundle":
            self._read_bundle(rule)
        elif rule.kind == "text-guard":
            if rule.values["regenerate"] is not None:
                self.regenerators[rule.values["file"]] = rule.values["regenerate"]
            for scope in rule.scopes(ctx):
                for part in rule.values["template"].parts:
                    if isinstance(part, Placeholder) and part.path is not None:
                        self.guards[locks.resolve(part.path, scope).text()] = rule.values["file"]
                    elif isinstance(part, Placeholder) and part.name == "value" and scope.base is not None:
                        self.guards[scope.base.text()] = rule.values["file"]

    def _read_bundle(self, rule: Rule) -> None:
        locks = self.locks
        if rule.values["dependencies_at"] is not None:
            collection = locks.resolve(rule.values["dependencies_at"])
            for key, _ in locks.entries(collection):
                self.bundles[collection.child(key).text()] = Bundle(rule, key, False)
        for dependency, at, _ in rule.values["mirrors"]:
            self.bundles[locks.resolve(at).text()] = Bundle(rule, dependency, False)
        if rule.values["security_overrides_at"] is not None:
            collection = locks.resolve(rule.values["security_overrides_at"])
            for key, _ in locks.entries(collection):
                self.bundles[collection.child(key).text()] = Bundle(rule, key, True)

    def dependents(self, source: LockPath) -> list[LockPath]:
        """The pin objects a derive rule fills from a field of SOURCE."""
        prefix = source.text() + "."
        targets: dict[str, LockPath] = {}
        for target, origin in self.derived.items():
            if origin.startswith(prefix):
                parent = parse_path(target).parent()[0]
                targets[parent.text()] = parent
        return list(targets.values())


def pin_of(locks: Locks, path: LockPath | None) -> Any:
    if path is None:
        return None
    try:
        return locks.get(path)
    except (KeyError, TypeError):
        return None


def version_field(move: Move, declared: Declared, pin: Any) -> str | None:
    """The field of a pin object that holds the version of its row."""
    if move.path is not None and move.path.text() in declared.downloads:
        return str(declared.downloads[move.path.text()].values["version_field"])
    if move.adapter is not None and move.adapter.values.get("current_field"):
        return str(move.adapter.values["current_field"])
    if isinstance(pin, dict):
        return next((name for name in CURRENT_FIELDS if name in pin), None)
    return None


def hash_fields(pin: Any) -> list[str]:
    return [key for key in pin if key.endswith(HASH_SUFFIX)] if isinstance(pin, dict) else []


def flake_original(instance: Instance) -> dict[str, Any]:
    lock = load_json(instance.path("flake.lock"))
    nodes = lock["nodes"]
    original: dict[str, Any] = nodes[nodes[lock["root"]]["inputs"][FRAMEWORK_INPUT]]["original"]
    return original


def skill_entry(locks: Locks, name: str) -> dict[str, Any] | None:
    document = locks.documents.get(SKILLS)
    entries = document.get("skills", []) if isinstance(document, dict) else []
    return next((entry for entry in entries if isinstance(entry, dict) and entry.get("name") == name), None)


def asset_of(move: Move) -> dict[str, Any]:
    """The asset fields of a row: top level, or those of this platform."""
    details = move.details
    assets = details.get("assets")
    if isinstance(assets, dict):
        system = nix_system()
        platform_name = system.rsplit("-", 1)[1]
        for key in (system, platform_name):
            if isinstance(assets.get(key), dict):
                entry: dict[str, Any] = assets[key]
                return entry
        return {"asset_missing": f"no asset for {system}"}
    return details


def reached(move: Move, instance: Instance, locks: Locks, declared: Declared) -> bool:
    """Whether the pin is already where the row wants it: a saved row on a new tip,
    or a second run with the same rows."""
    pin = pin_of(locks, move.path)
    if move.id == FRAMEWORK_ROW:
        ref = flake_original(instance).get("ref")
        return isinstance(ref, str) and versions.compare(ref.removeprefix("refs/tags/"), move.latest) >= 0
    if move.id.startswith("skills."):
        entry = skill_entry(locks, move.id.removeprefix("skills."))
        return entry is not None and entry.get("revision") == move.details.get("head")
    if isinstance(pin, dict) and "channel" in pin:
        return pin.get("revision") == move.details.get("head")
    current = pin if isinstance(pin, str) else None
    if isinstance(pin, dict):
        name = version_field(move, declared, pin)
        current = pin.get(name) if name else None
    return isinstance(current, str) and bool(move.latest) and versions.compare(current, move.latest) >= 0


def constraint(move: Move, instance: Instance, declared: Declared, pin: Any) -> str | None:
    """Why a person decides this move, or None."""
    if isinstance(pin, dict):
        for key, value in pin.items():
            if key.endswith("_reason"):
                return f"{key}: {value}"
        name = version_field(move, declared, pin)
        if name and move.path is not None:
            origin = declared.derived.get(move.path.child(name).text())
            if origin is not None:
                return f"the version follows {origin}"
    components = instance.config.get("components")
    entry = components.get(move.component) if isinstance(components, dict) else None
    if isinstance(entry, dict) and entry.get("version") is not None:
        return f"[components.{move.component}] version = {entry['version']!r}"
    bundle = declared.bundles.get(move.path.text()) if move.path is not None else None
    if bundle is not None and bundle.override and move.row["status"] == "review":
        return "a new major of a security override"
    return None


def group_of(move: Move, instance: Instance, declared: Declared, locks: Locks) -> tuple[str, str] | None:
    """(kind, key) of the group that moves a row; None when no declaration explains
    the pin."""
    path = move.path
    if path is None:
        return None
    pin = pin_of(locks, path)
    text = path.text()
    steps = path.steps
    if len(steps) == 2 and steps[0].key == "flake_inputs" and path.file == "versions":
        if isinstance(pin, dict) and "channel" in pin:
            return "channel", ""
        return "flake", str(steps[1].key)
    if text in declared.downloads:
        return "download", move.id
    if text in declared.bundles:
        return "npm", str(declared.bundles[text].rule.values["dir"])
    guarded = declared.guards.get(path.child("version").text()) or declared.guards.get(text)
    if move.row.get("kind") == "pypi" or (move.adapter is not None and move.adapter.name == "pypi"):
        return ("pypi", guarded) if guarded in declared.regenerators else None
    if hash_fields(pin):
        return "nix-package", str(steps[-1].key)
    return None


class Router:
    def __init__(self, instance: Instance, locks: Locks, planned: list[Planned], tools: Tools) -> None:
        self.instance = instance
        self.locks = locks
        self.tools = tools
        self.declared = Declared(instance, locks)
        self.planned = {entry.id: entry for entry in planned}
        self.plan = Plan()
        self.groups: dict[tuple[str, str], Group] = {}
        self.errors: list[Move] = []

    def line(self, row: Row, status: str, note: Any = None, **fields: Any) -> None:
        self.plan.lines.append({"id": row["id"], "status": status, "note": note, **fields})

    def item(self, code: str, move: Move, **fields: Any) -> None:
        self.plan.items.append(
            {
                "code": code,
                "id": move.id,
                "current": move.row.get("current"),
                "latest": move.row.get("latest"),
                "source": move.row.get("source"),
                **fields,
            }
        )

    def move_of(self, row: Row) -> Move | None:
        entry = self.planned.get(row["id"])
        if entry is None:
            return None
        request = entry.request
        return Move(
            row,
            request.base if request is not None else None,
            entry.component,
            request.adapter if request is not None else None,
            request,
        )

    def add(self, kind: str, key: str, move: Move) -> None:
        name = f"{kind}:{key}" if key else kind
        self.groups.setdefault((kind, key), Group(name, kind, key)).moves.append(move)

    def route(self, rows: list[Row], skips: list[str], restores: list[dict[str, Any]] | None = None) -> Plan:
        restored = self._restores(restores or [], skips)
        for row in rows:
            if row["id"] in restored:
                self.line(row, "restored", "back to an earlier commit")
                continue
            self._route(row, skips)
        for move in self.errors:
            place = group_of(move, self.instance, self.declared, self.locks)
            if place is not None and place in self.groups:
                self.groups[place].blocked.append(move.id)
        self.plan.groups = sorted(self.groups.values(), key=lambda group: (ORDER.index(group.kind), group.name))
        return self.plan

    def _restores(self, restores: list[dict[str, Any]], skips: list[str]) -> set[str]:
        """The groups that put pins back to an earlier commit (``--restore``): a download pin with the
        companions its component installs, or a pypi group with every pin its requirements guard, all
        from one commit. A pin without such a group is a review item. The ids it restores."""
        restored: set[str] = set()
        old: dict[str, Locks | None] = {}
        for entry in restores:
            identifier, commit = str(entry.get("id") or ""), str(entry.get("commit") or "")
            if identifier in restored:
                continue
            members, key = self._restore_members(identifier)
            if key is None:
                self.plan.items.append(
                    {"code": "restore-unsupported", "id": identifier, "reason": "the writer has no group to restore it"}
                )
                continue
            if any(fnmatch.fnmatchcase(member, pattern) for member in members for pattern in skips):
                self.plan.lines.append({"id": identifier, "status": "skipped", "note": "--skip"})
                continue
            if commit not in old:
                old[commit] = locks_at(self.instance, commit)
            before = old[commit]
            if before is None:
                self.plan.items.append(
                    {
                        "code": "restore-unsupported",
                        "id": identifier,
                        "commit": commit,
                        "reason": "the commit is not here",
                    }
                )
                continue
            for member in members:
                path = parse_path(member)
                was, now = pin_of(before, path), pin_of(self.locks, path)
                if was is None or was == now:
                    continue
                row: Row = {
                    "id": member,
                    "kind": "restore",
                    "current": _version_text(now),
                    "latest": _version_text(was),
                    "status": "update",
                    "source": commit,
                    "details": {"commit": commit},
                }
                move = Move(row, path, "")
                self.groups.setdefault(("restore", key), Group(f"restore:{key}", "restore", key)).moves.append(move)
            restored.update(members)
        return restored

    def _restore_members(self, identifier: str) -> tuple[list[str], str | None]:
        """The pins that come back with IDENTIFIER, and the key of their group (None: no group)."""
        try:
            path = parse_path(identifier)
        except DeclarationError:
            return [identifier], None
        text = path.text()
        if text in self.declared.downloads:
            members = [text]
            for system in self.instance.systems:
                for component in self.instance.manifest(system).get("components") or []:
                    install = component.get("install") if isinstance(component, dict) else None
                    if not isinstance(install, dict) or install.get("pin") != text:
                        continue
                    for companion in install.get("companions") or ():
                        pin = companion.get("pin") if isinstance(companion, dict) else None
                        if isinstance(pin, str) and pin in self.declared.downloads:
                            members.append(pin)
            return list(dict.fromkeys(members)), text
        guarded = self.declared.guards.get(path.child("version").text()) or self.declared.guards.get(text)
        if guarded is not None and guarded in self.declared.regenerators:
            members = [
                key.removesuffix(".version")
                for key, file in self.declared.guards.items()
                if file == guarded and not key.startswith("skills:")
            ]
            return sorted(set(members) | {text}), guarded
        return [text], None

    def _route(self, row: Row, skips: list[str]) -> None:
        identifier, status = row["id"], row.get("status")
        details = row.get("details") or {}
        if status in ("current", "follows"):
            return
        if any(fnmatch.fnmatchcase(identifier, pattern) for pattern in skips):
            self.line(row, "skipped", "--skip")
        elif status in ("held", "manual"):
            self.line(row, status, details.get("note"))
        elif status == "error":
            # A row of a job of pins latest that failed names the pins it was for.
            ids = [str(name) for name in details.get("ids") or ()]
            self.line(row, "error", details.get("error"), **({"ids": ids} if ids else {}))
            for name in [identifier, *ids]:
                move = self.move_of({**row, "id": name})
                if move is not None:
                    self.errors.append(move)
        elif status not in ("update", "review"):
            self.line(row, "unknown", f"status {status!r}")
        else:
            move = self.move_of(row)
            if move is None:
                self.line(row, "undeclared", "no declaration of the instance has this row")
            else:
                self._route_move(move, details)

    def _route_move(self, move: Move, details: dict[str, Any]) -> None:
        kind = move.adapter.name if move.adapter is not None else move.row.get("kind")
        if kind == "git-compare":
            self._route_compare(move, details)
        elif move.id == FRAMEWORK_ROW:
            self._route_framework(move)
        elif kind == "skill-source":
            self._route_skill(move)
        elif reached(move, self.instance, self.locks, self.declared) and not self._newer_series(move):
            return
        else:
            self._route_pin(move)

    def _route_compare(self, move: Move, details: dict[str, Any]) -> None:
        declared_at = move.adapter.declaration.get("revision_at", "") if move.adapter is not None else ""
        if str(declared_at).endswith(MARKETPLACE_FIELD):
            self.line(move.row, "self-updating", "a plugin marketplace updates itself; a later scan reports it")
        else:
            self.item("pins-review", move, changed_paths=details.get("changed_paths", []))

    def _route_framework(self, move: Move) -> None:
        if reached(move, self.instance, self.locks, self.declared):
            return
        old = self._framework_version()
        if model.classify(old, move.latest.removeprefix("v")) == "review":
            self.item("framework-major", move, version=old, reason="a framework major needs a person")
            return
        self.add("framework", "", move)

    def _framework_version(self) -> str:
        ref = flake_original(self.instance).get("ref")
        if isinstance(ref, str):
            return ref.removeprefix("refs/tags/").removeprefix("v")
        # A commit pin: the release it is based on.
        try:
            return (self.tools.framework_source() / "VERSION").read_text(encoding="utf-8").strip()
        except (GroupFailure, OSError):
            return "0"

    def _route_skill(self, move: Move) -> None:
        name = move.id.removeprefix("skills.")
        entry = skill_entry(self.locks, name)
        if entry is None or reached(move, self.instance, self.locks, self.declared):
            return
        if entry.get("source_transform"):
            # Prose only an agent can replay: work for dotsteward-update, no decision that holds a run.
            self.item("skill-transform", move, pending=False, transform=entry["source_transform"])
            return
        self.add("skill", name, move)

    def _newer_series(self, move: Move) -> bool:
        details = move.details
        pin = pin_of(self.locks, move.path)
        channel = pin.get("channel") if isinstance(pin, dict) else None
        newest = details.get("newest_series")
        return bool(channel and newest and versions.compare(newest, channel) > 0)

    def _route_pin(self, move: Move) -> None:
        pin = pin_of(self.locks, move.path)
        if self._newer_series(move):
            self.item("series-available", move, series=move.details["newest_series"])
            if reached(move, self.instance, self.locks, self.declared):
                return
        reason = constraint(move, self.instance, self.declared, pin)
        if reason is not None:
            self.item("pins-constrained", move, reason=reason)
            return
        place = group_of(move, self.instance, self.declared, self.locks)
        if place is None:
            self.item("pins-no-writer", move, reason="no rule of the instance says how this pin moves")
            return
        if place[0] == "download" and "asset_missing" in asset_of(move):
            self.item("asset-missing", move, asset=asset_of(move)["asset_missing"])
            return
        self.add(*place, move)


def route(
    instance: Instance,
    locks: Locks,
    planned: list[Planned],
    rows: list[Row],
    skips: list[str],
    tools: Tools,
    restores: list[dict[str, Any]] | None = None,
) -> Plan:
    return Router(instance, locks, planned, tools).route(rows, skips, restores)


def show(instance: Instance, commit: str, name: str) -> bytes | None:
    """The file NAME of the instance at COMMIT, None when it has none."""
    done = subprocess.run(
        ["git", "-C", str(instance.root), "show", f"{commit}:{name}"], capture_output=True, check=False, timeout=60
    )
    return done.stdout if done.returncode == 0 else None


def locks_at(instance: Instance, commit: str) -> Locks | None:
    text = show(instance, commit, instance.versions_label)
    if text is None:
        return None
    try:
        return Locks(documents={VERSIONS: json.loads(text)})
    except ValueError:
        return None


def _version_text(value: Any) -> str | None:
    """The version a pin value names, for the lines of a restore."""
    if isinstance(value, dict):
        for name in CURRENT_FIELDS:
            if isinstance(value.get(name), str):
                return str(value[name])
        return None
    return value if isinstance(value, str) else None
