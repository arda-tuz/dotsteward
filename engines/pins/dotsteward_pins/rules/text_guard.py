"""``text-guard``: an instance file must contain a text built from lock
values (for example a Nix assertion that keeps a package at its pinned
version).

Fields:

    file        instance-relative file (required)
    template    text template of the required text (required)
    for_each, only_with, formats, name   (see rules/__init__.py)

Example::

    { "kind": "text-guard", "file": "home.nix",
      "for_each": "example_policy.exact_versions",
      "template": "pkgs.{key}.version == \\"{value}\\"" }

Check: ``<file>: missing <text!r>`` when the text is absent, ``<file>: no
such file`` when the file is. Check-only.
"""

from __future__ import annotations

from typing import ClassVar

from ..checker import Checker
from ..lockfile import Scope, parse_template
from . import Context, FieldSpec, Rule, relative_file


class TextGuard(Rule):
    kind = "text-guard"
    FOR_EACH = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "file": FieldSpec(relative_file, required=True),
        "template": FieldSpec(parse_template, required=True),
    }

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        name = self.values["file"]
        path = ctx.instance.path(name)
        if not path.is_file():
            c.ok(name, False, "no such file")
            return
        text = ctx.locks.render(self.values["template"], scope)
        c.ok(name, text in path.read_text(encoding="utf-8"), f"missing {text!r}")
