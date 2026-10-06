"""``minimum-version``: versions that must stay at or above declared
minimums (for example the requirements an external tool documents).

Fields:

    minimums_at     lock path of an object: name -> minimum version
                    (required)
    actual_from     lock paths tried in order for each name's actual
                    version, with {key} bound to the name (required); the
                    first that exists wins
    name, formats   (see rules/__init__.py)

Example::

    { "kind": "minimum-version", "minimums_at": "example_policy.minimum_versions",
      "actual_from": ["skills:npm_tools.{key}", "nix_packages.{key}.resolved"] }

Versions compare as tuples of their decimal numbers (1.10 > 1.9). Check:
``<minimums_at>.<name>: expected at least <minimum!r>, found <actual!r>``.
Check-only.
"""

from __future__ import annotations

import re
from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import Scope, parse_path
from . import Context, FieldSpec, Rule, paths


def version_key(value: Any) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", str(value)))


class MinimumVersion(Rule):
    kind = "minimum-version"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "minimums_at": FieldSpec(parse_path, required=True),
        "actual_from": FieldSpec(paths, required=True),
    }

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        locks = ctx.locks
        minimums = locks.resolve(self.values["minimums_at"])
        for name, minimum in locks.entries(minimums):
            entry = Scope(key=name, value=minimum, base=minimums.child(name), has_entry=True)
            actual = None
            for source in self.values["actual_from"]:
                try:
                    actual = locks.get(locks.resolve(source, entry))
                except (KeyError, TypeError):
                    continue
                break
            c.ok(
                minimums.child(name).text(),
                actual is not None and version_key(actual) >= version_key(minimum),
                f"expected at least {minimum!r}, found {actual!r}",
            )
