"""``skill-digests`` (core): the digests of the skills in the skills lock
(``skills[]``, directories below ``[skills] vendor_dir``).

Fields:

    sentinels   revisions that mark a repo-owned skill, whose digests
                follow its files (core passes "same-as-instance-checkout"
                and ``[compat] repo_owned_revision``)
    name, formats   (see rules/__init__.py)

Check (labels ``skills:skills[name=<name>].<field>``): every entry's
``skill_sha256`` (and ``directory_sha256`` when present) is 64 hex digits;
for repo-owned entries both equal the digests of the files (SKILL.md, and
the directory digest of digest.py); a ``dotsteward-*`` name is refused
(framework skills never appear in the instance lock). Nothing to check
without a skills lock.

Sync: rewrites the digests of repo-owned entries and of the entries named
with ``--skill``; ``directory_sha256`` only where the entry has one.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, ClassVar

from ..checker import Checker
from ..digest import directory_sha256, file_sha256
from ..lockfile import SKILLS, Scope, parse_path
from . import Context, FieldSpec, Rule, strings

FRAMEWORK_PREFIX = "dotsteward-"
_SKILLS = parse_path("skills:skills")


class SkillDigests(Rule):
    kind = "skill-digests"
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {"sentinels": FieldSpec(strings, default=[])}

    def _entries(self, ctx: Context) -> list[dict[str, Any]]:
        if SKILLS not in ctx.locks.documents:
            return []
        entries = ctx.locks.get(_SKILLS)
        if not isinstance(entries, list):
            raise TypeError("skills:skills: expected a list")
        return entries

    def _directory(self, ctx: Context, item: dict[str, Any]) -> Path:
        return ctx.instance.path(ctx.instance.vendor_dir) / item["directory"]

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        for item in self._entries(ctx):
            name = item["name"]
            label = f"skills:skills[name={name}]"
            c.fmt(f"{label}.skill_sha256", "hex64", item.get("skill_sha256"))
            if "directory_sha256" in item:
                c.fmt(f"{label}.directory_sha256", "hex64", item["directory_sha256"])
            c.ok(
                label,
                not str(name).startswith(FRAMEWORK_PREFIX),
                "dotsteward-* names are reserved for framework skills",
            )
            if item.get("revision") in self.values["sentinels"]:
                directory = self._directory(ctx, item)
                c.eq(f"{label}.skill_sha256", item.get("skill_sha256"), file_sha256(directory / "SKILL.md"))
                if "directory_sha256" in item:
                    c.eq(f"{label}.directory_sha256", item["directory_sha256"], directory_sha256(directory))

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        for item in self._entries(ctx):
            if item.get("revision") not in self.values["sentinels"] and item["name"] not in ctx.extra_skills:
                continue
            directory = self._directory(ctx, item)
            item["skill_sha256"] = file_sha256(directory / "SKILL.md")
            if "directory_sha256" in item:
                item["directory_sha256"] = directory_sha256(directory)
