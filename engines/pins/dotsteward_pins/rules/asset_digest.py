"""``asset-digest``: a file of the instance pinned by its SHA-256.

Fields:

    path_at     lock path of the instance-relative file path (required)
    sha256_at   lock path of its hex SHA-256 (required)
    name, formats   (see rules/__init__.py)

Check: ``<path_at>: no such file <path!r>`` when the file is missing (or
outside the instance), else ``<sha256_at>: expected <lock value>, found
<actual digest>``. Check-only.
"""

from __future__ import annotations

from pathlib import PurePosixPath
from typing import ClassVar

from ..checker import Checker
from ..digest import file_sha256
from ..lockfile import Scope, parse_path
from . import Context, FieldSpec, Rule


class AssetDigest(Rule):
    kind = "asset-digest"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "path_at": FieldSpec(parse_path, required=True),
        "sha256_at": FieldSpec(parse_path, required=True),
    }

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        locks = ctx.locks
        path_at = locks.resolve(self.values["path_at"])
        sha256_at = locks.resolve(self.values["sha256_at"])
        relative = locks.get(path_at)
        expected = locks.get(sha256_at)
        inside = (
            isinstance(relative, str)
            and relative != ""
            and not PurePosixPath(relative).is_absolute()
            and ".." not in PurePosixPath(relative).parts
        )
        path = ctx.instance.path(relative) if inside else None
        c.ok(path_at.text(), path is not None and path.is_file(), f"no such file {relative!r}")
        if path is not None and path.is_file():
            c.eq(sha256_at.text(), file_sha256(path), expected)
