"""Built-in rows of ``pins latest``, derived from the lock files (no
component declares them):

    flake_inputs.<name>        every flake input of the versions lock
                               (except [pins] excluded_flake_inputs) with a
                               ``channel`` (channel-head) or a ``version``
                               (github-release from its reference)
    nix.installer              the lock's ``nix`` section (nix-release over
                               the stable tags of NixOS/nix and the
                               installer URL of the lock)
    skills.<name>              every skills lock entry with a 40-digit
                               revision (skill-source); other revisions
                               except the repo-owned sentinels are manual
    nix_packages.<name>        packages whose expected version is the
                               locked nixpkgs package (follows, --all)
    framework                  the dotsteward input (adapters/framework.py)

A component's declaration with the same row id replaces a built-in row.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from ..checker import HEX40
from ..instance import Instance
from ..lockfile import SKILLS, VERSIONS, LockPath, Locks, Step
from ..rules.nix_package_format import LOCKED_NIXPKGS
from .adapters import PlanContext, Planned, Request, make
from .adapters import framework as framework_adapter
from .adapters.skill_source import SkillSource, vendored_filter
from .model import error_item, item
from .upstream import github_repo

NIX_REPOSITORY = "NixOS/nix"
SNAPSHOT_NOTE = "local snapshot; compare with the upstream source manually"
NIXPKGS_NOTE = "run 'dotsteward sync --nix' after a nixpkgs update"


def _path(*keys: str) -> str:
    return LockPath(VERSIONS, tuple(Step(key) for key in keys)).text()


def _literal(text: str) -> str:
    """A lock template that renders to exactly ``text``."""
    return text.replace("{", "{{").replace("}", "}}")


def _section(locks: Locks, kind: str, key: str) -> Mapping[str, Any]:
    document = locks.documents.get(kind)
    section = document.get(key) if isinstance(document, dict) else None
    return section if isinstance(section, dict) else {}


def _declared(ctx: PlanContext, declaration: dict[str, Any]) -> list[Planned]:
    return make("core", declaration).plan(ctx)


def flake_inputs(ctx: PlanContext) -> list[Planned]:
    planned = []
    excluded = set(ctx.instance.excluded_flake_inputs)
    for name, pin in _section(ctx.locks, VERSIONS, "flake_inputs").items():
        if name in excluded or not isinstance(pin, dict):
            continue
        if "channel" in pin:
            adapter = "channel-head"
        elif "version" in pin:
            adapter = "github-release"
        else:
            continue
        at = _path("flake_inputs", name)
        planned += _declared(ctx, {"id": _literal(f"flake_inputs.{name}"), "adapter": adapter, "at": at})
    return planned


def nix_installer(ctx: PlanContext) -> list[Planned]:
    pin = _section(ctx.locks, VERSIONS, "nix")
    if "installer_url" not in pin:
        return []
    declaration = {"id": "nix.installer", "adapter": "nix-release", "at": "nix", "repo": NIX_REPOSITORY}
    return _declared(ctx, declaration)


def nixpkgs_followers(ctx: PlanContext) -> list[Planned]:
    planned = []
    for name, pin in _section(ctx.locks, VERSIONS, "nix_packages").items():
        if isinstance(pin, dict) and pin.get("expected") == LOCKED_NIXPKGS:
            declaration = {
                "id": _literal(f"nix_packages.{name}"),
                "adapter": "follows",
                "at": _path("nix_packages", name),
                "current": "{.resolved}",
                "follows": "nixpkgs",
                "note": _literal(NIXPKGS_NOTE),
            }
            planned += _declared(ctx, declaration)
    return planned


def skills(ctx: PlanContext) -> list[Planned]:
    document = ctx.locks.documents.get(SKILLS)
    if not isinstance(document, dict):
        return []
    entries = document.get("skills")
    if not isinstance(entries, list):
        return [_error("skills", "the skills lock has no skills list")]
    instance = ctx.instance
    vendor = instance.path(instance.vendor_dir)
    planned = []
    for index, skill in enumerate(entries, start=1):
        name = skill.get("name") if isinstance(skill, dict) else None
        if not isinstance(name, str) or not name:
            planned.append(_error(f"skills.{index}", f"skills lock entry {index} has no name"))
            continue
        identifier = f"skills.{name}"
        revision = skill.get("revision", "")
        if revision in instance.repo_owned_revisions:
            continue
        source = skill.get("source", "")
        if not isinstance(revision, str) or not HEX40.fullmatch(revision):
            row = item(identifier, "manual", revision, None, "manual", source, note=SNAPSHOT_NOTE)
            planned.append(Planned(identifier, "core", False, None, row))
            continue
        repo = github_repo(source)
        directory = skill.get("directory", name)
        if repo is None or not isinstance(directory, str):
            planned.append(_error(identifier, f"the source {source!r} of skill {name} is not a GitHub repository"))
            continue
        adapter = SkillSource("core", {"id": _literal(identifier), "adapter": SkillSource.name})
        request = Request(
            identifier,
            adapter,
            current=revision[:12],
            values={
                "repo": repo,
                "revision": revision,
                "release_bound": bool(skill.get("release_bound")),
                "matches": vendored_filter(str(skill.get("source_path", "")), vendor / directory),
            },
        )
        planned.append(Planned(identifier, "core", False, request, None))
    return planned


def _error(identifier: str, message: str) -> Planned:
    return Planned(identifier, "core", False, None, error_item(identifier, SkillSource.name, message))


def rows(instance: Instance, locks: Locks) -> list[Planned]:
    """Every built-in row, in job order."""
    ctx = PlanContext(instance, locks)
    return [
        *flake_inputs(ctx),
        *nix_installer(ctx),
        *skills(ctx),
        *nixpkgs_followers(ctx),
        framework_adapter.plan(instance),
    ]
