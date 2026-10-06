"""``nix-package-format`` (core, always on): the entries of ``nix_packages``.

No fields. Per entry: ``resolved`` is a non-empty string and equals
``expected`` unless ``expected`` is the sentinel ``"locked nixpkgs
package"`` (the version is whatever the locked nixpkgs provides);
``official_tag`` (when present) is ``v<expected>``; ``tag_revision`` and
``source_revision`` (when present) are 40 hex digits; every
``*_nix_sha256`` field is SRI.

Sync: ``official_tag`` (where present) becomes ``v<expected>``.
"""

from __future__ import annotations

from ..checker import Checker
from ..lockfile import Scope, parse_path
from . import Context, Rule

LOCKED_NIXPKGS = "locked nixpkgs package"
_PACKAGES = parse_path("nix_packages")


class NixPackageFormat(Rule):
    kind = "nix-package-format"
    SYNCS = True

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        for name, pin in ctx.locks.entries(_PACKAGES):
            label = f"nix_packages.{name}"
            c.fmt(f"{label}.resolved", "nonempty", pin.get("resolved"))
            if pin.get("expected") != LOCKED_NIXPKGS:
                c.eq(f"{label}.resolved", pin.get("resolved"), pin.get("expected"))
            if "official_tag" in pin:
                c.eq(f"{label}.official_tag", pin["official_tag"], f"v{pin.get('expected')}")
            for key in ("tag_revision", "source_revision"):
                if key in pin:
                    c.fmt(f"{label}.{key}", "hex40", pin[key])
            for key, value in pin.items():
                if key.endswith("_nix_sha256"):
                    c.fmt(f"{label}.{key}", "sri", value)

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        for _, pin in ctx.locks.entries(_PACKAGES):
            if "official_tag" in pin:
                pin["official_tag"] = f"v{pin['expected']}"
