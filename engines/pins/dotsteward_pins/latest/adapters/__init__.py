"""Latest adapters (SPEC 5.5) and the declaration machinery they share.

A declaration is a JSON object with ``id``, ``adapter`` and ``component``.
Components declare them in ``dotsteward.components.<name>.pins.latest``;
the manifest mirror carries them tagged with the component (so an adapter
field cannot be named ``component``). Base URLs, repositories and asset
names live in the declarations, never in the engine.

Fields every declaration accepts:

    id              the report row id; a lock template ({key}, {value},
                    {<lock path>})
    at              lock path of the pin object (relative paths and {key}
                    with for_each). Default: the for_each entry, else the
                    id when it names an object of the versions lock
    current         lock template of the current version ("{value}",
                    "{.minimum_version}")
    current_field   field of the pin object holding the current version;
                    default the first present of version, minimum_version
                    and expected
    holdback_field  field whose presence holds a newer version back
                    (status held, its text becomes the note); default
                    holdback_reason
    note            lock template of a note for the row
    source          the report's source text (default per adapter)
    optional        true: the row is listed only with --all (default true
                    for follows and local-apt)
    for_each        lock path of an object; one row per entry with {key}
                    and {value} bound and the entry as base of relative
                    paths
    only_with       with for_each: skip entries (objects) without this
                    field

Fields ending in ``_at`` are lock paths (relative to ``at`` when they
start with "."); templates of upstream values (``asset``, ``url_template``,
``manifest_url``) are release templates (templates.py). The other fields
are listed in each adapter module.

Planning reads the lock files only: a value a declaration needs but the
lock lacks becomes an error row with the row id, before any query. An
adapter's ``fetch`` queries the upstream and returns rows; an
``UpstreamError`` becomes an error row of its ids, any other exception the
runner's ``job-<n>`` error row.
"""

from __future__ import annotations

import re
from collections.abc import Hashable, Iterator, Mapping
from dataclasses import dataclass, field
from typing import Any, ClassVar

from ...checker import GROUP_ERRORS
from ...instance import Declaration, EngineError, Instance
from ...lockfile import DeclarationError, Locks, LockPath, Placeholder, Scope, Template, parse_path, parse_template
from ...rules import FieldSpec, boolean, string
from ..model import Row, error_item
from ..upstream import Upstream

CURRENT_FIELDS = ("version", "minimum_version", "expected")
PLAN_ERRORS = (*GROUP_ERRORS, DeclarationError, LookupError)


class PlanError(Exception):
    """A lock value a declaration needs is missing or unusable."""


# --- Field parsers ----------------------------------------------------------------


def text(value: Any) -> str:
    """Any string, the empty one included."""
    if not isinstance(value, str):
        raise DeclarationError(f"expected a string, found {value!r}")
    return value


def regex(value: Any) -> re.Pattern[str]:
    text = string(value)
    try:
        return re.compile(text)
    except re.error as error:
        raise DeclarationError(f"invalid regular expression {text!r}: {error}") from error


def regexes(value: Any) -> list[re.Pattern[str]]:
    if not isinstance(value, list) or not value:
        raise DeclarationError(f"expected a non-empty list of regular expressions, found {value!r}")
    return [regex(item) for item in value]


def repository(value: Any) -> Template:
    """An ``owner/name`` GitHub repository (a lock template)."""
    template = parse_template(string(value))
    if all(isinstance(part, str) for part in template.parts) and not re.fullmatch(r"[^/\s]+/[^/\s]+", value):
        raise DeclarationError(f"expected a GitHub repository owner/name, found {value!r}")
    return template


def url(value: Any) -> str:
    text = string(value)
    if not re.match(r"[a-z][a-z0-9+.-]*://", text):
        raise DeclarationError(f"expected a URL, found {text!r}")
    return text.rstrip("/")


COMMON_FIELDS: dict[str, FieldSpec] = {
    "id": FieldSpec(parse_template, required=True),
    "at": FieldSpec(parse_path),
    "current": FieldSpec(parse_template),
    "current_field": FieldSpec(string),
    "holdback_field": FieldSpec(string, default="holdback_reason"),
    "note": FieldSpec(parse_template),
    "source": FieldSpec(string),
    "optional": FieldSpec(boolean),
    "for_each": FieldSpec(parse_path),
    "only_with": FieldSpec(string),
}
RESERVED_FIELDS = ("adapter", "component")


# --- Requests ---------------------------------------------------------------------


@dataclass
class Request:
    """One planned row: everything read from the lock files."""

    id: str
    adapter: Adapter
    current: str | None = None
    held: bool = False
    note: str | None = None
    values: dict[str, Any] = field(default_factory=dict)

    @property
    def kind(self) -> str:
        return self.adapter.name

    @property
    def optional(self) -> bool:
        return self.adapter.optional

    def error(self, message: str) -> Row:
        return error_item(self.id, self.kind, message, self.current, self.adapter.source_of(self))


@dataclass
class Planned:
    """A plan result: a request to fetch, or a row known without a query."""

    id: str
    component: str
    optional: bool
    request: Request | None = None
    row: Row | None = None


@dataclass
class PlanContext:
    instance: Instance
    locks: Locks


# --- Adapter base -----------------------------------------------------------------


class Adapter:
    """A validated declaration of one adapter."""

    name: ClassVar[str]
    FIELDS: ClassVar[dict[str, FieldSpec]] = {}
    OPTIONAL: ClassVar[bool] = False
    # False: the adapter sets the current value itself (revisions).
    VERSIONED: ClassVar[bool] = True
    # Built-in adapters produce core rows only; components cannot declare them.
    BUILT_IN: ClassVar[bool] = False

    def __init__(self, component: str, declaration: Mapping[str, Any], label: str | None = None) -> None:
        self.component = component
        self.declaration = dict(declaration)
        identifier = declaration.get("id")
        self.group = f"{component}/{identifier if isinstance(identifier, str) else label or 'latest'}"
        problems: list[str] = []
        if self.BUILT_IN and component != "core":
            message = f"adapter {self.name!r} is built in; it is not declared"
            raise EngineError(f"{self.group}: invalid declaration: {message}")
        specs = {**COMMON_FIELDS, **self.FIELDS}
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
            problems.extend(self._common_problems())
            problems.extend(self.validate())
        if problems:
            raise EngineError(f"{self.group}: invalid declaration: {'; '.join(problems)}")

    def _common_problems(self) -> list[str]:
        problems = []
        if self.values["only_with"] is not None and self.values["for_each"] is None:
            problems.append("'only_with' needs 'for_each'")
        problems.extend(self.exclusive("current", "current_field"))
        if self.values["for_each"] is None:
            for name, value in self.values.items():
                if isinstance(value, Template) and any(
                    isinstance(part, Placeholder) and part.path is None for part in value.parts
                ):
                    problems.append(f"field {name!r}: {{key}} and {{value}} need 'for_each'")
        return problems

    def exclusive(self, first: str, second: str) -> list[str]:
        if self.values.get(first) is not None and self.values.get(second) is not None:
            return [f"{first!r} and {second!r} exclude each other"]
        return []

    def one_of(self, first: str, second: str) -> list[str]:
        problems = self.exclusive(first, second)
        if self.values.get(first) is None and self.values.get(second) is None:
            problems.append(f"one of {first!r} and {second!r} is required")
        return problems

    def validate(self) -> list[str]:
        """Cross-field problems of the declaration."""
        return []

    @property
    def optional(self) -> bool:
        value = self.values["optional"]
        return self.OPTIONAL if value is None else value

    # -- planning --

    def scopes(self, locks: Locks) -> Iterator[Scope]:
        at = self.values["at"]
        for_each = self.values["for_each"]
        if for_each is None:
            if at is None:
                yield Scope(base=self._id_path(locks))
            else:
                yield Scope(base=locks.resolve(at))
            return
        collection = locks.resolve(for_each)
        only_with = self.values["only_with"]
        for key, value in locks.entries(collection):
            if only_with is not None and not (isinstance(value, dict) and only_with in value):
                continue
            scope = Scope(key=key, value=value, base=collection.child(key), has_entry=True)
            if at is not None:
                scope.base = locks.resolve(at, scope)
            yield scope

    def _id_path(self, locks: Locks) -> LockPath | None:
        template: Template = self.values["id"]
        if not all(isinstance(part, str) for part in template.parts):
            return None
        try:
            path = parse_path(template.source)
        except DeclarationError:
            return None
        if not path.concrete():
            return None
        try:
            return path if isinstance(locks.get(path), dict) else None
        except (KeyError, TypeError):
            return None

    def plan(self, ctx: PlanContext) -> list[Planned]:
        """The rows of this declaration: requests, or error rows for lock
        values that are missing."""
        try:
            scopes = list(self.scopes(ctx.locks))
        except PLAN_ERRORS as error:
            return [self._plan_error(self.values["id"].source, None, error)]
        return [self._plan_scope(ctx, scope) for scope in scopes]

    def _plan_scope(self, ctx: PlanContext, scope: Scope) -> Planned:
        locks = ctx.locks
        identifier = self.values["id"].source
        current = None
        try:
            identifier = locks.render(self.values["id"], scope)
            pin = locks.get(scope.base) if scope.base is not None else None
            request = Request(identifier, self)
            if self.VERSIONED:
                current = request.current = self._current(locks, scope, pin)
            holdback = self.values["holdback_field"]
            if isinstance(pin, dict) and holdback in pin:
                request.held = True
                request.note = str(pin[holdback])
            elif self.values["note"] is not None:
                request.note = locks.render(self.values["note"], scope)
            self.resolve(ctx, scope, pin, request)
        except (*PLAN_ERRORS, PlanError) as error:
            return self._plan_error(identifier, current, error)
        row = self.immediate(request)
        return Planned(identifier, self.component, self.optional, None if row else request, row)

    def _plan_error(self, identifier: str, current: str | None, error: BaseException) -> Planned:
        if isinstance(error, KeyError) and error.args:
            message = f"the lock lacks {error.args[0]}"
        else:
            message = str(error) if str(error) else repr(error)
        row = error_item(identifier, self.name, f"{self.group}: {message}", current)
        return Planned(identifier, self.component, self.optional, None, row)

    def _current(self, locks: Locks, scope: Scope, pin: Any) -> str:
        if self.values["current"] is not None:
            return locks.render(self.values["current"], scope)
        field_name = self.values["current_field"]
        if field_name is not None:
            if not isinstance(pin, dict) or field_name not in pin:
                where = scope.base.text() if scope.base is not None else "the pin"
                raise PlanError(f"no current version: {where} has no field {field_name!r}")
            return _text(pin[field_name])
        if isinstance(pin, dict):
            for name in CURRENT_FIELDS:
                if isinstance(pin.get(name), str | int) and not isinstance(pin.get(name), bool):
                    return _text(pin[name])
        raise PlanError("no current version: declare 'at', 'current' or 'current_field'")

    def lock_value(self, locks: Locks, path: LockPath, scope: Scope) -> Any:
        return locks.get(locks.resolve(path, scope))

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        """Reads the adapter's lock values into request.values."""

    def immediate(self, request: Request) -> Row | None:
        """The row of an adapter that needs no query, else None."""
        return None

    # -- fetching --

    def source_of(self, request: Request) -> str:
        """The report source of a row (the declared one by default)."""
        return self.values["source"] or self.default_source(request)

    def default_source(self, request: Request) -> str:
        return ""

    def group_key(self, request: Request) -> Hashable | None:
        """Requests with the same key share one query (fetch_group)."""
        return None

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        raise NotImplementedError

    def fetch_group(self, requests: list[Request], upstream: Upstream) -> list[Row]:
        raise NotImplementedError


def _text(value: Any) -> str:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    raise PlanError(f"the current version is not a version: {value!r}")


# --- Registry ---------------------------------------------------------------------


def _registry() -> dict[str, type[Adapter]]:
    from . import (
        apt_index,
        channel_head,
        deb_url,
        follows,
        framework,
        git_compare,
        github_release,
        local_apt,
        manual,
        nix_release,
        npm,
        official_manifest,
        skill_source,
    )

    adapters: list[type[Adapter]] = [
        github_release.GithubRelease,
        npm.Npm,
        apt_index.AptIndex,
        deb_url.DebUrl,
        official_manifest.OfficialManifest,
        nix_release.NixRelease,
        channel_head.ChannelHead,
        git_compare.GitCompare,
        skill_source.SkillSource,
        local_apt.LocalApt,
        manual.Manual,
        follows.Follows,
        framework.Framework,
    ]
    return {adapter.name: adapter for adapter in adapters}


ADAPTERS: dict[str, type[Adapter]] = _registry()


def make(component: str, declaration: Mapping[str, Any], label: str | None = None) -> Adapter:
    return ADAPTERS[declaration["adapter"]](component, declaration, label)


def declared(declaration: Declaration) -> Adapter:
    """The adapter of one manifest declaration (EngineError when invalid)."""
    data = declaration.data
    component = data.get("component")
    adapter = data.get("adapter")
    where = f"{declaration.source}: latest {declaration.index}"
    if not isinstance(component, str) or not component:
        raise EngineError(f"{where}: missing component")
    if component == "core":
        raise EngineError(f"{where}: the component name 'core' is reserved for built-in rows")
    if adapter not in ADAPTERS:
        raise EngineError(f"{where} (component {component}): unknown adapter {adapter!r}")
    return make(component, data, f"latest {declaration.index}")


__all__ = [
    "ADAPTERS",
    "Adapter",
    "FieldSpec",
    "PlanContext",
    "PlanError",
    "Planned",
    "Request",
    "boolean",
    "declared",
    "make",
    "regex",
    "regexes",
    "repository",
    "string",
    "text",
    "url",
]
