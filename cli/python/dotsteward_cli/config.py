"""workstation.toml reader and DS_* exporter (SPEC 4.1, 4.4, 6.1).

Two layers:

- The resolved configuration: the same validation messages, in the same
  order, and the same resolved value as ``lib/config.nix`` (the Nix parity
  test in ``tests/cli/config`` holds the two readers together). Both
  interpret the JSON Schema keyword subset documented in
  ``schema/workstation.schema.json``, which is the single source of the
  accepted keys, their types and their static defaults; the cross-key rules
  and derived defaults below mirror ``lib/config.nix`` rule by rule. Paths
  are not expanded in this layer.
- The run-time layer of the command line: instance discovery, ``~/`` and
  ``${VAR:-default}`` expansion with the runtime environment, the
  ``DOTSTEWARD_*`` (and, with ``compat.legacy_env``, ``DOTFILES_*``)
  environment overrides, and the ``DS_*`` shell variables that
  ``cli/lib/config.sh`` evaluates.

Command line (used by ``cli/lib/config.sh``)::

    python3 -m dotsteward_cli.config [--instance DIR | --file PATH]
        [--catalog NAMES] [--instance-name NAME] COMMAND

    resolve    print the resolved configuration (one JSON document)
    errors     print the validation messages (a JSON array, [] when valid)
    export     print DS_* declarations for bash, one per line
    discover   print the instance root

Exit status 0 on success, 1 for an invalid configuration, a usage error or
any other refusal; messages go to standard error as ``[dotsteward] ERROR:``
lines.

Python API (for the other engines): ``read_toml``, ``errors``, ``resolve``,
``framework_catalog``, ``discover_instance``, ``load_instance``,
``export_variables``, ``ConfigError`` and ``DotstewardError``.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import math
import os
import platform
import re
import sys
import tomllib
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Any

FRAMEWORK_ROOT = Path(__file__).resolve().parents[3]

SUPPORTED_VERSION = 1

# The public catalog in its canonical order (default of components.order).
CATALOG_ORDER = ("shell", "herdr", "claude-code", "codex", "opencode-pi", "vscode")

# Keys of the [profiles] table that are not profile tables.
PROFILE_KEYS = ("names", "default", "check", "bootstrap")

LINUX_USER_PATTERN = "^[a-z_][a-z0-9_-]*$"

CONFIG_FILE = "workstation.toml"

SUPPORTED_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "$defs",
        "$ref",
        "$comment",
        "title",
        "description",
        "default",
        "type",
        "enum",
        "const",
        "pattern",
        "minLength",
        "minimum",
        "maximum",
        "items",
        "minItems",
        "uniqueItems",
        "properties",
        "required",
        "additionalProperties",
        "propertyNames",
    }
)

TYPE_NAMES = {
    "object": "a table",
    "array": "an array",
    "string": "a string",
    "integer": "an integer",
    "boolean": "a boolean",
}


class DotstewardError(Exception):
    """A refusal with one or more messages for ``[dotsteward] ERROR:`` lines."""

    prefix = ""

    def __init__(self, *messages: str) -> None:
        super().__init__("\n".join(messages))
        self.messages = list(messages)

    def lines(self) -> list[str]:
        return [f"[dotsteward] ERROR: {self.prefix}{message}" for message in self.messages]


class ConfigError(DotstewardError):
    """Problems of a workstation.toml (messages as lib/config.nix words them)."""

    prefix = f"{CONFIG_FILE}: "


# --- Nix value semantics -----------------------------------------------------


def _is_bool(value: Any) -> bool:
    return type(value) is bool


def _is_int(value: Any) -> bool:
    # bool is a subclass of int in Python; Nix keeps them apart.
    return type(value) is int


def _is_float(value: Any) -> bool:
    return type(value) is float


def _is_number(value: Any) -> bool:
    return _is_int(value) or _is_float(value)


def _describe(value: Any) -> str:
    if isinstance(value, dict):
        return "a table"
    if isinstance(value, list):
        return "an array"
    if isinstance(value, str):
        return "a string"
    if _is_int(value):
        return "an integer"
    if _is_float(value):
        return "a float"
    if _is_bool(value):
        return "a boolean"
    return f"a {type(value).__name__}"


def _type_matches(type_name: str, value: Any) -> bool:
    checks = {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": _is_int,
        "boolean": _is_bool,
    }
    if type_name not in checks:
        raise RuntimeError(f"dotsteward: internal error: unsupported schema type {to_json(type_name)}")
    return checks[type_name](value)


def nix_equal(left: Any, right: Any) -> bool:
    """Equality as Nix ``==``: numbers compare by value (1 == 1.0), booleans
    never equal numbers, lists and tables compare element-wise."""
    if _is_number(left) and _is_number(right):
        return left == right
    if _is_bool(left) or _is_bool(right):
        return _is_bool(left) and _is_bool(right) and left == right
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(nix_equal(a, b) for a, b in zip(left, right, strict=True))
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(nix_equal(left[k], right[k]) for k in left)
    if type(left) is not type(right):
        return False
    return left == right


def _elem(value: Any, values: Sequence[Any]) -> bool:
    return any(nix_equal(value, candidate) for candidate in values)


def _attr_names(table: Mapping[str, Any]) -> list[str]:
    """Keys in the order of Nix ``attrNames`` (byte order)."""
    return sorted(table, key=lambda key: key.encode("utf-8"))


def _sort_strings(values: Sequence[str]) -> list[str]:
    """``lib.sort lib.lessThan`` on strings (byte order)."""
    return sorted(values, key=lambda value: value.encode("utf-8"))


def to_json(value: Any) -> str:
    """``builtins.toJSON``: compact, keys sorted, non-ASCII kept."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)


def _translate_regex(pattern: str) -> str:
    """A POSIX extended regular expression of the schema subset as a Python
    pattern with Nix ``builtins.match`` semantics: outside bracket
    expressions an unescaped ``$`` matches only at the very end (never
    before a trailing newline); inside them every character, the backslash
    included, is literal."""
    out: list[str] = []
    i = 0
    n = len(pattern)
    while i < n:
        char = pattern[i]
        if char == "\\":
            if i + 1 >= n:
                raise RuntimeError(f"dotsteward: internal error: trailing backslash in pattern {to_json(pattern)}")
            out.append(pattern[i : i + 2])
            i += 2
        elif char == "[":
            j = i + 1
            members = ["["]
            if j < n and pattern[j] == "^":
                members.append("^")
                j += 1
            if j < n and pattern[j] == "]":
                members.append("\\]")
                j += 1
            while j < n and pattern[j] != "]":
                member = pattern[j]
                if member == "[" and j + 1 < n and pattern[j + 1] in ":.=":
                    raise RuntimeError(
                        f"dotsteward: internal error: unsupported bracket class in pattern {to_json(pattern)}"
                    )
                members.append(re.escape(member) if member in "\\[" else member)
                j += 1
            if j >= n:
                raise RuntimeError(f"dotsteward: internal error: unterminated bracket in pattern {to_json(pattern)}")
            members.append("]")
            out.append("".join(members))
            i = j + 1
        elif char == "$":
            out.append(r"\Z")
            i += 1
        else:
            out.append(char)
            i += 1
    return "".join(out)


@cache
def _compiled(regex: str) -> re.Pattern[str]:
    return re.compile(_translate_regex(regex), re.DOTALL)


def nix_match(regex: str, value: str) -> bool:
    """Whether ``builtins.match regex value`` is not null (a whole-string
    match; "." also matches a newline)."""
    return _compiled(regex).fullmatch(value) is not None


def _matches_pattern(pattern: str, value: str) -> bool:
    # JSON Schema "pattern" is a search, as in lib/config.nix.
    return nix_match(f".*({pattern}).*", value)


def _format_path(path: Sequence[str | int]) -> str:
    if not path:
        return "(root)"
    out = ""
    for segment in path:
        if isinstance(segment, int):
            out = f"{out}[{segment}]"
        else:
            key = segment if nix_match("[A-Za-z0-9_-]+", segment) else to_json(segment)
            out = key if out == "" else f"{out}.{key}"
    return out


def _plural(count: int, word: str) -> str:
    return f"{count} {word}{'' if count == 1 else 's'}"


def _one_of(values: Sequence[Any]) -> str:
    return ", ".join(to_json(value) for value in values)


def _duplicates(values: Sequence[Any]) -> list[Any]:
    repeated = [v for v in values if sum(1 for w in values if nix_equal(v, w)) > 1]
    unique: list[Any] = []
    for value in repeated:
        if not _elem(value, unique):
            unique.append(value)
    return unique


# --- Schema -------------------------------------------------------------------


def _schema_path(root: Path) -> Path:
    return root / "schema" / "workstation.schema.json"


@cache
def _load_schema(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def schema(root: Path = FRAMEWORK_ROOT) -> dict[str, Any]:
    """The parsed schema/workstation.schema.json of the framework."""
    return _load_schema(str(_schema_path(root)))


class _Validator:
    """The JSON Schema subset of lib/config.nix: validation and defaults."""

    def __init__(self, document: dict[str, Any]) -> None:
        self.document = document

    def deref(self, node: dict[str, Any]) -> dict[str, Any]:
        unsupported = [key for key in _attr_names(node) if key not in SUPPORTED_KEYWORDS]
        if unsupported:
            raise RuntimeError(f"dotsteward: internal error: unsupported schema keywords: {', '.join(unsupported)}")
        if "$ref" not in node:
            return node
        reference = node["$ref"]
        name = reference.removeprefix("#/$defs/")
        if name == reference or name not in self.document.get("$defs", {}):
            raise RuntimeError(f"dotsteward: internal error: unsupported schema reference {to_json(reference)}")
        merged = dict(self.deref(self.document["$defs"][name]))
        merged.update({key: value for key, value in node.items() if key != "$ref"})
        return merged

    # validateNode PATH NODE VALUE -> messages
    def validate(self, path: list[str | int], node: dict[str, Any], value: Any) -> list[str]:
        s = self.deref(node)
        at = _format_path(path)
        if "type" in s and not _type_matches(s["type"], value):
            return [f"{at}: expected {TYPE_NAMES[s['type']]}, got {_describe(value)}"]
        messages: list[str] = []
        if "const" in s and not nix_equal(value, s["const"]):
            messages.append(f"{at}: expected {to_json(s['const'])}, got {to_json(value)}")
        if "enum" in s and not _elem(value, s["enum"]):
            messages.append(f"{at}: expected one of {_one_of(s['enum'])}, got {to_json(value)}")
        if "pattern" in s and isinstance(value, str) and not _matches_pattern(s["pattern"], value):
            messages.append(f"{at}: {to_json(value)} does not match {to_json(s['pattern'])}")
        # Nix stringLength counts bytes.
        if "minLength" in s and isinstance(value, str) and len(value.encode("utf-8")) < s["minLength"]:
            if s["minLength"] == 1:
                messages.append(f"{at}: expected a non-empty string")
            else:
                messages.append(f"{at}: expected at least {_plural(s['minLength'], 'character')}")
        if "minimum" in s and _is_number(value) and value < s["minimum"]:
            messages.append(f"{at}: expected {_describe(value)} >= {s['minimum']}, got {to_json(value)}")
        if "maximum" in s and _is_number(value) and value > s["maximum"]:
            messages.append(f"{at}: expected {_describe(value)} <= {s['maximum']}, got {to_json(value)}")
        if isinstance(value, list):
            messages.extend(self._validate_array(path, s, value))
        if isinstance(value, dict):
            messages.extend(self._validate_object(path, s, value))
        return messages

    def _validate_array(self, path: list[str | int], s: dict[str, Any], value: list[Any]) -> list[str]:
        at = _format_path(path)
        messages: list[str] = []
        if "minItems" in s and len(value) < s["minItems"]:
            messages.append(f"{at}: expected at least {_plural(s['minItems'], 'item')}, got {len(value)}")
        if s.get("uniqueItems", False):
            messages.extend(f"{at}: duplicate item {to_json(v)}" for v in _duplicates(value))
        if "items" in s:
            for index, item in enumerate(value):
                messages.extend(self.validate([*path, index], s["items"], item))
        return messages

    # The reason a key fails propertyNames, or None when it is valid.
    def _key_name_problem(self, node: dict[str, Any], key: str) -> str | None:
        s = self.deref(node)
        if "enum" in s and not _elem(key, s["enum"]):
            return f"expected one of {_one_of(s['enum'])}"
        if "pattern" in s and not _matches_pattern(s["pattern"], key):
            return f"does not match {to_json(s['pattern'])}"
        return None

    def _validate_object(self, path: list[str | int], s: dict[str, Any], value: dict[str, Any]) -> list[str]:
        properties = s.get("properties", {})
        additional = s.get("additionalProperties", True)
        messages = [
            f"missing required key {_format_path([*path, key])}" for key in s.get("required", []) if key not in value
        ]
        for key in _attr_names(value):
            key_path: list[str | int] = [*path, key]
            # An invalid key name is the only problem reported for that key.
            problem = self._key_name_problem(s["propertyNames"], key) if "propertyNames" in s else None
            if problem is not None:
                messages.append(f"invalid key name {_format_path(key_path)}: {problem}")
            elif key in properties:
                messages.extend(self.validate(key_path, properties[key], value[key]))
            elif isinstance(additional, dict):
                messages.extend(self.validate(key_path, additional, value[key]))
            elif additional is False:
                messages.append(f"unknown key {_format_path(key_path)}")
        return messages

    # A missing optional table whose schema has properties is created, so its
    # leaf defaults apply.
    def _is_implicit_table(self, node: dict[str, Any]) -> bool:
        s = self.deref(node)
        return s.get("type") == "object" and "properties" in s and "default" not in s

    def apply_defaults(self, node: dict[str, Any], value: Any) -> Any:
        s = self.deref(node)
        if isinstance(value, dict) and s.get("type") == "object":
            properties = s.get("properties", {})
            additional = s.get("additionalProperties", True)
            required = s.get("required", [])
            known: dict[str, Any] = {}
            for key, child in properties.items():
                child_schema = self.deref(child)
                if key in value:
                    known[key] = self.apply_defaults(child, value[key])
                elif "default" in child_schema:
                    known[key] = copy.deepcopy(child_schema["default"])
                elif self._is_implicit_table(child) and key not in required:
                    known[key] = self.apply_defaults(child, {})
            extra = {
                key: self.apply_defaults(additional, item) if isinstance(additional, dict) else item
                for key, item in value.items()
                if key not in properties
            }
            return {**extra, **known}
        if isinstance(value, list) and "items" in s:
            return [self.apply_defaults(s["items"], item) for item in value]
        return value


# --- Catalog -----------------------------------------------------------------


def framework_catalog(root: Path = FRAMEWORK_ROOT) -> list[str]:
    """The catalog component names of the framework, like ``lib.catalog``:
    the catalog.json the CLI package writes (the package's modules/components
    holds only the directories of the components that carry a seed, so its
    listing is not the catalog), else the directories of modules/components
    in a checkout, else none."""
    catalog_file = root / "catalog.json"
    if catalog_file.exists():
        try:
            with open(catalog_file, encoding="utf-8") as handle:
                names = json.load(handle)
        except (OSError, ValueError) as error:
            raise DotstewardError(f"invalid catalog file {catalog_file}: {error}") from error
        if not isinstance(names, list) or not all(isinstance(n, str) and _is_component_name(n) for n in names):
            raise DotstewardError(f"invalid catalog file {catalog_file}: expected a JSON array of component names")
        return list(dict.fromkeys(names))
    components = root / "modules" / "components"
    if components.is_dir():
        return _sort_strings([entry.name for entry in os.scandir(components) if entry.is_dir(follow_symlinks=False)])
    return []


def _is_component_name(name: str) -> bool:
    return nix_match("[a-z][a-z0-9-]*", name)


def _order_catalog(catalog: Sequence[str]) -> list[str]:
    """Catalog names in canonical order, unknown ones sorted after them."""
    known = [name for name in CATALOG_ORDER if name in catalog]
    return known + _sort_strings([name for name in catalog if name not in CATALOG_ORDER])


# --- Reading ------------------------------------------------------------------


def _check_toml_values(value: Any, path: list[str | int]) -> None:
    """Refuses what Nix ``builtins.fromTOML`` refuses (dates and times) and
    what JSON cannot hold (non-finite floats)."""
    if isinstance(value, dict):
        for key in _attr_names(value):
            _check_toml_values(value[key], [*path, key])
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _check_toml_values(item, [*path, index])
    elif isinstance(value, (datetime.date, datetime.time)):
        raise ConfigError(f"invalid TOML: dates and times are not supported ({_format_path(path)})")
    elif _is_float(value) and not math.isfinite(value):
        raise ConfigError(f"invalid TOML: {_format_path(path)}: {value!r} is not a finite number")


def read_toml(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Parses a workstation.toml (raises DotstewardError or ConfigError)."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise DotstewardError(f"cannot read {path}: {error.strerror}") from error
    try:
        raw = tomllib.loads(data.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ConfigError(f"invalid TOML: not valid UTF-8 ({error.reason} at byte {error.start})") from error
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"invalid TOML: {error}") from error
    _check_toml_values(raw, [])
    return raw


# --- Validation and resolution (lib/config.nix) ---------------------------------


def _version_errors(raw: dict[str, Any]) -> list[str]:
    if "schema_version" not in raw:
        return ["missing required key schema_version"]
    version = raw["schema_version"]
    if not _is_int(version):
        return [f"schema_version: expected an integer, got {_describe(version)}"]
    if version != SUPPORTED_VERSION:
        return [
            f"schema_version {version} is not supported; this dotsteward reads schema_version "
            f"{SUPPORTED_VERSION} (update the dotsteward flake input to a release that reads it)"
        ]
    return []


def _not_a_profile(path: list[str | int], value: Any) -> str:
    return f"{_format_path(path)}: {to_json(value)} is not in profiles.names"


# Rules across keys; only run on a schema-valid file.
def _semantic_errors(document: dict[str, Any], raw: dict[str, Any], catalog: Sequence[str]) -> list[str]:
    catalog_names = _order_catalog(catalog)
    profiles = raw["profiles"]
    names = profiles["names"]
    systems = raw["nix"].get("systems", document["properties"]["nix"]["properties"]["systems"]["default"])
    username = raw["identity"]["username"]
    components = raw.get("components", {})
    tables = {key: value for key, value in components.items() if key != "order"}

    messages: list[str] = []
    if any(system.endswith("-linux") for system in systems) and not nix_match(LINUX_USER_PATTERN, username):
        messages.append(f"identity.username: {to_json(username)} is not a valid Linux user name ({LINUX_USER_PATTERN})")

    for index, name in enumerate(names):
        if name in PROFILE_KEYS:
            messages.append(
                f"profiles.names[{index}]: {to_json(name)} is reserved "
                "(profiles.names, default, check and bootstrap are keys of [profiles])"
            )
    for role in PROFILE_KEYS[1:]:
        if role in profiles and not _elem(profiles[role], names):
            messages.append(_not_a_profile(["profiles", role], profiles[role]))
    for key in _attr_names(profiles):
        if key not in PROFILE_KEYS and not _elem(key, names):
            messages.append(f"unknown key {_format_path(['profiles', key])} (not a profile in profiles.names)")

    for name in _attr_names(components):
        if name == "order":
            for index, entry in enumerate(components["order"]):
                if entry not in catalog_names and entry not in tables:
                    messages.append(
                        f"components.order[{index}]: unknown component name {to_json(entry)} "
                        f"(neither a catalog component nor a [components.{entry}] table)"
                    )
            continue
        table = tables[name]
        if table.get("source") == "catalog" and name not in catalog_names:
            messages.append(
                f"components.{name}.source: {name} is not a catalog component (catalog: {', '.join(catalog_names)})"
            )
        for index, profile in enumerate(table.get("profiles", [])):
            if not _elem(profile, names):
                messages.append(_not_a_profile(["components", name, "profiles", index], profile))

    aliases = raw.get("compat", {}).get("check_aliases", {})
    builtin_checks = ["home", *(f"home-{name}" for name in names)]
    for alias in _attr_names(aliases):
        path: list[str | int] = ["compat", "check_aliases", alias]
        if not _elem(aliases[alias], names):
            messages.append(_not_a_profile(path, aliases[alias]))
        if alias in builtin_checks:
            messages.append(f"{_format_path(path)}: collides with the built-in check {alias}")
    return messages


def errors(
    raw: dict[str, Any],
    catalog: Sequence[str] | None = None,
    *,
    root: Path = FRAMEWORK_ROOT,
) -> list[str]:
    """The validation messages of a parsed workstation.toml ([] when valid),
    exactly as ``lib/config.nix`` ``errors`` reports them."""
    if catalog is None:
        catalog = framework_catalog(root)
    version = _version_errors(raw)
    if version:
        return version
    document = schema(root)
    schema_errors = _Validator(document).validate([], document, raw)
    if schema_errors:
        return schema_errors
    return _semantic_errors(document, raw, catalog)


def _build(
    document: dict[str, Any], raw: dict[str, Any], catalog: Sequence[str], instance_name: str | None
) -> dict[str, Any]:
    validator = _Validator(document)
    c = validator.apply_defaults(document, raw)
    catalog_names = _order_catalog(catalog)
    username = c["identity"]["username"]

    names = c["profiles"]["names"]
    default_profile = c["profiles"].get("default", names[0])
    profile_schema = document["$defs"]["profile"]

    name = c["instance"].get("name", instance_name)

    component_schema = document["$defs"]["component"]
    tables = {key: value for key, value in c["components"].items() if key != "order"}
    instance_names = _sort_strings([n for n in tables if n not in catalog_names])
    given_order = c["components"].get("order", [])
    order = [*given_order, *(n for n in catalog_names + instance_names if n not in given_order)]

    def component_for(component: str) -> dict[str, Any]:
        table = tables[component] if component in tables else validator.apply_defaults(component_schema, {})
        default_source = "catalog" if component in catalog_names else "instance"
        return {**table, "source": table.get("source", default_source)}

    resolved = dict(c)
    resolved["identity"] = {
        **c["identity"],
        "home": c["identity"].get("home", f"/home/{username}"),
        "darwin_home": c["identity"].get("darwin_home", f"/Users/{username}"),
    }
    resolved["instance"] = {
        **c["instance"],
        "name": name,
        "checkout": c["instance"].get("checkout", None if name is None else f"~/{name}"),
    }
    resolved["profiles"] = {
        **c["profiles"],
        "default": default_profile,
        "check": c["profiles"].get("check", default_profile),
        "bootstrap": c["profiles"].get("bootstrap", default_profile),
        **{
            profile: c["profiles"][profile]
            if profile in c["profiles"]
            else validator.apply_defaults(profile_schema, {})
            for profile in names
        },
    }
    resolved["components"] = {
        **{component: component_for(component) for component in catalog_names + instance_names},
        "order": order,
    }
    resolved["settings"] = {
        **c["settings"],
        "published_ref": c["settings"].get("published_ref", f"origin/{c['instance']['branch']}"),
    }
    return resolved


def resolve(
    raw: dict[str, Any],
    catalog: Sequence[str] | None = None,
    instance_name: str | None = None,
    *,
    root: Path = FRAMEWORK_ROOT,
) -> dict[str, Any]:
    """The resolved configuration (every schema key, defaults filled), equal
    to ``lib/config.nix`` ``resolve``; raises ConfigError with every message
    of an invalid file."""
    if catalog is None:
        catalog = framework_catalog(root)
    problems = errors(raw, catalog, root=root)
    if problems:
        raise ConfigError(*problems)
    return _build(schema(root), raw, catalog, instance_name)


def method_for(config: Mapping[str, Any], name: str, platform_name: str) -> str | None:
    """The method configured for a component on a platform ("linux" or
    "darwin"): method_by_platform, then method; None means the component's
    own default (``lib/config.nix`` ``methodFor``)."""
    component = config["components"].get(name)
    if not isinstance(component, dict):
        raise DotstewardError(f"unknown component name {to_json(name)}")
    by_platform = (component.get("method_by_platform") or {}).get(platform_name)
    return by_platform if by_platform is not None else component.get("method")


# --- Run time: discovery, expansion, environment -----------------------------------


def _env_get(env: Mapping[str, str], name: str) -> str | None:
    """A variable's value; empty counts as unset, like ${VAR:-...}."""
    value = env.get(name)
    return value if value else None


def _instance_dir(path: str, label: str) -> Path:
    candidate = Path(path)
    if not candidate.is_dir():
        raise DotstewardError(f"{label}: not a directory: {path}")
    if not (candidate / CONFIG_FILE).is_file():
        raise DotstewardError(f"{label}: no {CONFIG_FILE} in {path}")
    return candidate.resolve()


def _legacy_root(path: str) -> Path | None:
    """DOTFILES_ROOT, when its workstation.toml sets compat.legacy_env."""
    candidate = Path(path)
    try:
        raw = read_toml(candidate / CONFIG_FILE)
    except DotstewardError:
        return None
    compat = raw.get("compat")
    if isinstance(compat, dict) and compat.get("legacy_env") is True:
        return candidate.resolve()
    return None


def discover_instance(
    explicit: str | None = None,
    *,
    env: Mapping[str, str] | None = None,
    cwd: str | os.PathLike[str] | None = None,
) -> Path:
    """The instance root (physical path), SPEC 6.1: ``--instance`` >
    DOTSTEWARD_INSTANCE > (DOTFILES_ROOT when its configuration sets
    compat.legacy_env) > the nearest workstation.toml above the working
    directory."""
    env = os.environ if env is None else env
    if explicit is not None:
        return _instance_dir(explicit, "--instance")
    value = _env_get(env, "DOTSTEWARD_INSTANCE")
    if value is not None:
        return _instance_dir(value, "DOTSTEWARD_INSTANCE")
    value = _env_get(env, "DOTFILES_ROOT")
    if value is not None:
        legacy = _legacy_root(value)
        if legacy is not None:
            return legacy
    start = Path(os.getcwd() if cwd is None else cwd)
    for directory in (start, *start.parents):
        if (directory / CONFIG_FILE).is_file():
            return directory.resolve()
    raise DotstewardError(
        f"no instance found: no {CONFIG_FILE} in {start} or its parent directories "
        "(use --instance DIR or DOTSTEWARD_INSTANCE)"
    )


@dataclass(frozen=True)
class Instance:
    """A loaded instance: its root, configuration file and resolved
    configuration (instance.name falls back to the directory name)."""

    root: Path
    file: Path
    config: dict[str, Any]


def load_instance(
    explicit: str | None = None,
    *,
    env: Mapping[str, str] | None = None,
    cwd: str | os.PathLike[str] | None = None,
    catalog: Sequence[str] | None = None,
    root: Path = FRAMEWORK_ROOT,
) -> Instance:
    """Discovers, reads and resolves the instance configuration."""
    instance_root = discover_instance(explicit, env=env, cwd=cwd)
    file = instance_root / CONFIG_FILE
    config = resolve(read_toml(file), catalog, instance_root.name, root=root)
    return Instance(instance_root, file, config)


def runtime_platform(env: Mapping[str, str] | None = None) -> str:
    """linux or darwin: DOTSTEWARD_PLATFORM, else the running system."""
    env = os.environ if env is None else env
    value = _env_get(env, "DOTSTEWARD_PLATFORM")
    if value is not None:
        if value not in ("linux", "darwin"):
            raise DotstewardError(f"DOTSTEWARD_PLATFORM: expected linux or darwin, got {value}")
        return value
    system = platform.system()
    if system == "Linux":
        return "linux"
    if system == "Darwin":
        return "darwin"
    raise DotstewardError(f"unsupported operating system: {system}")


_EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}(.*)", re.DOTALL)


def expand_path(value: str, env: Mapping[str, str]) -> str:
    """Expands a leading ``${NAME:-DEFAULT}`` (NAME when set and non-empty)
    and then a leading ``~`` or ``~/`` with HOME, as the shell would."""
    match = _EXPANSION.fullmatch(value)
    if match:
        value = (_env_get(env, match.group(1)) or match.group(2)) + match.group(3)
    if value == "~" or value.startswith("~/"):
        home = _env_get(env, "HOME")
        if home is None:
            raise DotstewardError("HOME is not set")
        value = home + value[1:]
    return value


def _user_path(config: Mapping[str, Any], section: str, key: str, env: Mapping[str, str]) -> str:
    value = config[section][key]
    expanded = expand_path(value, env)
    if not os.path.isabs(expanded):
        raise ConfigError(f"{section}.{key}: expands to a relative path: {to_json(value)}")
    return expanded


@dataclass(frozen=True)
class _Override:
    name: str
    legacy: str


def _override(env: Mapping[str, str], names: _Override, legacy_env: bool) -> tuple[str, str] | None:
    value = _env_get(env, names.name)
    if value is not None:
        return names.name, value
    if legacy_env:
        value = _env_get(env, names.legacy)
        if value is not None:
            return names.legacy, value
    return None


def runtime_values(instance: Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The run-time values of an instance: expanded paths, the environment
    overrides of SPEC 6.1 and the effective skill overlays. Raises
    DotstewardError with every problem of the environment."""
    env = os.environ if env is None else env
    config = instance.config
    document = schema()
    legacy_env = config["compat"]["legacy_env"] is True
    gate_schema = document["properties"]["gate"]["properties"]
    problems: list[str] = []

    state_root = _override(env, _Override("DOTSTEWARD_STATE_ROOT", "DOTFILES_STATE_ROOT"), legacy_env)
    if state_root is None:
        state_root_value = _user_path(config, "state", "root", env)
    else:
        name, state_root_value = state_root
        if not os.path.isabs(state_root_value):
            problems.append(f"{name}: expected an absolute path, got {to_json(state_root_value)}")

    gate: dict[str, Any] = {}
    for key, names in (
        ("nix_max_jobs", _Override("DOTSTEWARD_NIX_MAX_JOBS", "DOTFILES_NIX_MAX_JOBS")),
        ("nix_cores", _Override("DOTSTEWARD_NIX_CORES", "DOTFILES_NIX_CORES")),
        ("min_free_gib", _Override("DOTSTEWARD_MIN_FREE_GB", "DOTFILES_MIN_FREE_GB")),
    ):
        gate[key] = config["gate"][key]
        override = _override(env, names, legacy_env)
        if override is None:
            continue
        name, value = override
        minimum = gate_schema[key]["minimum"]
        if re.fullmatch(r"[0-9]+", value, re.ASCII) and int(value) >= minimum:
            gate[key] = int(value)
        else:
            problems.append(f"{name}: expected an integer >= {minimum}, got {to_json(value)}")
    gate["cache_url"] = config["gate"]["cache_url"]
    override = _override(env, _Override("DOTSTEWARD_CACHE_URL", "DOTFILES_CACHE_URL"), legacy_env)
    if override is not None:
        name, value = override
        pattern = gate_schema["cache_url"]["pattern"]
        if _matches_pattern(pattern, value):
            gate["cache_url"] = value
        else:
            problems.append(f"{name}: {to_json(value)} does not match {to_json(pattern)}")
    if problems:
        raise DotstewardError(*problems)

    denylist = config["privacy"]["denylist"]
    if denylist is not None:
        denylist = expand_path(denylist, env)
        if not os.path.isabs(denylist):
            denylist = str(instance.root / denylist)

    overlays = dict(config["skills"]["overlays"])
    for skill in document["properties"]["skills"]["properties"]["overlays"]["propertyNames"]["enum"]:
        default = f"agent/overlays/{skill}.md"
        if skill not in overlays and (instance.root / default).is_file():
            overlays[skill] = default

    return {
        "platform": runtime_platform(env),
        "state_root": state_root_value,
        "checkout": _user_path(config, "instance", "checkout", env),
        "local_clone": _user_path(config, "upstream", "local_clone", env),
        "denylist": denylist,
        "gate": gate,
        "overlays": overlays,
    }


# --- DS_* export ----------------------------------------------------------------


def _is_control(char: str) -> bool:
    return ord(char) < 0x20 or ord(char) == 0x7F  # noqa: PLR2004 # C0 controls and DEL


def _shell_quote(value: str) -> str:
    """A bash word for value: single quotes, or $'...' when it holds control
    characters, so every declaration stays on one line."""
    if "\0" in value:
        raise DotstewardError("a configuration value contains a NUL character, which a shell variable cannot hold")
    if not any(_is_control(char) for char in value):
        return "'" + value.replace("'", "'\\''") + "'"
    out = []
    for char in value:
        if char == "\\":
            out.append("\\\\")
        elif char == "'":
            out.append("\\'")
        elif char == "\n":
            out.append("\\n")
        elif char == "\t":
            out.append("\\t")
        elif char == "\r":
            out.append("\\r")
        elif _is_control(char):
            out.append(f"\\x{ord(char):02x}")
        else:
            out.append(char)
    return "$'" + "".join(out) + "'"


def _scalar(value: Any) -> str:
    if value is None:
        return ""
    if _is_bool(value):
        return "true" if value else "false"
    return str(value)


def export_variables(instance: Instance, env: Mapping[str, str] | None = None) -> list[str]:
    """The DS_* declarations of an instance for bash (``cli/lib/config.sh``
    documents every name), one per line: exported scalars
    (``declare -gx``), indexed arrays (``declare -ga``) and associative
    arrays (``declare -gA``)."""
    values = runtime_values(instance, env)
    c = instance.config
    names = c["profiles"]["names"]
    order = c["components"]["order"]
    components = c["components"]
    platform_name = values["platform"]
    gate = values["gate"]
    linux = c["platform"]["linux"]["fast_path"]
    darwin = c["platform"]["darwin"]["fast_path"]

    scalars: list[tuple[str, Any]] = [
        ("DS_CONFIG_FILE", str(instance.file)),
        ("DS_INSTANCE_ROOT", str(instance.root)),
        ("DS_RUNTIME_PLATFORM", platform_name),
        ("DS_CONFIG_JSON", to_json(c)),
        ("DS_IDENTITY_USERNAME", c["identity"]["username"]),
        ("DS_IDENTITY_HOME", c["identity"]["home"]),
        ("DS_IDENTITY_DARWIN_HOME", c["identity"]["darwin_home"]),
        ("DS_INSTANCE_NAME", c["instance"]["name"]),
        ("DS_INSTANCE_REMOTE", c["instance"]["remote"]),
        ("DS_INSTANCE_BRANCH", c["instance"]["branch"]),
        ("DS_INSTANCE_CHECKOUT", values["checkout"]),
        ("DS_STATE_ROOT", values["state_root"]),
        ("DS_NIX_PRIMARY_SYSTEM", c["nix"]["systems"][0]),
        ("DS_NIX_ALLOW_UNFREE", c["nix"]["allow_unfree"]),
        ("DS_NIX_STATE_VERSION", c["nix"]["state_version"]),
        ("DS_PROFILES_DEFAULT", c["profiles"]["default"]),
        ("DS_PROFILES_CHECK", c["profiles"]["check"]),
        ("DS_PROFILES_BOOTSTRAP", c["profiles"]["bootstrap"]),
        ("DS_PLATFORM_LINUX_OS_ID", linux["os_id"]),
        ("DS_PLATFORM_LINUX_OS_VERSION", linux["os_version"]),
        ("DS_PLATFORM_LINUX_ARCHITECTURE", linux["architecture"]),
        ("DS_PLATFORM_LINUX_DESKTOP_CONTAINS", linux["desktop_contains"]),
        ("DS_PLATFORM_DARWIN_MIN_VERSION", darwin["min_version"]),
        ("DS_PLATFORM_DARWIN_ARCHITECTURE", darwin["architecture"]),
        ("DS_GATE_NIX_MAX_JOBS", gate["nix_max_jobs"]),
        ("DS_GATE_NIX_CORES", gate["nix_cores"]),
        ("DS_GATE_MIN_FREE_GIB", gate["min_free_gib"]),
        ("DS_GATE_PREPARE_WARN_FREE_GIB", c["gate"]["prepare_warn_free_gib"]),
        ("DS_GATE_CACHE_URL", gate["cache_url"]),
        ("DS_COMMIT_UPDATE_SUBJECT", c["commit"]["update_subject"]),
        ("DS_COMMIT_SETTINGS_SUBJECT", c["commit"]["settings_subject"]),
        ("DS_COMMIT_UPGRADE_SUBJECT", c["commit"]["upgrade_subject"]),
        ("DS_SETTINGS_BUFFER_DIR", c["settings"]["buffer_dir"]),
        ("DS_SETTINGS_PUBLISHED_REF", c["settings"]["published_ref"]),
        ("DS_SKILLS_LOCK", c["skills"]["lock"]),
        ("DS_SKILLS_VENDOR_DIR", c["skills"]["vendor_dir"]),
        ("DS_SKILLS_HM_ROOT", c["skills"]["hm_root"]),
        ("DS_PINS_VERSIONS_LOCK", c["pins"]["versions_lock"]),
        ("DS_PINS_APT_ARCH", c["pins"]["apt_arch"]),
        ("DS_PRIVACY_DENYLIST", values["denylist"]),
        ("DS_PRIVACY_FILE_RULES_JSON", to_json(c["privacy"]["file_rules"])),
        ("DS_AGENT_RULES_SOURCE", c["agent_rules"]["source"]),
        ("DS_UPSTREAM_CONTRIBUTE", c["upstream"]["contribute"]),
        ("DS_UPSTREAM_FORK", c["upstream"]["fork"]),
        ("DS_UPSTREAM_PR_TO_UPSTREAM", c["upstream"]["pr_to_upstream"]),
        ("DS_UPSTREAM_LOCAL_CLONE", values["local_clone"]),
        ("DS_COMPAT_LEGACY_ENV", c["compat"]["legacy_env"]),
        ("DS_COMPAT_LEGACY_BACKUP_LAYOUT", c["compat"]["legacy_backup_layout"]),
        ("DS_COMPAT_REPO_OWNED_REVISION", c["compat"]["repo_owned_revision"]),
        ("DS_COMPAT_HOST_INPUT", c["compat"]["host_input"]),
    ]
    arrays: list[tuple[str, Sequence[Any]]] = [
        ("DS_NIX_SYSTEMS", c["nix"]["systems"]),
        ("DS_PROFILES_NAMES", names),
        ("DS_PLATFORM_LINUX_DETECTORS", linux["detectors"]),
        ("DS_GATE_STATIC", c["gate"]["static"]),
        ("DS_GATE_UPDATE_ALLOWLIST", c["gate"]["update_allowlist"]),
        ("DS_COMPONENTS_ORDER", order),
        ("DS_COMPONENTS_ENABLED", [name for name in order if components[name]["enable"]]),
        ("DS_SKILLS_INSTALLER", c["skills"]["installer"] or []),
        ("DS_PINS_EXCLUDED_FLAKE_INPUTS", c["pins"]["excluded_flake_inputs"]),
        ("DS_PRIVACY_FORBIDDEN_PATHS", c["privacy"]["forbidden_paths"]),
    ]
    tables: list[tuple[str, Mapping[str, Any]]] = [
        ("DS_PROFILE_MODE", {name: c["profiles"][name]["mode"] for name in names}),
        ("DS_COMPONENT_ENABLE", {name: components[name]["enable"] for name in order}),
        ("DS_COMPONENT_SOURCE", {name: components[name]["source"] for name in order}),
        ("DS_COMPONENT_METHOD", {name: method_for(c, name, platform_name) for name in order}),
        (
            "DS_COMPONENT_PROFILES",
            {name: " ".join(components[name]["profiles"] or []) for name in order},
        ),
        ("DS_SKILLS_OVERLAYS", values["overlays"]),
        ("DS_PINS_NIXPKGS_VERSIONS", c["pins"]["nixpkgs_versions"]),
        ("DS_PROTECTED", c["protected"]),
        ("DS_COMPAT_CHECK_ALIASES", c["compat"]["check_aliases"]),
    ]

    lines = [f"declare -gx {name}={_shell_quote(_scalar(value))}" for name, value in scalars]
    lines += [
        f"declare -ga {name}=({' '.join(_shell_quote(_scalar(item)) for item in items)})" for name, items in arrays
    ]
    lines += [
        f"declare -gA {name}=("
        + " ".join(f"[{_shell_quote(key)}]={_shell_quote(_scalar(table[key]))}" for key in _attr_names(table))
        + ")"
        for name, table in tables
    ]
    return lines


# --- Command line -------------------------------------------------------------------


class _Parser(argparse.ArgumentParser):
    """Usage errors exit 1 (the bash convention), not argparse's 2."""

    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        _write(f"[dotsteward] ERROR: {message}", sys.stderr)
        sys.exit(1)


def _parse_catalog(parser: _Parser, value: str | None) -> list[str] | None:
    if value is None:
        return None
    names = [name for name in value.split(",") if name != ""]
    for name in names:
        if not _is_component_name(name):
            parser.error(f"invalid catalog component name: {name!r}")
    return list(dict.fromkeys(names))


def _parser() -> _Parser:
    parser = _Parser(
        prog="python3 -m dotsteward_cli.config",
        description="Read, validate and export an instance workstation.toml.",
        epilog=(
            "commands: resolve (the resolved configuration as JSON), errors (the validation "
            "messages as a JSON array), export (DS_* declarations for bash), discover (the "
            "instance root)"
        ),
    )
    parser.add_argument("command", choices=("resolve", "errors", "export", "discover"))
    parser.add_argument("--instance", metavar="DIR", help="the instance root (default: discovery)")
    parser.add_argument("--file", metavar="PATH", help="read this file instead of an instance's workstation.toml")
    parser.add_argument(
        "--catalog",
        metavar="NAMES",
        help="comma-separated catalog component names (default: the framework catalog)",
    )
    parser.add_argument(
        "--instance-name",
        metavar="NAME",
        help="default of instance.name (default: the instance directory name; none with --file)",
    )
    return parser


def _write(text: str, stream: Any = None) -> None:
    """Writes one line as UTF-8 whatever the locale (paths keep their bytes)."""
    stream = sys.stdout if stream is None else stream
    stream.flush()
    stream.buffer.write((text + "\n").encode("utf-8", "surrogateescape"))
    stream.buffer.flush()


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.file is not None and args.instance is not None:
        parser.error("--file and --instance are mutually exclusive")
    catalog = _parse_catalog(parser, args.catalog)
    try:
        if args.command == "discover":
            _write(str(discover_instance(args.instance)))
            return 0
        if catalog is None:
            catalog = framework_catalog()
        if args.file is not None:
            file = Path(args.file)
            instance_root = None
        else:
            instance_root = discover_instance(args.instance)
            file = instance_root / CONFIG_FILE
        raw = read_toml(file)
        if args.command == "errors":
            _write(json.dumps(errors(raw, catalog), ensure_ascii=False))
            return 0
        if args.command == "resolve":
            name = args.instance_name
            if name is None and instance_root is not None:
                name = instance_root.name
            _write(to_json(resolve(raw, catalog, name)))
            return 0
        root = instance_root if instance_root is not None else file.parent.resolve()
        name = args.instance_name if args.instance_name is not None else root.name
        instance = Instance(root, root / file.name if instance_root is None else file, resolve(raw, catalog, name))
        _write("\n".join(export_variables(instance)))
        return 0
    except DotstewardError as error:
        for line in error.lines():
            _write(line, sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
