"""``skill-source`` (built in): upstream changes of a vendored skill.

One row ``skills.<name>`` per entry of the skills lock whose revision is a
40-digit commit (core.py); entries with the repo-owned sentinel have no
row, other revisions are ``manual`` rows. Only upstream changes below the
skill's ``source_path`` that touch a vendored file (a file of
``<[skills] vendor_dir>/<directory>``) or the skill structure (SKILL.md,
references/, scripts/, assets/, agents/, LICENSE) count. ``release_bound``
entries compare with the newest release tag. The compare is shared with
every row of the same repository, revision and release binding
(git_compare.py).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from .git_compare import CompareAdapter

SKILL_STRUCTURE = ("SKILL.md", "references/", "scripts/", "assets/", "agents/", "LICENSE")


def vendored_filter(source_path: str, directory: Path) -> Callable[[str], bool]:
    """Selects upstream paths that change vendored files or the structure."""
    path = source_path.strip("/")
    prefix = "" if path in ("", ".") else path + "/"
    vendored = (
        {entry.relative_to(directory).as_posix() for entry in directory.rglob("*") if entry.is_file()}
        if directory.is_dir()
        else set()
    )

    def matches(name: str) -> bool:
        if not name.startswith(prefix):
            return False
        relative = name[len(prefix) :]
        return relative in vendored or relative.startswith(SKILL_STRUCTURE)

    return matches


class SkillSource(CompareAdapter):
    name = "skill-source"
    BUILT_IN = True
