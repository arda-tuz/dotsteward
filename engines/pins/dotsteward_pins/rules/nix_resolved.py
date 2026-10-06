"""``nix-resolved`` (core): ``nix_packages.<name>.resolved`` against the
versions Nix evaluates. Active only with ``--nix``: it runs ``nix eval
--json --no-update-lock-file <instance>#<attr>`` (untracked files are
refused first).

Fields:

    attr    flake attribute of the instance (default "lib.pinnedVersions")
    name, formats   (see rules/__init__.py)

Check: the evaluated keys equal the keys of ``nix_packages``; each
evaluated version equals the lock's ``resolved``. Sync: writes the
evaluated versions to the ``resolved`` of entries that exist (never
creates one).
"""

from __future__ import annotations

from typing import ClassVar

from ..checker import Checker
from ..lockfile import Scope, parse_path
from . import Context, FieldSpec, Rule, string

_PACKAGES = parse_path("nix_packages")


class NixResolved(Rule):
    kind = "nix-resolved"
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {"attr": FieldSpec(string, default="lib.pinnedVersions")}

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        if not ctx.nix:
            return
        attribute = self.values["attr"]
        pinned = ctx.pinned_versions(attribute)
        packages = ctx.locks.get(_PACKAGES)
        c.eq(f"{attribute} keys", sorted(pinned), sorted(packages))
        for name, version in pinned.items():
            c.eq(f"nix_packages.{name}.resolved (Nix evaluation)", packages.get(name, {}).get("resolved"), version)

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        if not ctx.nix:
            return
        packages = ctx.locks.get(_PACKAGES)
        for name, version in ctx.pinned_versions(self.values["attr"]).items():
            if name in packages:
                packages[name]["resolved"] = version
