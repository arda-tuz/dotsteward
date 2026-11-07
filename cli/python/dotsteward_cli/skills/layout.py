"""Where the skills of a machine live, from the manifest of the instance.

The same roots as ``skills_init`` of ``cli/lib/skills.sh``: the canonical root
``~/.agents/skills``, the legacy roots, the link roots, the agent roots and the store
of scoped skills. A reader of a skill looks in that order.
"""

from __future__ import annotations

import json
import os
import platform
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from dotsteward_cli import config


@dataclass(frozen=True)
class Layout:
    canonical: str
    legacy_roots: tuple[str, ...]
    link_roots: tuple[str, ...]
    agent_roots: Mapping[str, str]
    scoped_store: str
    hm_root: str
    excluded: tuple[str, ...]

    @property
    def search_roots(self) -> tuple[str, ...]:
        """The roots that hold a copy, as ``skills_find_existing`` reads them."""
        roots = [self.canonical, *self.legacy_roots]
        if self.hm_root not in roots:
            roots.append(self.hm_root)
        return tuple(roots)


def _expand(path: str, home: str) -> str:
    return (os.path.join(home, path[2:]) if path.startswith("~/") else path).rstrip("/")


def _system(loaded: config.Instance) -> str:
    kernel = "darwin" if platform.system() == "Darwin" else "linux"
    systems = [str(item) for item in loaded.config["nix"]["systems"]]
    return next((item for item in systems if item.endswith("-" + kernel)), systems[0])


def manifest(loaded: config.Instance) -> dict[str, Any]:
    """The manifest mirror of this system, empty when it is missing or broken."""
    path = loaded.root / ".dotsteward" / f"manifest.{_system(loaded)}.json"
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


def component_names(loaded: config.Instance) -> set[str]:
    """The components the manifest enables."""
    components = manifest(loaded).get("components")
    listed = components if isinstance(components, list) else []
    return {str(item["name"]) for item in listed if isinstance(item, dict) and isinstance(item.get("name"), str)}


def read(loaded: config.Instance) -> Layout:
    home = os.environ.get("HOME") or os.path.expanduser("~")
    document = manifest(loaded)
    skill_layout = document.get("skill_layout") or {}
    canonical = os.path.join(home, ".agents", "skills")
    legacy = [_expand(str(root), home) for root in skill_layout.get("legacy_roots") or []]
    hm_root = str((document.get("skills") or {}).get("hm_root") or loaded.config["skills"]["hm_root"]).rstrip("/")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    return Layout(
        canonical=canonical,
        legacy_roots=tuple(root for root in legacy if root != canonical),
        link_roots=tuple(_expand(str(root), home) for root in skill_layout.get("link_roots") or {}),
        agent_roots={
            str(key): _expand(str(value), home) for key, value in (skill_layout.get("agent_roots") or {}).items()
        },
        scoped_store=os.path.join(data_home.rstrip("/"), "dotsteward", "scoped-skills"),
        hm_root=os.path.join(home, hm_root),
        excluded=tuple(str(item).rstrip("/") for item in skill_layout.get("excluded_subtrees") or []),
    )


def find_copy(layout: Layout, entry: Mapping[str, Any]) -> str | None:
    """The local copy of a lock ENTRY: the path a reader finds, None without one."""
    directory = str(entry.get("directory") or entry.get("name"))
    name = str(entry.get("name"))
    if entry.get("agents"):
        path = os.path.join(layout.scoped_store, directory)
        return path if os.path.isfile(os.path.join(path, "SKILL.md")) else None
    candidates = [directory, str(entry.get("legacy_directory") or "")]
    for root in layout.search_roots:
        for candidate in candidates:
            if candidate and os.path.isfile(os.path.join(root, candidate, "SKILL.md")):
                return os.path.join(root, candidate)
    for root in layout.link_roots:
        for candidate in (name, directory):
            path = os.path.join(root, candidate)
            if not os.path.islink(path) and os.path.isfile(os.path.join(path, "SKILL.md")):
                return path
    return None
