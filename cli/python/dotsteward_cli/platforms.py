"""The platform layer: ``platforms/<platform>.toml`` of an instance says what differs on one
platform ([schema](../../../schema/platform.schema.json)).

A machine runs one release, ``ubuntu-22.04`` or ``macos-15``, the string ``hosts/<name>.toml``
records as ``platform``. Its layers, the most specific first, are the release, the operating
system (``ubuntu``, ``macos``) and the Nix platform (``linux``, ``darwin``); ``workstation.toml``
is below them all. A key of a more specific layer wins over the same key of a more general one,
and lists do not merge.

The CLI resolves the layer, here and nowhere else, and Nix never reads it, apart from the fast
path of a release, which the stage-0 mirror carries for the bootstrap before Nix. A component a
layer calls unavailable is left out on the machine like one for other machines:
``machine.effective`` gives it the reason ``platform`` and Nix a ``no:`` tag.

    platform_id(env)                   the release of this machine
    layers(platform, runtime)          its layers, the most specific first
    resolve(instance, env)             {id, layers, files, fast_path, components}
    check_problems(instance)           the problems of every platform file of the tree
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from dotsteward_cli import config, tomlfile

PLATFORMS_DIR = "platforms"
_NAME = re.compile(r"[a-z0-9][a-z0-9.-]*", re.ASCII)
_DARWIN_NAMES = ("darwin", "macos")


def _os_release(env: Mapping[str, str]) -> dict[str, str]:
    path = env.get("DOTSTEWARD_OS_RELEASE") or "/etc/os-release"
    values: dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return values
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip().strip("\"'")
    return values


def platform_id(env: Mapping[str, str] | None = None) -> str:
    """The operating system and its release: ubuntu-24.04, macos-15."""
    env = os.environ if env is None else env
    if config.runtime_platform(env) == "darwin":
        command = env.get("DOTSTEWARD_SW_VERS") or "sw_vers"
        try:
            version = subprocess.run(
                [command, "-productVersion"], capture_output=True, text=True, timeout=30, check=False
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            version = ""
        text = f"macos-{version.split('.')[0]}" if version else "macos"
    else:
        release = _os_release(env)
        text = "-".join(part for part in (release.get("ID"), release.get("VERSION_ID")) if part) or "linux"
    return re.sub(r"[^a-z0-9.-]+", "-", text.lower()).strip("-.") or "unknown"


def layers(platform: str, runtime: str) -> list[str]:
    """The layers of PLATFORM on the Nix platform RUNTIME, the most specific first:
    ubuntu-22.04, ubuntu, linux."""
    found = [platform]
    system, separator, release = platform.rpartition("-")
    if separator and system and release[:1].isdigit():
        found.append(system)
    if runtime not in found:
        found.append(runtime)
    return found


def valid_name(name: str) -> bool:
    return _NAME.fullmatch(name) is not None


def is_darwin(name: str) -> bool:
    return name.split("-", 1)[0] in _DARWIN_NAMES


def platform_schema(root: Path = config.FRAMEWORK_ROOT) -> dict[str, Any]:
    with open(root / "schema" / "platform.schema.json", encoding="utf-8") as handle:
        document: dict[str, Any] = json.load(handle)
    return document


def _label(name: str) -> str:
    return f"{PLATFORMS_DIR}/{name}.toml"


def read_platform(root: str | os.PathLike[str], name: str) -> dict[str, Any] | None:
    """The checked document of platforms/NAME.toml, None when the file does not exist."""
    path = Path(root) / PLATFORMS_DIR / f"{name}.toml"
    label = _label(name)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as error:
        raise config.DotstewardError(f"cannot read {path}: {error.strerror}") from error
    try:
        document = tomlfile.loads(text)
    except tomlfile.TomlError as error:
        raise config.DotstewardError(f"{label}: invalid TOML: {error}") from error
    problems = config.schema_errors(platform_schema(), document)
    if problems:
        hint = config.newer_tree_hint(Path(root), problems)
        raise config.DotstewardError(*(f"{label}: {problem}" for problem in problems), *([hint] if hint else []))
    return document


def resolve(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """What the platform layer says on this machine: ``{id, layers, files, fast_path,
    components: {name: {unavailable, layer}}}``, each value from the most specific layer
    that has it."""
    env = os.environ if env is None else env
    current = platform_id(env)
    chain = layers(current, config.runtime_platform(env))
    files: list[str] = []
    fast_path: dict[str, Any] | None = None
    components: dict[str, dict[str, str]] = {}
    for layer in chain:
        document = read_platform(instance.root, layer)
        if document is None:
            continue
        files.append(_label(layer))
        if fast_path is None and "fast_path" in document:
            fast_path = dict(document["fast_path"])
        for name, table in document.get("components", {}).items():
            entry = components.setdefault(name, {})
            for key, value in table.items():
                if key not in entry:
                    entry[key] = value
                    entry.setdefault("layer", layer)
    return {
        "id": current,
        "layers": chain,
        "files": files,
        "fast_path": fast_path,
        "components": {name: components[name] for name in sorted(components)},
    }


def unavailable(document: Mapping[str, Any]) -> list[str]:
    """The components a resolved layer calls unavailable, sorted."""
    return sorted(name for name, entry in document["components"].items() if entry.get("unavailable"))


def file_names(root: str | os.PathLike[str]) -> list[str]:
    try:
        return sorted(os.listdir(Path(root) / PLATFORMS_DIR))
    except (FileNotFoundError, NotADirectoryError):
        return []


def check_problems(instance: config.Instance) -> list[str]:
    """Every platform file is named like a platform and valid, and a fast path names the
    Linux release of its file."""
    problems: list[str] = []
    for file_name in file_names(instance.root):
        name = file_name.removesuffix(".toml")
        label = f"{PLATFORMS_DIR}/{file_name}"
        if not file_name.endswith(".toml") or not valid_name(name):
            problems.append(f"{label}: expected {PLATFORMS_DIR}/<platform>.toml, matching ^[a-z0-9][a-z0-9.-]*$")
            continue
        try:
            document = read_platform(instance.root, name) or {}
        except config.DotstewardError as error:
            problems += error.messages
            continue
        fast_path = document.get("fast_path")
        if fast_path is None:
            continue
        if is_darwin(name):
            problems.append(f"{label}: a fast path is for a Linux release; macOS has [platform.darwin.fast_path]")
            continue
        named = f"{fast_path['os_id']}-{fast_path['os_version']}"
        if named != name:
            problems.append(f"{label}: the fast path names {named}, the file another platform")
    return problems
