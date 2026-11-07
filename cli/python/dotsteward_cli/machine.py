"""The name of this machine and what applies to it.

Two files describe a machine. ``<state>/machine.json`` stays on the machine and
holds its name, which ``dotsteward host init`` writes (``DOTSTEWARD_MACHINE``
replaces it in tests). ``hosts/<name>.toml`` of the instance is what the other
machines may know about it: the file name is the machine name, only that machine
writes the file, and ``dotsteward host publish`` brings it to the remote. A machine
without ``machine.json`` has no name, which is how every instance starts: nothing
changes for it unless the instance scopes something to named machines.

``effective`` is the one answer to "what applies here": which components, skills
and plugins this machine leaves out, and why. Nothing stores the answer; every
command computes it when it starts, and ``config_load`` hands it to bash as
``DS_MACHINE_NAME`` and ``DS_SKIP_{COMPONENTS,SKILLS,PLUGINS}_JSON``. An instance
reads it with ``dotsteward skills effective --json``. A later release adds more
reasons to leave something out; the commands read only the result.

Python API: ``effective``, ``name_taken``, ``current_name``, ``read_machine``,
``write_machine``, ``recorded_profile``, ``nix_system``, ``known_names``, ``read_host``,
``parse_host``, ``host_path``, ``scoped_entries``, ``check_problems`` and ``valid_name``.

Command line (``cli/commands/skills.sh``)::

    python3 -m dotsteward_cli.machine effective [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import sys
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, tomlfile

MACHINE_ENV = "DOTSTEWARD_MACHINE"
MACHINE_FILE = "machine.json"
HOSTS_DIR = "hosts"
CURRENT_PROFILE = "current/profile"

_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}", re.ASCII)
_ARCHITECTURES = {"amd64": "x86_64", "arm64": "aarch64"}

# What a lock entry or a plugin entry says about the machines it is for.
REASON_MACHINES = "machines"
REASON_DECLINED = "declined"


def valid_name(name: str) -> bool:
    """Whether NAME can name a machine: ^[a-z0-9][a-z0-9-]{0,31}$."""
    return _NAME.fullmatch(name) is not None


# --- machine.json --------------------------------------------------------------------


def machine_path(state_root: str | os.PathLike[str]) -> Path:
    return Path(state_root) / MACHINE_FILE


def read_machine(state_root: str | os.PathLike[str]) -> dict[str, Any] | None:
    """The record of this machine, None when it has no name yet."""
    path = machine_path(state_root)
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise config.DotstewardError(f"cannot read {path}: {error}; 'dotsteward host init' writes it again") from error
    name = record.get("name") if isinstance(record, dict) else None
    if not isinstance(name, str) or not valid_name(name):
        raise config.DotstewardError(f"invalid machine name in {path}; 'dotsteward host init' writes it again")
    return dict(record)


def write_machine(state_root: str | os.PathLike[str], record: Mapping[str, Any]) -> None:
    atomic.make_private_dirs(state_root)
    atomic.atomic_write_json(machine_path(state_root), record, mode=0o600)


def current_name(record: Mapping[str, Any] | None, env: Mapping[str, str] | None = None) -> str | None:
    """The name of this machine: DOTSTEWARD_MACHINE, else machine.json, else None."""
    env = os.environ if env is None else env
    value = env.get(MACHINE_ENV) or None
    if value is not None:
        if not valid_name(value):
            raise config.DotstewardError(f"{MACHINE_ENV}: invalid machine name {value!r}")
        return value
    return None if record is None else str(record["name"])


# --- hosts/<name>.toml ------------------------------------------------------------------


def host_path(root: str | os.PathLike[str], name: str) -> Path:
    return Path(root) / HOSTS_DIR / f"{name}.toml"


def known_names(root: str | os.PathLike[str]) -> list[str]:
    """The machine names registered in the tree at ROOT, sorted."""
    try:
        entries = os.listdir(Path(root) / HOSTS_DIR)
    except (FileNotFoundError, NotADirectoryError):
        return []
    names = (entry.removesuffix(".toml") for entry in entries if entry.endswith(".toml"))
    return sorted(name for name in names if valid_name(name))


def host_schema(root: Path = config.FRAMEWORK_ROOT) -> dict[str, Any]:
    """The parsed schema/host.schema.json of the framework."""
    with open(root / "schema" / "host.schema.json", encoding="utf-8") as handle:
        document: dict[str, Any] = json.load(handle)
    return document


def parse_host(text: str, label: str, instance_root: Path) -> dict[str, Any]:
    """The checked document of a host file with the text TEXT."""
    try:
        document = tomlfile.loads(text)
    except tomlfile.TomlError as error:
        raise config.DotstewardError(f"{label}: invalid TOML: {error}") from error
    problems = config.schema_errors(host_schema(), document)
    if problems:
        messages = [f"{label}: {problem}" for problem in problems]
        hint = config.newer_tree_hint(instance_root, problems)
        raise config.DotstewardError(*messages, *([hint] if hint else []))
    return document


def read_host(root: str | os.PathLike[str], name: str) -> dict[str, Any] | None:
    """The checked document of hosts/NAME.toml, None when the file does not exist."""
    path = host_path(root, name)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as error:
        raise config.DotstewardError(f"cannot read {path}: {error.strerror}") from error
    return parse_host(text, f"{HOSTS_DIR}/{name}.toml", Path(root))


# --- What the instance scopes -----------------------------------------------------------


def _read_lock(instance: config.Instance) -> dict[str, Any]:
    """The skills lock, or nothing when it is missing or not an object: the commands
    that need it report that themselves, as they always did."""
    try:
        document = json.loads((instance.root / instance.config["skills"]["lock"]).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


def _entries(document: Mapping[str, Any], key: str) -> list[dict[str, Any]]:
    entries = document.get(key)
    return [entry for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else []


def _plugin_entries(instance: config.Instance) -> Iterator[dict[str, Any]]:
    """Every [[components.<component>.options.plugins]] table."""
    for table in instance.config["components"].values():
        options = table.get("options") if isinstance(table, dict) else None
        plugins = options.get("plugins") if isinstance(options, dict) else None
        if isinstance(plugins, list):
            yield from (plugin for plugin in plugins if isinstance(plugin, dict))


def scoped_entries(instance: config.Instance) -> Iterator[dict[str, Any]]:
    """Every entry that can name machines: the skills and own plugins of the lock and
    the plugin tables of the components."""
    lock = _read_lock(instance)
    yield from _entries(lock, "skills")
    yield from _entries(lock, "own_plugins")
    yield from _plugin_entries(instance)


def _for_this_machine(entry: Mapping[str, Any], name: str | None) -> bool:
    """An entry without machines is for every machine; an entry with machines is
    for the machines it names, so never for a machine without a name."""
    machines = entry.get("machines")
    return machines is None or (isinstance(machines, list) and name in machines)


# --- The effective scope ----------------------------------------------------------------


def recorded_profile(state_root: str, instance: config.Instance) -> str | None:
    """The profile of the last rebuild, when it still is a profile of the instance."""
    try:
        recorded = (Path(state_root) / CURRENT_PROFILE).read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return recorded if recorded in instance.config["profiles"]["names"] else None


def effective(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """What applies to this machine: ``{name, profile, tags, skip: {components, skills,
    plugins}, reasons}``. ``skip`` holds sorted names, ``reasons`` one word for each,
    under ``skill:<name>`` and ``plugin:<name>``. A plugin goes by its spec. The profile
    never falls back to a default of the instance. The components stay empty until the
    instance can scope them."""
    state = config.state_root(instance, env)
    record = read_machine(state)
    name = current_name(record, env)
    host = (read_host(instance.root, name) if name is not None else None) or {}
    recorded: dict[str, Any] = {}
    if record is not None and record.get("name") == name and isinstance(record.get("host"), dict):
        recorded = record["host"]
    declined = host.get("declined", {})

    reasons: dict[str, str] = {}
    lock = _read_lock(instance)
    for entry in _entries(lock, "skills"):
        skill = entry.get("name")
        if isinstance(skill, str):
            if not _for_this_machine(entry, name):
                reasons[f"skill:{skill}"] = REASON_MACHINES
            elif skill in declined.get("skills", []):
                reasons[f"skill:{skill}"] = REASON_DECLINED
    plugins = {str(p["name"]): p for p in _entries(lock, "own_plugins") if isinstance(p.get("name"), str)}
    plugins.update({str(p["spec"]): p for p in _plugin_entries(instance) if isinstance(p.get("spec"), str)})
    for plugin, entry in plugins.items():
        if not _for_this_machine(entry, name):
            reasons[f"plugin:{plugin}"] = REASON_MACHINES
        elif plugin in declined.get("plugins", []):
            reasons[f"plugin:{plugin}"] = REASON_DECLINED

    profile = host.get("profile") or recorded.get("profile") or recorded_profile(state, instance)
    return {
        "name": name,
        "profile": profile,
        "tags": list(host.get("tags", recorded.get("tags") or [])),
        "skip": {
            "components": [],
            "skills": sorted(key.removeprefix("skill:") for key in reasons if key.startswith("skill:")),
            "plugins": sorted(key.removeprefix("plugin:") for key in reasons if key.startswith("plugin:")),
        },
        "reasons": dict(sorted(reasons.items())),
    }


def nix_system(instance: config.Instance, env: Mapping[str, str] | None = None) -> str:
    """The Nix system of this machine: the entry of nix.systems for its platform, as the
    commands choose it, else the running machine's."""
    platform_name = config.runtime_platform(env)
    for system in instance.config["nix"]["systems"]:
        if system.endswith(f"-{platform_name}"):
            return str(system)
    architecture = platform.machine().lower()
    return f"{_ARCHITECTURES.get(architecture, architecture)}-{platform_name}"


def _skill_roots(instance: config.Instance, env: Mapping[str, str]) -> list[Path]:
    """The directories that hold the user's skills on this machine: the canonical
    root and the roots the manifest mirror names."""
    mirror = instance.root / ".dotsteward" / f"manifest.{nix_system(instance, env)}.json"
    try:
        layout = json.loads(mirror.read_text(encoding="utf-8")).get("skill_layout") or {}
    except (OSError, ValueError, AttributeError):
        layout = {}
    named: list[Any] = ["~/.agents/skills"]
    if isinstance(layout, dict):
        named += layout.get("legacy_roots") or []
        named += list(layout.get("link_roots") or {})
        named += list((layout.get("agent_roots") or {}).values())
    roots: list[Path] = []
    for item in named:
        root = Path(config.expand_path(str(item), env))
        if root not in roots:
            roots.append(root)
    return roots


def name_taken(instance: config.Instance, scope: Mapping[str, Any], env: Mapping[str, str] | None = None) -> list[str]:
    """The skills of the lock that are for other machines and whose name this machine
    uses for a skill of its own: they would otherwise stay untracked without a word."""
    roots = _skill_roots(instance, os.environ if env is None else env)
    taken: list[str] = []
    for entry in _entries(_read_lock(instance), "skills"):
        skill, directory = entry.get("name"), entry.get("directory")
        if scope["reasons"].get(f"skill:{skill}") != REASON_MACHINES or not isinstance(directory, str):
            continue
        if any((root / directory / "SKILL.md").exists() for root in roots):
            taken.append(str(skill))
    return sorted(taken)


# --- The checks of the tree ---------------------------------------------------------------


def _machines_problems(label: str, machines: Any, names: Sequence[str]) -> list[str]:
    if machines is None:
        return []
    if not isinstance(machines, list) or not machines or not all(isinstance(item, str) for item in machines):
        return [f"{label}: machines must be a non-empty list of machine names"]
    problems = [
        f"{label}: machines names {item}, which has no {HOSTS_DIR}/{item}.toml"
        for item in machines
        if item not in names
    ]
    if len(set(machines)) != len(machines):
        problems.append(f"{label}: machines lists a machine more than once")
    return problems


def check_problems(instance: config.Instance) -> list[str]:
    """The problems of the tree: every host file is valid and named like a machine, and
    every machines key lists known machines. An empty list without a hosts directory
    and without a machines key, so a tree that names no machine passes."""
    root = instance.root
    names = known_names(root)
    problems: list[str] = []
    try:
        entries = sorted(os.listdir(root / HOSTS_DIR))
    except (FileNotFoundError, NotADirectoryError):
        entries = []
    for file_name in entries:
        stem = file_name.removesuffix(".toml")
        label = f"{HOSTS_DIR}/{file_name}"
        if not file_name.endswith(".toml") or not valid_name(stem):
            problems.append(f"{label}: expected {HOSTS_DIR}/<name>.toml, a name matches ^[a-z0-9][a-z0-9-]{{0,31}}$")
            continue
        try:
            host = read_host(root, stem) or {}
        except config.DotstewardError as error:
            problems += error.messages
            continue
        if "system" in host and host["system"] not in instance.config["nix"]["systems"]:
            problems.append(f"{label}: system {host['system']} is not in nix.systems")
        if "profile" in host and host["profile"] not in instance.config["profiles"]["names"]:
            problems.append(f"{label}: profile {host['profile']} is not in profiles.names")
        for entry in _entries(_read_lock(instance), "skills"):
            if (
                entry.get("name") in host.get("declined", {}).get("skills", [])
                and entry.get("deployment") == "home-manager"
            ):
                problems.append(
                    f"{label}: declined skill {entry['name']} has the home-manager deployment, on every machine"
                )
    lock = _read_lock(instance)
    lock_name = instance.config["skills"]["lock"]
    for entry in _entries(lock, "skills"):
        label = f"{lock_name}: skill {entry.get('name')}"
        problems += _machines_problems(label, entry.get("machines"), names)
        if entry.get("machines") is not None and entry.get("deployment", "copy") != "copy":
            problems.append(f"{label}: machines needs the copy deployment")
    for entry in _entries(lock, "own_plugins"):
        problems += _machines_problems(f"{lock_name}: plugin {entry.get('name')}", entry.get("machines"), names)
    answers: dict[Any, Any] = {}
    for plugin in _plugin_entries(instance):
        label = f"{config.CONFIG_FILE}: plugin {plugin.get('spec')}"
        problems += _machines_problems(label, plugin.get("machines"), names)
        # What a machine leaves out goes by the spec, so a spec has one answer.
        if answers.setdefault(plugin.get("spec"), plugin.get("machines")) != plugin.get("machines"):
            problems.append(f"{label}: the components list it for different machines")
    return problems


# --- Command line ---------------------------------------------------------------------


def _human(document: Mapping[str, Any]) -> list[str]:
    name = document["name"] or "(no name yet)"
    lines = [f"machine: {name}", f"profile: {document['profile'] or '(none)'}"]
    lines.append(f"tags: {', '.join(document['tags']) or '(none)'}")
    for kind, prefix in (("skills", "skill"), ("plugins", "plugin"), ("components", "component")):
        items = [f"{item} ({document['reasons'][f'{prefix}:{item}']})" for item in document["skip"][kind]]
        lines.append(f"{kind} left out: {', '.join(items) or '(none)'}")
    if document["name_taken"]:
        lines.append(f"name taken: {', '.join(document['name_taken'])} (the lock keeps these names for other machines)")
    return lines


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward skills",
        description="What the instance's skills, plugins and components mean for this machine.",
        epilog="Exit status: 0 done, 1 refusal, 2 usage error.",
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="subcommand", required=True, metavar="SUBCOMMAND")
    report = commands.add_parser(
        "effective",
        help="what this machine leaves out, and why",
        description=(
            "Prints the machine name, its profile and tags, and what it leaves out: skip.components, "
            "skip.skills and skip.plugins, with one word for each in reasons (machines: the entry is for "
            "other machines; declined: hosts/<name>.toml says never). name_taken lists the skills of the "
            "lock that are for other machines while this machine has a skill of that name."
        ),
        allow_abbrev=False,
    )
    report.add_argument("--json", action="store_true", help="print one JSON document")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        instance = config.load_instance()
        document = effective(instance)
        document["name_taken"] = name_taken(instance, document)
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(document, indent=2, ensure_ascii=False))
    else:
        print("\n".join(_human(document)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
