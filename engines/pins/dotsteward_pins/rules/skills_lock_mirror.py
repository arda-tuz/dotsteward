"""``skills-lock-mirror``: values of the skills lock that copy lock values
(the skills lock is read by the agent tooling installer, so it repeats the
versions it needs).

Fields:

    pairs       list of { "from": <lock path>, "to": <skills: lock path> }
                (required); a target's parent must exist
    for_each, only_with, formats, name   (see rules/__init__.py)

Examples::

    { "kind": "skills-lock-mirror", "pairs": [
        { "from": "agent_tools.example.minimum_version",
          "to": "skills:release_tools.example.version" } ] }
    { "kind": "skills-lock-mirror", "for_each": "skills:nix_tools",
      "pairs": [ { "from": "nix_packages.{key}.resolved",
                   "to": "skills:nix_tools.{key}" } ] }
    { "kind": "skills-lock-mirror", "pairs": [
        { "from": "agent_tools.example-plugin.revision",
          "to": "skills:plugins[spec={agent_tools.example-plugin.spec}].revision" } ] }

Check: each target equals its source (label: the target path). Sync:
copies each source to its target.
"""

from __future__ import annotations

from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import SKILLS, DeclarationError, LockPath, Scope, parse_path
from . import Context, FieldSpec, Rule


def _pairs(value: Any) -> list[tuple[LockPath, LockPath]]:
    if not isinstance(value, list) or not value:
        raise DeclarationError(f"expected a non-empty list of {{ from, to }}, found {value!r}")
    result = []
    for index, pair in enumerate(value, start=1):
        if not isinstance(pair, dict) or set(pair) != {"from", "to"}:
            raise DeclarationError(f"pair {index}: expected exactly 'from' and 'to'")
        target = parse_path(pair["to"])
        if target.file != SKILLS or target.relative:
            raise DeclarationError(f"pair {index}: 'to' must be a skills: path")
        result.append((parse_path(pair["from"]), target))
    return result


class SkillsLockMirror(Rule):
    kind = "skills-lock-mirror"
    FOR_EACH = True
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {"pairs": FieldSpec(_pairs, required=True)}

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        locks = ctx.locks
        for source, target in self.values["pairs"]:
            resolved = locks.resolve(target, scope)
            expected = locks.get(locks.resolve(source, scope))
            c.eq(resolved.text(), locks.get_leaf(resolved), expected)

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        locks = ctx.locks
        for source, target in self.values["pairs"]:
            locks.set(locks.resolve(target, scope), locks.get(locks.resolve(source, scope)))
