"""JSONC reader of the settings engine.

JSONC is JSON with ``//`` line comments, ``/* */`` block comments and
trailing commas, the format some editors use for their settings files. The
engine reads such a target with ``strip`` followed by ``json.loads``. It
never writes a file that had comments or trailing commas (it cannot keep
them), so ``strip`` also tells whether there were any.

``strip`` replaces every removed character with a space and keeps every line
break, so the result has the length and the line structure of the input and
``json.loads`` reports positions of the original file.
"""

from __future__ import annotations

_WHITESPACE = frozenset(" \t\r\n")


def _blank(text: str) -> str:
    """TEXT with every character except line breaks replaced by a space."""
    return "".join(char if char == "\n" else " " for char in text)


def _position(text: str, index: int) -> str:
    line = text.count("\n", 0, index) + 1
    column = index - (text.rfind("\n", 0, index) + 1) + 1
    return f"line {line} column {column}"


def strip(text: str) -> tuple[str, bool]:
    """Removes comments and trailing commas outside strings.

    Returns the JSON text and whether anything was removed. Raises ValueError
    for a block comment that is never closed. Everything else, valid JSON or
    not, is passed through for ``json.loads`` to judge.
    """
    pieces: list[str] = []
    changed = False
    # Index in pieces of a comma that only whitespace and comments follow so far.
    pending_comma: int | None = None
    length = len(text)
    index = 0
    while index < length:
        char = text[index]
        if char == '"':
            end = index + 1
            while end < length:
                if text[end] == "\\":
                    end += 2
                    continue
                end += 1
                if text[end - 1] == '"':
                    break
            pieces.append(text[index:end])
            pending_comma = None
            index = end
            continue
        if char == "/" and text.startswith("//", index):
            end = text.find("\n", index)
            if end == -1:
                end = length
            pieces.append(_blank(text[index:end]))
            changed = True
            index = end
            continue
        if char == "/" and text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end == -1:
                raise ValueError(f"unterminated block comment at {_position(text, index)}")
            pieces.append(_blank(text[index : end + 2]))
            changed = True
            index = end + 2
            continue
        if char in _WHITESPACE:
            start = index
            while index < length and text[index] in _WHITESPACE:
                index += 1
            pieces.append(text[start:index])
            continue
        if char in "}]" and pending_comma is not None:
            pieces[pending_comma] = " "
            changed = True
        pending_comma = len(pieces) if char == "," else None
        pieces.append(char)
        index += 1
    return "".join(pieces), changed
