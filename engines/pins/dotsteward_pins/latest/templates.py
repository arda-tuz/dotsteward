"""Release templates: text with placeholders filled from an upstream answer
(``{version}``, and ``{tag}`` for GitHub releases), such as an asset name
or a download URL. ``{{`` and ``}}`` are literal braces. They are not lock
templates: lock values are read with ``*_at`` lock paths or lock templates
(``id``, ``current``, ``note``, ``package``, ``repo``).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from ..lockfile import DeclarationError


@dataclass(frozen=True)
class ReleaseTemplate:
    source: str
    parts: tuple[tuple[bool, str], ...]  # (is_placeholder, text)

    def uses(self, name: str) -> bool:
        return (True, name) in self.parts

    def render(self, **values: str) -> str:
        return "".join(values[text] if placeholder else text for placeholder, text in self.parts)


def parse(text: Any, names: tuple[str, ...]) -> ReleaseTemplate:
    if not isinstance(text, str) or not text:
        raise DeclarationError(f"expected a non-empty template string, found {text!r}")
    known = ", ".join("{" + name + "}" for name in names)
    parts: list[tuple[bool, str]] = []
    literal = ""
    position = 0
    while position < len(text):
        if text.startswith("{{", position) or text.startswith("}}", position):
            literal += text[position]
            position += 2
            continue
        char = text[position]
        if char == "}":
            raise DeclarationError(f"unbalanced '}}' in {text!r}")
        if char == "{":
            end = text.find("}", position)
            if end < 0:
                raise DeclarationError(f"unbalanced '{{' in {text!r}")
            name = text[position + 1 : end]
            if name not in names:
                raise DeclarationError(f"unknown placeholder {{{name}}} (known: {known})")
            if literal:
                parts.append((False, literal))
                literal = ""
            parts.append((True, name))
            position = end + 1
            continue
        literal += char
        position += 1
    if literal:
        parts.append((False, literal))
    return ReleaseTemplate(text, tuple(parts))


def parser(*names: str) -> Callable[[Any], ReleaseTemplate]:
    """A field parser for release templates with these placeholders."""
    return lambda value: parse(value, names)
