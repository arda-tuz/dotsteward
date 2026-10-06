"""``derive``: a lock value that is derived from other lock values.

Fields:

    to          lock path of the derived value (required); its parent must
                exist, the value itself may be missing (check reports it,
                sync writes it)
    from        lock path of the source value, or
    template    a text template (exactly one of from and template)
    for_each, only_with, formats, name   (see rules/__init__.py)

Examples::

    { "kind": "derive", "to": "nix_packages.example.expected",
      "from": "flake_inputs.example.version" }
    { "kind": "derive", "to": "agent_tools.example.official_tag",
      "template": "v{agent_tools.example.version}" }
    { "kind": "derive", "for_each": "example_policy.exact_versions",
      "to": "nix_packages.{key}.expected", "template": "{value}" }

Check: the value at ``to`` equals the source value (label: the ``to``
path). Sync: writes the source value to ``to``.
"""

from __future__ import annotations

from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import Scope, parse_path, parse_template
from . import Context, FieldSpec, Rule


class Derive(Rule):
    kind = "derive"
    FOR_EACH = True
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "to": FieldSpec(parse_path, required=True),
        "from": FieldSpec(parse_path),
        "template": FieldSpec(parse_template),
    }

    def validate(self) -> list[str]:
        if (self.values["from"] is None) == (self.values["template"] is None):
            return ["exactly one of 'from' and 'template' is required"]
        return []

    def _expected(self, ctx: Context, scope: Scope) -> Any:
        if self.values["from"] is not None:
            return ctx.locks.get(ctx.locks.resolve(self.values["from"], scope))
        return ctx.locks.render(self.values["template"], scope)

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        target = ctx.locks.resolve(self.values["to"], scope)
        expected = self._expected(ctx, scope)
        c.eq(target.text(), ctx.locks.get_leaf(target), expected)

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        target = ctx.locks.resolve(self.values["to"], scope)
        ctx.locks.set(target, self._expected(ctx, scope))
