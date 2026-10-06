"""The facts of an instance on this machine: ``dotsteward context`` (SPEC 6.5).

The document (``schema/context.schema.json``, ``schema_version`` 1) joins:

- the resolved ``workstation.toml`` with the run-time layer of
  ``config.py`` (expanded paths, environment overrides, effective overlays);
- the runtime identity (``USER`` and ``HOME``) next to the check identity
  ``[identity]`` (SPEC 4.4);
- the state records: ``<state root>/current/profile`` and the gate record
  paths below ``<state root>/update``;
- the ``.dotsteward/manifest.<system>.json`` mirror of the running system
  (component methods, settings targets and commands, home-managed skills);
- the settings buffer ``<settings.buffer_dir>/buffer.toml`` (target names and
  entry ids only: settings values are never read into the document);
- the skills lock (``skills.lock``, skill names only);
- the running framework (``VERSION`` and ``source-info``, as
  ``dotsteward version``) and the ``dotsteward`` input of ``flake.lock``
  (D17).

A missing mirror, buffer, skills lock, ``flake.lock`` or state record is not
an error: the facts it would add are empty or null. A buffer, skills lock,
``flake.lock``, recorded profile or ``source-info`` that exists but cannot be
read is a refusal, because the facts would be incomplete; a mirror that
cannot be read is ignored here and reported by ``doctor``.

Command line (used by ``cli/commands/context.sh``)::

    python3 -m dotsteward_cli.context [--json]

The instance comes from ``DOTSTEWARD_INSTANCE`` (the dispatcher's
``--instance``) or discovery (SPEC 6.1). ``--json`` prints the document as
one JSON document on standard output; without it every fact is one
``[dotsteward] key: value`` line. Exit status 0, or 1 for a usage error, an
invalid configuration or environment, or an unreadable source; messages go
to standard error as ``[dotsteward] ERROR:`` lines.

Python API (for ``doctor``): ``build_context``, ``nix_system``,
``framework_version``, ``GATE_STEP_KEYS``, ``CONVENTIONAL_TYPES``.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import tomllib
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import config

SCHEMA_VERSION = 1

# The gate steps in order: the keys of validation.json step_seconds (D4).
GATE_STEP_KEYS = ("preflight", "static", "pins", "flake-check", "cli-probes")

# The commit types of the maintain scope, the one source for the gate's
# subject rule and the skills' text.
CONVENTIONAL_TYPES = ("feat", "fix", "perf", "refactor", "docs", "chore", "test", "build", "ci", "style", "revert")

# Inputs and records, relative to their roots.
MIRROR_DIR = ".dotsteward"
BUFFER_FILE = "buffer.toml"
FLAKE_LOCK = "flake.lock"
FRAMEWORK_INPUT = "dotsteward"
CURRENT_PROFILE = "current/profile"
UPDATE_DIR = "update"

_MACHINES = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64"}


class ContextError(config.DotstewardError):
    """A source of the context that exists but cannot be used."""


# --- Small readers -------------------------------------------------------------------


def nix_system(platform_name: str) -> str:
    """The Nix system of the running machine for platform_name (linux or
    darwin): <machine>-<platform>, as the settings engine computes it."""
    machine = platform.machine().lower()
    return f"{_MACHINES.get(machine, machine)}-{platform_name}"


def _read_text(path: Path) -> str | None:
    """The text of a regular file, or None when it does not exist."""
    try:
        return path.read_text(encoding="utf-8", errors="surrogateescape")
    except FileNotFoundError:
        return None
    except IsADirectoryError:
        return None


def read_json(path: Path) -> Any:
    """The JSON value of path, None when it does not exist; ValueError or
    OSError for a file that cannot be read."""
    text = _read_text(path)
    if text is None:
        return None
    return json.loads(text)


def read_mirror(instance: config.Instance, system: str) -> dict[str, Any] | None:
    """The manifest mirror of system, or None when it is missing or cannot
    be used (doctor reports why)."""
    try:
        mirror = read_json(instance.root / MIRROR_DIR / f"manifest.{system}.json")
    except (OSError, ValueError):
        return None
    return mirror if isinstance(mirror, dict) else None


def _relative(instance: config.Instance, path: Path) -> str:
    try:
        return str(path.relative_to(instance.root))
    except ValueError:
        return str(path)


def _names(value: Any) -> list[str]:
    """The strings of a JSON array; anything else is no names."""
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _field(table: Mapping[str, Any] | None, key: str, kind: type[dict] | type[list]) -> Any:
    """table[key] when table is a mapping and the value has the JSON type
    kind (dict or list), else an empty value of that type."""
    value = table.get(key) if isinstance(table, Mapping) else None
    return value if isinstance(value, kind) else kind()


def _unique(values: Sequence[str]) -> list[str]:
    return list(dict.fromkeys(values))


def _sorted(values: Any) -> list[str]:
    """Strings in byte order (as Nix and jq sort them)."""
    return sorted(values, key=lambda value: value.encode("utf-8", "surrogateescape"))


# --- Sources -------------------------------------------------------------------------


def framework_version(root: Path = config.FRAMEWORK_ROOT) -> dict[str, str | None]:
    """version, rev and narHash of the running framework, as ``dotsteward
    version`` reports them: VERSION; source-info (baked into the package);
    else, in a git checkout whose top level is the framework root, HEAD with
    -dirty when tracked files changed; else null."""
    try:
        version = (root / "VERSION").read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ContextError(f"cannot read the framework version {root / 'VERSION'}: {error.strerror}") from error
    rev: str | None = None
    nar_hash: str | None = None
    try:
        info = _read_text(root / "source-info")
    except OSError as error:
        raise ContextError(f"cannot read the framework source-info {root / 'source-info'}: {error.strerror}") from error
    if info is not None:
        for line in info.splitlines():
            if line.startswith("rev="):
                rev = line.removeprefix("rev=") or None
            elif line.startswith("narHash="):
                nar_hash = line.removeprefix("narHash=") or None
    else:
        rev = _git_rev(root)
    return {"version": version, "rev": rev, "narHash": nar_hash}


def _git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )


def _git_rev(root: Path) -> str | None:
    try:
        toplevel = _git(root, "rev-parse", "--show-toplevel")
        if toplevel.returncode != 0 or Path(toplevel.stdout.strip()).resolve() != root.resolve():
            return None
        head = _git(root, "rev-parse", "--verify", "--quiet", "HEAD")
        if head.returncode != 0:
            return None
        rev = head.stdout.strip()
        if _git(root, "diff", "--quiet", "HEAD", "--").returncode != 0:
            rev += "-dirty"
        return rev
    except OSError:
        return None


def framework_input(instance: config.Instance) -> tuple[str | None, str | None]:
    """(upstream, track) of the dotsteward input of the instance flake.lock
    (D17): the flake reference of its original source without ref and rev,
    and the original ref. (None, None) without flake.lock, without the input
    or for an input that follows another one."""
    path = instance.root / FLAKE_LOCK
    try:
        lock = read_json(path)
    except (OSError, ValueError) as error:
        raise ContextError(f"cannot read {FLAKE_LOCK}: {error}") from error
    if lock is None:
        return None, None
    nodes = lock.get("nodes") if isinstance(lock, dict) else None
    if not isinstance(nodes, dict):
        raise ContextError(f"{FLAKE_LOCK}: no nodes table")
    root = nodes.get(lock.get("root", "root"))
    inputs = root.get("inputs") if isinstance(root, dict) else None
    key = inputs.get(FRAMEWORK_INPUT) if isinstance(inputs, dict) else None
    node = nodes.get(key) if isinstance(key, str) else None
    original = node.get("original") if isinstance(node, dict) else None
    if not isinstance(original, dict):
        return None, None
    ref = original.get("ref")
    return _flake_reference(original), ref if isinstance(ref, str) and ref else None


def _flake_reference(original: Mapping[str, Any]) -> str | None:
    kind = original.get("type")
    if kind in ("github", "gitlab", "sourcehut"):
        owner, repo = original.get("owner"), original.get("repo")
        if isinstance(owner, str) and isinstance(repo, str):
            host = original.get("host")
            query = f"?host={host}" if isinstance(host, str) and host else ""
            return f"{kind}:{owner}/{repo}{query}"
        return None
    url = original.get("url")
    if kind in ("git", "hg", "tarball", "file") and isinstance(url, str):
        return url if url.startswith(f"{kind}+") or kind in ("tarball", "file") else f"{kind}+{url}"
    path = original.get("path")
    if kind == "path" and isinstance(path, str):
        return f"path:{path}"
    if kind == "indirect" and isinstance(original.get("id"), str):
        return f"flake:{original['id']}"
    return None


def read_buffer(instance: config.Instance) -> tuple[list[str], list[str]]:
    """(target names, entry ids) of the settings buffer; empty without one.
    Only the names are read: values stay out of the document."""
    relative = f"{instance.config['settings']['buffer_dir']}/{BUFFER_FILE}"
    path = instance.root / relative
    try:
        text = _read_text(path)
    except OSError as error:
        raise ContextError(f"{relative}: cannot read the settings buffer: {error.strerror}") from error
    if text is None:
        return [], []
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise ContextError(f"{relative}: invalid TOML: {error}") from error
    targets = document.get("targets", {})
    if not isinstance(targets, dict):
        raise ContextError(f"{relative}: targets must be a table")
    entries = document.get("entries", [])
    if not isinstance(entries, list):
        raise ContextError(f"{relative}: entries must be an array of tables")
    ids: list[str] = []
    for index, entry in enumerate(entries):
        entry_id = entry.get("id") if isinstance(entry, dict) else None
        if not isinstance(entry_id, str) or not entry_id:
            raise ContextError(f"{relative}: entries[{index}] has no id")
        ids.append(entry_id)
    return list(targets), _unique(ids)


def read_skills_lock(instance: config.Instance) -> list[str]:
    """The skill names of the instance's skills lock; empty without one."""
    relative = instance.config["skills"]["lock"]
    try:
        lock = read_json(instance.root / relative)
    except (OSError, ValueError) as error:
        raise ContextError(f"{relative}: cannot read the skills lock: {error}") from error
    if lock is None:
        return []
    skills = lock.get("skills", []) if isinstance(lock, dict) else None
    if not isinstance(skills, list):
        raise ContextError(f"{relative}: skills must be an array")
    names: list[str] = []
    for index, skill in enumerate(skills):
        name = skill.get("name") if isinstance(skill, dict) else None
        if not isinstance(name, str) or not name:
            raise ContextError(f"{relative}: skills[{index}] has no name")
        names.append(name)
    return names


def current_profile(state_root: str, profiles: Mapping[str, Any]) -> str:
    """The profile of the last rebuild (<state root>/current/profile) when it
    names a profile of the instance, else the check profile (D15)."""
    path = Path(state_root) / CURRENT_PROFILE
    try:
        text = _read_text(path)
    except OSError as error:
        raise ContextError(f"cannot read {path}: {error.strerror}") from error
    recorded = text.strip() if text is not None else ""
    return recorded if recorded in profiles["names"] else profiles["check"]


def _strip_slash(path: str | None) -> str | None:
    if path is None:
        return None
    stripped = path.rstrip("/")
    return stripped or "/"


# --- The document --------------------------------------------------------------------


def build_context(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The context document of instance (SPEC 6.5). Raises DotstewardError
    for an invalid environment or an unreadable source."""
    try:
        return _build_context(instance, os.environ if env is None else env)
    except OSError as error:
        # The readers above name the sources they refuse; this keeps any
        # other unreadable path (an instance directory without permissions)
        # a refusal rather than a traceback.
        where = error.filename if error.filename is not None else "a context source"
        raise ContextError(f"cannot read {where}: {error.strerror}") from error


def _build_context(instance: config.Instance, env: Mapping[str, str]) -> dict[str, Any]:
    c = instance.config
    values = config.runtime_values(instance, env)
    platform_name = values["platform"]
    system = nix_system(platform_name)
    mirror = read_mirror(instance, system)
    buffer_targets, entry_ids = read_buffer(instance)

    # A mirror part of an unexpected shape adds nothing (doctor reports the
    # mirror).
    mirror_components = {
        item["name"]: item
        for item in _field(mirror, "components", list)
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    mirror_targets = _field(mirror, "settings_targets", dict)
    mirror_commands = _field(_field(mirror, "checks", dict), "commands", list)
    home_managed = _names(_field(mirror, "skills", dict).get("home_managed"))

    def targets_of(name: str) -> list[str]:
        return [
            target
            for target, spec in mirror_targets.items()
            if isinstance(spec, dict) and spec.get("component") == name
        ]

    def commands_of(name: str) -> list[str]:
        return _unique(
            [
                item["command"]
                for item in mirror_commands
                if isinstance(item, dict) and item.get("component") == name and isinstance(item.get("command"), str)
            ]
        )

    def method_of(name: str) -> str | None:
        method = config.method_for(c, name, platform_name)
        if method is None:
            recorded = mirror_components.get(name, {}).get("method")
            method = recorded if isinstance(recorded, str) else None
        return method

    components = [
        {
            "name": name,
            "enable": c["components"][name]["enable"],
            "source": c["components"][name]["source"],
            "method": method_of(name),
            "profiles": c["components"][name]["profiles"],
            "settings_targets": targets_of(name),
            "commands": commands_of(name),
        }
        for name in c["components"]["order"]
    ]

    identity = c["identity"]
    check_home = identity["darwin_home"] if platform_name == "darwin" else identity["home"]
    runtime_user = env.get("USER") or None
    runtime_home = _strip_slash(env.get("HOME") or None)
    state_root = values["state_root"]
    update = os.path.join(state_root, UPDATE_DIR)
    profiles = c["profiles"]
    framework = framework_version()
    upstream, track = framework_input(instance)
    # The framework skills are the skills with an overlay key.
    framework_skills = config.schema()["properties"]["skills"]["properties"]["overlays"]["propertyNames"]["enum"]
    instance_skills = _sorted({*read_skills_lock(instance), *home_managed} - set(framework_skills))

    return {
        "schema_version": SCHEMA_VERSION,
        "instance": {
            "path": str(instance.root),
            "name": c["instance"]["name"],
            "remote": c["instance"]["remote"],
            "branch": c["instance"]["branch"],
            "checkout": values["checkout"],
            "upstream_contribute": c["upstream"]["contribute"],
        },
        "identity": {
            "check_username": identity["username"],
            "check_home": check_home,
            "runtime_user": runtime_user,
            "runtime_home": runtime_home,
            "runtime_matches_check": runtime_user == identity["username"]
            and runtime_home is not None
            and runtime_home == _strip_slash(check_home),
        },
        "state": {
            "root": state_root,
            "memo": os.path.join(update, "validation.json"),
            "log": os.path.join(update, "validate.log"),
            "candidate": os.path.join(update, "candidate.json"),
            "validation": os.path.join(update, "validation.json"),
        },
        "profiles": {
            "names": list(profiles["names"]),
            "current": current_profile(state_root, profiles),
            "default": profiles["default"],
            "check": profiles["check"],
            "bootstrap": profiles["bootstrap"],
            "modes": {name: profiles[name]["mode"] for name in profiles["names"]},
        },
        "gate": {**values["gate"], "step_keys": list(GATE_STEP_KEYS)},
        "commit": {
            "update_subject": c["commit"]["update_subject"],
            "settings_subject": c["commit"]["settings_subject"],
            "upgrade_subject": c["commit"]["upgrade_subject"],
            "conventional_types": list(CONVENTIONAL_TYPES),
        },
        "protected": _sorted(c["protected"]),
        "overlays": {skill: values["overlays"].get(skill) for skill in framework_skills},
        "components": components,
        "settings": {
            "buffer_dir": c["settings"]["buffer_dir"],
            "published_ref": c["settings"]["published_ref"],
            "target_names": _sorted({*mirror_targets, *buffer_targets}),
            "entry_ids": entry_ids,
        },
        "skills": {
            "hm_root": c["skills"]["hm_root"],
            "instance_skill_names": instance_skills,
        },
        "framework": {**framework, "upstream": upstream, "track": track},
        "platform": {
            "system": system,
            "name": platform_name,
            "fast_path": c["platform"][platform_name]["fast_path"],
        },
    }


# --- Human output --------------------------------------------------------------------


def _human(value: Any) -> str:
    if value is None:
        return "none"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return ", ".join(_human(item) for item in value) if value else "none"
    if isinstance(value, dict):
        return ", ".join(f"{key}={_human(item)}" for key, item in value.items()) if value else "none"
    return str(value)


def human_lines(document: Mapping[str, Any]) -> list[str]:
    """One "[dotsteward] key: value" line per fact; components are keyed by
    name, lists are comma-separated, null and empty lists are "none"."""
    lines: list[str] = []

    def emit(prefix: str, value: Any) -> None:
        if isinstance(value, dict) and value and prefix not in ("profiles.modes", "platform.fast_path"):
            for key, item in value.items():
                emit(f"{prefix}.{key}", item)
        else:
            lines.append(f"[dotsteward] {prefix}: {_human(value)}")

    for key, value in document.items():
        if key == "components":
            for component in value:
                for field, item in component.items():
                    if field != "name":
                        emit(f"components.{component['name']}.{field}", item)
        else:
            emit(key, value)
    return lines


# --- Command line --------------------------------------------------------------------


USAGE = """\
Usage: dotsteward context [--json]

Prints the facts of the instance on this machine (SPEC 6.5): the instance,
the check and runtime identity, the state record paths, profiles, gate
parameters, commit rules, protected paths, skill overlays, components with
their methods, settings targets and commands, the settings buffer's target
names and entry ids (never values), the instance skills, the framework and
its upstream, and the platform.

  --json      one JSON document (schema/context.schema.json) on stdout;
              without it, one "[dotsteward] key: value" line per fact
  -h, --help  this help

The instance comes from --instance, DOTSTEWARD_INSTANCE or the nearest
workstation.toml above the working directory. Exit 0, or 1 for a usage
error, an invalid configuration or an unreadable source."""


class _Parser(argparse.ArgumentParser):
    """Usage errors exit 1 (the bash convention), not argparse's 2."""

    def error(self, message: str) -> None:  # type: ignore[override]
        config._write(f"[dotsteward] ERROR: {message}", sys.stderr)
        config._write(f"[dotsteward] run 'dotsteward {self.prog} --help' for the usage", sys.stderr)
        sys.exit(1)


def parser(name: str) -> _Parser:
    """A parser with -h/--help as a plain flag (the caller prints its usage
    text) that exits 1 on usage errors and accepts no abbreviations."""
    result = _Parser(prog=name, add_help=False, allow_abbrev=False, usage=argparse.SUPPRESS)
    result.add_argument("-h", "--help", action="store_true")
    return result


def write_errors(error: config.DotstewardError) -> None:
    for line in error.lines():
        config._write(line, sys.stderr)


def main(argv: Sequence[str] | None = None) -> int:
    args_parser = parser("context")
    args_parser.add_argument("--json", action="store_true")
    args = args_parser.parse_args(argv)
    if args.help:
        config._write(USAGE)
        return 0
    try:
        document = build_context(config.load_instance())
    except config.DotstewardError as error:
        write_errors(error)
        return 1
    if args.json:
        config._write(json.dumps(document, indent=2, ensure_ascii=False))
    else:
        config._write("\n".join(human_lines(document)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
