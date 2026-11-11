"""What a run reads from the instance: the manifest mirror and the configuration.

The mirror is the committed ``.dotsteward/manifest.<system>.json``, so nothing here needs Nix. Each
function is cheap and holds no state: a pull or the writer can change the mirror during a run, so
the steps ask again.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from dotsteward_cli import config, machine, platforms

_APT = "apt"
_DEB = "deb"
_SELF = "self"


def mirror(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The manifest mirror of this machine; empty when there is none yet."""
    path = instance.root / ".dotsteward" / f"manifest.{machine.nix_system(instance, env)}.json"
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


def active_components(
    instance: config.Instance, profile: str | None, env: Mapping[str, str] | None = None
) -> list[dict[str, Any]]:
    """The components of the mirror that apply here: profile, platform, not skipped by the machine."""
    platform_name = config.runtime_platform(env)
    skipped = set(machine.effective(instance, env)["skip"]["components"])
    active = []
    for component in mirror(instance, env).get("components") or ():
        profiles = component.get("profiles")
        platforms = component.get("platforms")
        if component.get("name") in skipped or component.get("unavailable"):
            continue
        if profiles is not None and profile not in profiles:
            continue
        if platforms is not None and platform_name not in platforms:
            continue
        active.append(component)
    return active


def _component_settings(instance: config.Instance, name: str) -> Mapping[str, Any]:
    settings = instance.config.get("components", {}).get(name)
    return settings if isinstance(settings, Mapping) else {}


def tracked_packages(active: list[dict[str, Any]], instance: config.Instance) -> list[str]:
    """The set T of the apt plan: what the enabled deb components install and what they follow, unless
    another updater is named for them."""
    names: set[str] = set()
    for component in active:
        settings = _component_settings(instance, component["name"])
        if component.get("method") != _DEB or settings.get("updater") not in (None, _APT):
            continue
        install = component.get("install") or {}
        names.update(install.get("packageNames") or ())
        names.update(install.get("apt") or ())
        names.update(settings.get("track") or ())
    return sorted(names)


def tools(instance: config.Instance) -> list[dict[str, Any]]:
    """``[[upgrade.tools]]``: the updaters of this instance, in their order."""
    return list(instance.config["upgrade"]["tools"])


def _constraint(instance: config.Instance, name: str, env: Mapping[str, str] | None) -> dict[str, str] | None:
    """The version constraint of NAME on this machine: its platform layer before workstation.toml."""
    shared = instance.config.get("components") or {}
    return platforms.constraint(instance.root, shared, name, platforms.platform_id(env))


def _packages(component: Mapping[str, Any], instance: config.Instance) -> list[str]:
    install = component.get("install") or {}
    settings = _component_settings(instance, component["name"])
    names = [*(install.get("packageNames") or ()), *(install.get("apt") or ()), *(settings.get("track") or ())]
    return sorted(set(map(str, names)))


def constraints(
    active: list[dict[str, Any]], instance: config.Instance, env: Mapping[str, str] | None = None
) -> dict[str, str]:
    """A constrained deb component and its version: ``{"sampledbms": "16.*"}``."""
    found: dict[str, str] = {}
    for component in active:
        rule = _constraint(instance, component["name"], env) if component.get("method") == _DEB else None
        if rule is not None:
            found[component["name"]] = rule["version"]
    return found


def kept(
    active: list[dict[str, Any]],
    instance: config.Instance,
    env: Mapping[str, str] | None,
    component_holds: Mapping[str, Mapping[str, str]],
) -> list[dict[str, Any]]:
    """What binds apt on this machine, for the records of the apt engine: the version constraint of
    each active deb component, and the hold the host file of this machine has for it, each with the
    packages of the component."""
    rules: list[dict[str, Any]] = []
    for component in active:
        if component.get("method") != _DEB:
            continue
        name = component["name"]
        packages = _packages(component, instance)
        rule = _constraint(instance, name, env)
        if rule is not None and packages:
            rules.append(
                {
                    "component": name,
                    "kind": "constraint",
                    "version": rule["version"],
                    "reason": rule["reason"],
                    "packages": packages,
                }
            )
        hold = component_holds.get(name)
        if hold is not None and packages:
            rules.append(
                {
                    "component": name,
                    "kind": "hold",
                    "version": hold["version"],
                    "reason": hold["reason"],
                    "packages": packages,
                }
            )
    return rules


def gated(instance: config.Instance, name: str | None) -> bool:
    """False only for ``[apt.gated] enable = false`` of this machine."""
    host = (machine.read_host(instance.root, name) if name else None) or {}
    return host.get("apt", {}).get("gated", {}).get("enable", True) is not False


def tracked_commands(document: Mapping[str, Any], active: list[dict[str, Any]]) -> set[str]:
    """The commands of core and the active components: a declared tool never moves them."""
    names = {component["name"] for component in active} | {"core"}
    commands = (document.get("checks") or {}).get("commands") or ()
    return {entry["command"] for entry in commands if entry.get("component") in names}


def pin_owners(active: list[dict[str, Any]]) -> dict[str, str]:
    """Which component a pin of an official binary or of its companions belongs to."""
    owners: dict[str, str] = {}
    for component in active:
        install = component.get("install") or {}
        pins = [install.get("pin"), *(companion.get("pin") for companion in install.get("companions") or ())]
        for pin in pins:
            if isinstance(pin, str):
                owners[pin] = component["name"]
    return owners


@dataclass(frozen=True)
class SelfUpdate:
    """A component whose own updater `upgrade` may start."""

    component: str
    command: tuple[str, ...]
    version: tuple[str, ...]


def self_updates(active: list[dict[str, Any]], instance: config.Instance) -> list[SelfUpdate]:
    """The components that declare their update command and leave updating to it: ``updater = "self"``,
    or no updater where no package manager owns the files. The policy keeps native updaters: its
    native_application_updates is true by rule (`dotsteward static` refuses false)."""
    found = []
    for component in active:
        declared = component.get("self_update")
        if not isinstance(declared, Mapping) or not declared.get("command"):
            continue
        updater = _component_settings(instance, component["name"]).get("updater")
        if updater == _SELF or (updater is None and component.get("method") != _DEB):
            found.append(
                SelfUpdate(component["name"], tuple(declared["command"]), tuple(declared.get("version") or ()))
            )
    return found


def role(instance: config.Instance, name: str | None) -> str:
    """Who moves the pins from this machine's point of view: ``this-machine``, the name of another
    machine, ``nobody`` with several machines and no producer, ``unnamed`` when this machine has no
    name yet: a fresh machine must not move the lock of the others."""
    if name is None:
        return "unnamed"
    producer = instance.config.get("hosts", {}).get("producer")
    if producer:
        return "this-machine" if producer == name else str(producer)
    known = machine.known_names(instance.root)
    if len(known) <= 1:
        return "this-machine"
    return "nobody"
