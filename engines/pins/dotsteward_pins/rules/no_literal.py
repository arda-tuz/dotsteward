"""``no-literal``: files that must not contain literal pins or placeholder
hashes (pins are read from the lock, never copied).

Fields (at least one of patterns, regexes, values):

    files       instance-relative globs (required; ``**`` spans
                directories; a glob without match is fine)
    patterns    preset names: "sri" (an SRI sha256 hash) and "fake-hash"
                (an all-A SRI hash or lib.fakeHash)
    regexes     object: name -> Python regular expression
    values      lock paths whose values must not appear literally (empty
                values are skipped)
    name, formats   (see rules/__init__.py)

Core declares two: sri and fake-hash over flake.nix, home.nix and
components/**/*.nix, and fake-hash over both lock files.

Check, per matched file in path order: ``<file>: contains a literal
matching <name> (<first match!r>)`` and ``<file>: contains the literal
value of <path>``. Check-only.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, ClassVar

from ..checker import SRI, Checker
from ..lockfile import DeclarationError, Scope, scalar_text
from . import Context, FieldSpec, Rule, paths, relative_files, strings

PRESETS: dict[str, re.Pattern[str]] = {
    "sri": SRI,
    "fake-hash": re.compile(r"sha256-A{43}=|lib\.fakeHash"),
}


def _presets(value: Any) -> list[str]:
    names = strings(value)
    unknown = [name for name in names if name not in PRESETS]
    if unknown:
        raise DeclarationError(f"unknown pattern {unknown[0]!r} (known: {', '.join(PRESETS)})")
    return names


def _regexes(value: Any) -> list[tuple[str, re.Pattern[str]]]:
    if not isinstance(value, dict) or not value:
        raise DeclarationError(f"expected an object of name -> regular expression, found {value!r}")
    result = []
    for name, regex in value.items():
        if not isinstance(regex, str):
            raise DeclarationError(f"{name}: expected a regular expression string")
        try:
            result.append((name, re.compile(regex)))
        except re.error as error:
            raise DeclarationError(f"{name}: invalid regular expression ({error})") from error
    return result


class NoLiteral(Rule):
    kind = "no-literal"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "files": FieldSpec(relative_files, required=True),
        "patterns": FieldSpec(_presets, default=[]),
        "regexes": FieldSpec(_regexes, default=[]),
        "values": FieldSpec(paths, default=[]),
    }

    def validate(self) -> list[str]:
        if not (self.values["patterns"] or self.values["regexes"] or self.values["values"]):
            return ["one of 'patterns', 'regexes' and 'values' is required"]
        return []

    def _files(self, root: Path) -> list[Path]:
        found: dict[str, Path] = {}
        for pattern in self.values["files"]:
            for path in root.glob(pattern):
                if path.is_file():
                    found.setdefault(str(path.relative_to(root)), path)
        return [found[name] for name in sorted(found)]

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        root = ctx.instance.root
        patterns = [(name, PRESETS[name]) for name in self.values["patterns"]] + self.values["regexes"]
        values = []
        for path in self.values["values"]:
            resolved = ctx.locks.resolve(path, scope)
            text = scalar_text(ctx.locks.get(resolved))
            if text:
                values.append((resolved.text(), text))
        for path in self._files(root):
            name = str(path.relative_to(root))
            content = path.read_text(encoding="utf-8", errors="replace")
            for pattern_name, pattern in patterns:
                match = pattern.search(content)
                detail = f"contains a literal matching {pattern_name} ({match.group(0)!r})" if match else ""
                c.ok(name, match is None, detail)
            for label, text in values:
                c.ok(name, text not in content, f"contains the literal value of {label}")
