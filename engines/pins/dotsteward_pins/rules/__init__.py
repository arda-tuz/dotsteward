"""Rule kinds of the pins engine (SPEC 5.4) and the shared rule machinery.

A rule is a declaration (a JSON object) with ``kind`` and ``component``.
Components declare them in ``dotsteward.components.<name>.pins.rules``; the
manifest mirror carries them tagged with the component. Core rules are built
in (``core_rules``): ``flake-inputs``, ``nix-package-format``, the Nix
installer ``download-pin``, then the components' rules in manifest order,
then ``skill-digests``, two ``no-literal`` rules and ``nix-resolved``
(active with ``--nix`` only).

Fields every rule accepts:

    kind        the rule kind (one of KINDS)
    component   the declaring component (set by the manifest)
    name        optional; the group label becomes <component>/<name>
                instead of <component>/<kind>
    formats     optional object: lock path -> format name (hex40, hex64,
                sri, sha512, nonempty, positive-int, https-url), checked
                with the rule (per entry with for_each; relative paths are
                relative to the rule's base object)

Kinds that iterate (derive, download-pin, text-guard, skills-lock-mirror)
also accept:

    for_each    lock path of an object; the rule runs once per entry with
                {key} and {value} bound and the entry as the base object of
                relative paths ({.field})
    only_with   with for_each: skip entries (objects) without this field

The field reference of each kind is in its module (rules/<kind>.py). Lock
paths and templates are described in lockfile.py.

``check`` adds assertions to a Checker; ``sync`` rewrites derived values in
place and never creates entries. Kinds without a sync are check-only.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass, field
from typing import Any, ClassVar

from ..checker import FORMATS, Checker
from ..instance import Declaration, EngineError, Instance
from ..lockfile import DeclarationError, LockPath, Locks, Scope, Template, parse_path, parse_template

# --- Context --------------------------------------------------------------------


@dataclass
class Context:
    """Everything a rule reads: the instance, the lock documents, whether
    Nix evaluation is allowed (--nix) and the skills named by --skill."""

    instance: Instance
    locks: Locks
    nix: bool = False
    extra_skills: frozenset[str] = frozenset()
    _evaluated: dict[str, dict[str, str]] = field(default_factory=dict)

    def pinned_versions(self, attribute: str) -> dict[str, str]:
        """The evaluated ``<instance>#<attribute>`` (cached per run)."""
        if attribute not in self._evaluated:
            value = self.instance.nix_eval(attribute)
            if not isinstance(value, dict) or not all(
                isinstance(key, str) and isinstance(item, str) for key, item in value.items()
            ):
                raise EngineError(f"nix eval of {attribute}: expected an object of strings, found {value!r}")
            self._evaluated[attribute] = value
        return self._evaluated[attribute]


# --- Field parsers ----------------------------------------------------------------

Parser = Callable[[Any], Any]


def string(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise DeclarationError(f"expected a non-empty string, found {value!r}")
    return value


def optional_string(value: Any) -> str | None:
    if value is None:
        return None
    return string(value)


def boolean(value: Any) -> bool:
    if not isinstance(value, bool):
        raise DeclarationError(f"expected true or false, found {value!r}")
    return value


def strings(value: Any) -> list[str]:
    if not isinstance(value, list) or not value:
        raise DeclarationError(f"expected a non-empty list of strings, found {value!r}")
    return [string(item) for item in value]


def paths(value: Any) -> list[LockPath]:
    if not isinstance(value, list) or not value:
        raise DeclarationError(f"expected a non-empty list of lock paths, found {value!r}")
    return [parse_path(item) for item in value]


def relative_file(value: Any) -> str:
    """An instance-relative file path or glob (no absolute path, no ..)."""
    text = string(value)
    if text.startswith("/") or ".." in text.split("/"):
        raise DeclarationError(f"expected a path inside the instance, found {text!r}")
    return text


def relative_files(value: Any) -> list[str]:
    if not isinstance(value, list) or not value:
        raise DeclarationError(f"expected a non-empty list of instance paths, found {value!r}")
    return [relative_file(item) for item in value]


def formats(value: Any) -> list[tuple[LockPath, str]]:
    if not isinstance(value, dict) or not value:
        raise DeclarationError(f"expected an object of lock path -> format, found {value!r}")
    result = []
    for path, name in value.items():
        if name not in FORMATS:
            raise DeclarationError(f"unknown format {name!r} (known: {', '.join(FORMATS)})")
        result.append((parse_path(path), name))
    return result


@dataclass(frozen=True)
class FieldSpec:
    parser: Parser
    required: bool = False
    default: Any = None


COMMON_FIELDS: dict[str, FieldSpec] = {
    "name": FieldSpec(string),
    "formats": FieldSpec(formats, default=[]),
}
RESERVED_FIELDS = ("kind", "component")
FOR_EACH_FIELDS: dict[str, FieldSpec] = {
    "for_each": FieldSpec(parse_path),
    "only_with": FieldSpec(string),
}


# --- Rule base --------------------------------------------------------------------


class Rule:
    """A validated declaration of one kind."""

    kind: ClassVar[str]
    FIELDS: ClassVar[dict[str, FieldSpec]] = {}
    FOR_EACH: ClassVar[bool] = False
    SYNCS: ClassVar[bool] = False

    def __init__(self, component: str, declaration: Mapping[str, Any]) -> None:
        self.component = component
        self.declaration = dict(declaration)
        specs = self.field_specs()
        label = declaration.get("name") if isinstance(declaration.get("name"), str) else self.kind
        self.group = f"{component}/{label}"
        problems: list[str] = []
        given = [key for key in declaration if key not in RESERVED_FIELDS]
        problems.extend(
            f"missing field {name!r}" for name, spec in specs.items() if spec.required and name not in given
        )
        problems.extend(f"unknown field {name!r}" for name in given if name not in specs)
        self.values: dict[str, Any] = {}
        for name, spec in specs.items():
            if name not in declaration:
                self.values[name] = spec.default
                continue
            try:
                self.values[name] = spec.parser(declaration[name])
            except DeclarationError as error:
                problems.append(f"field {name!r}: {error}")
        if not problems:
            if self.values.get("only_with") is not None and self.values.get("for_each") is None:
                problems.append("'only_with' needs 'for_each'")
            problems.extend(self.validate())
        if problems:
            raise EngineError(f"{self.group}: invalid declaration: {'; '.join(problems)}")

    @classmethod
    def field_specs(cls) -> dict[str, FieldSpec]:
        specs = dict(COMMON_FIELDS)
        if cls.FOR_EACH:
            specs.update(FOR_EACH_FIELDS)
        specs.update(cls.FIELDS)
        return specs

    def validate(self) -> list[str]:
        """Cross-field problems of the declaration."""
        return []

    # -- evaluation --

    def base(self) -> LockPath | None:
        """The declared base object (``at``) of relative paths, if any."""
        return self.values.get("at")

    def scopes(self, ctx: Context) -> Iterator[Scope]:
        locks = ctx.locks
        at = self.base()
        for_each = self.values.get("for_each")
        if for_each is None:
            yield Scope(base=locks.resolve(at) if at is not None else None)
            return
        collection = locks.resolve(for_each)
        for key, value in locks.entries(collection):
            only_with = self.values.get("only_with")
            if only_with is not None and not (isinstance(value, dict) and only_with in value):
                continue
            scope = Scope(key=key, value=value, base=collection.child(key), has_entry=True)
            if at is not None:
                scope.base = locks.resolve(at, scope)
            yield scope

    def check(self, ctx: Context, c: Checker) -> None:
        for scope in self.scopes(ctx):
            self.check_scope(ctx, c, scope)
            self.check_formats(ctx, c, scope)

    def check_formats(self, ctx: Context, c: Checker, scope: Scope) -> None:
        for path, name in self.values.get("formats") or []:
            resolved = ctx.locks.resolve(path, scope)
            c.fmt(resolved.text(), name, ctx.locks.get_leaf(resolved))

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        raise NotImplementedError

    def sync(self, ctx: Context) -> None:
        for scope in self.scopes(ctx):
            self.sync_scope(ctx, scope)

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        """Rewrites the derived values of one scope (sync rules only)."""


# --- Registry ---------------------------------------------------------------------


def _registry() -> dict[str, type[Rule]]:
    from . import (
        asset_digest,
        derive,
        download_pin,
        flake_inputs,
        minimum_version,
        nix_package_format,
        nix_resolved,
        no_literal,
        npm_bundle,
        skill_digests,
        skills_lock_mirror,
        text_guard,
    )

    kinds = [
        flake_inputs.FlakeInputs,
        nix_package_format.NixPackageFormat,
        derive.Derive,
        download_pin.DownloadPin,
        text_guard.TextGuard,
        no_literal.NoLiteral,
        npm_bundle.NpmBundle,
        skills_lock_mirror.SkillsLockMirror,
        minimum_version.MinimumVersion,
        asset_digest.AssetDigest,
        nix_resolved.NixResolved,
        skill_digests.SkillDigests,
    ]
    return {kind.kind: kind for kind in kinds}


KINDS: dict[str, type[Rule]] = _registry()


def make(component: str, declaration: Mapping[str, Any]) -> Rule:
    return KINDS[declaration["kind"]](component, declaration)


def core_rules(instance: Instance) -> tuple[list[Rule], list[Rule]]:
    """The built-in core rules: those that run before the components' rules
    and those that run after them."""
    head = [
        make("core", {"kind": "flake-inputs", "excluded": instance.excluded_flake_inputs}),
        make("core", {"kind": "nix-package-format"}),
        make(
            "core",
            {
                "kind": "download-pin",
                "at": "nix",
                "version_field": "version",
                "url_field": "installer_url",
                "size_field": "installer_size",
                "sha256_field": "installer_sha256",
                "url_contains": "/nix-{.version}/",
            },
        ),
    ]
    tail = [
        make("core", {"kind": "skill-digests", "sentinels": list(instance.repo_owned_revisions)}),
        make(
            "core",
            {
                "kind": "no-literal",
                "files": ["flake.nix", "home.nix", "components/**/*.nix"],
                "patterns": ["sri", "fake-hash"],
            },
        ),
        make(
            "core",
            {
                "kind": "no-literal",
                "files": [instance.versions_label, instance.skills_label],
                "patterns": ["fake-hash"],
            },
        ),
        make("core", {"kind": "nix-resolved"}),
    ]
    return head, tail


def component_rule(declaration: Declaration) -> Rule:
    data = declaration.data
    component = data.get("component")
    kind = data.get("kind")
    where = f"{declaration.source}: rule {declaration.index}"
    if not isinstance(component, str) or not component:
        raise EngineError(f"{where}: missing component")
    if kind not in KINDS:
        raise EngineError(f"{where} (component {component}): unknown kind {kind!r}")
    return make(component, data)


def build_rules(instance: Instance) -> list[Rule]:
    """Every rule of the instance in evaluation order."""
    head, tail = core_rules(instance)
    declared = [component_rule(declaration) for declaration in instance.declarations("rules")]
    return head + declared + tail


__all__ = [
    "KINDS",
    "Checker",
    "Context",
    "FieldSpec",
    "Rule",
    "Template",
    "boolean",
    "build_rules",
    "optional_string",
    "parse_path",
    "parse_template",
    "paths",
    "relative_file",
    "relative_files",
    "string",
    "strings",
]
