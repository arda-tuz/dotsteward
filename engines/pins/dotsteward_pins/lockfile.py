"""Lock files: serializer, atomic writes, lock paths and templates.

Serializer: ``json.dumps(data, indent=2, ensure_ascii=False)``
plus a final newline, keys in insertion order, values updated in place.
``generated_at`` is written as ``YYYY-MM-DDTHH:MM:SS+00:00`` in the versions
lock and ``YYYY-MM-DDTHH:MM:SSZ`` in the skills lock. Writes are atomic: a
temporary file next to the target (same mode) renamed over it.

Lock paths
----------
A lock path addresses a value of one of the two lock files::

    [versions: | skills:] [.] segment ( . segment )*
    segment   := key selector*
    key       := bare | "json string" | {placeholder}
    selector  := [ field = value ]          (value: bare, "json string" or
                                              {placeholder})

``versions:`` (the default) is the versions lock (``[pins] versions_lock``),
``skills:`` the skills lock (``[skills] lock``). A bare key is any text
without ``.``, ``[``, ``]``, ``{``, ``}``, ``"`` and ``=``; other keys are
written as JSON strings (``feature_probes."example --version"``). A selector
picks the first element of a list whose ``field`` equals ``value``
(``skills:plugins[spec=example@market].revision``). A leading ``.`` makes
the path relative to the rule's base object (``at``, or the ``for_each``
entry). Placeholders, resolved per evaluation: ``{key}`` and ``{value}`` of
the ``for_each`` entry, or ``{<lock path>}`` for the value at another path
(used whole as one key or selector value, never spliced into text).

Templates
---------
A text template renders ``{placeholder}`` (same placeholders as above) and
keeps everything else; ``{{`` and ``}}`` are literal braces. Placeholder
values must be strings or integers.

A missing key or selector raises ``KeyError(<full path>)``; a value of the
wrong type on the way raises ``TypeError``. Rules turn both into one failure
line of their group.
"""

from __future__ import annotations

import datetime
import json
import os
import stat
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

VERSIONS = "versions"
SKILLS = "skills"
FILES = (VERSIONS, SKILLS)

_BARE_FORBIDDEN = set('.[]{}"=')


class DeclarationError(Exception):
    """An invalid path or template in a rule declaration."""


# --- Serializer -----------------------------------------------------------------


def dump(data: Any) -> str:
    """The exact lock file text of ``data``."""
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def write_atomic(path: Path, text: str) -> None:
    """Replaces ``path`` with ``text`` through a temporary file in the same
    directory, keeping the mode of the existing file."""
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def generated_at(kind: str, now: datetime.datetime) -> str:
    """The generated_at text of a lock file for the UTC instant ``now``."""
    now = now.astimezone(datetime.UTC).replace(microsecond=0)
    if kind == SKILLS:
        return now.strftime("%Y-%m-%dT%H:%M:%SZ")
    return now.isoformat()


# --- Paths ----------------------------------------------------------------------


@dataclass(frozen=True)
class Placeholder:
    """``{key}``, ``{value}`` or ``{<lock path>}`` inside a path or template."""

    name: str
    path: LockPath | None = None

    def text(self) -> str:
        return "{" + (self.path.text() if self.path is not None else self.name) + "}"


@dataclass(frozen=True)
class Step:
    """One segment of a path: a key and optional list selectors."""

    key: str | Placeholder
    selectors: tuple[tuple[str, str | Placeholder], ...] = ()


@dataclass(frozen=True)
class LockPath:
    """A parsed lock path (possibly with placeholders and relative)."""

    file: str
    steps: tuple[Step, ...]
    relative: bool = False

    def text(self) -> str:
        """The canonical spelling (also used in messages)."""
        prefix = "skills:" if self.file == SKILLS else ""
        body = ".".join(_step_text(step) for step in self.steps)
        return prefix + ("." if self.relative else "") + body

    def concrete(self) -> bool:
        return not self.relative and all(
            isinstance(step.key, str) and all(isinstance(value, str) for _, value in step.selectors)
            for step in self.steps
        )

    def child(self, *keys: str) -> LockPath:
        return LockPath(self.file, self.steps + tuple(Step(key) for key in keys), self.relative)

    def parent(self) -> tuple[LockPath, Step]:
        return LockPath(self.file, self.steps[:-1], self.relative), self.steps[-1]


def _quote(text: str) -> str:
    if text and not (_BARE_FORBIDDEN & set(text)) and text.strip() == text:
        return text
    return json.dumps(text, ensure_ascii=False)


def _value_text(value: str | Placeholder) -> str:
    return value.text() if isinstance(value, Placeholder) else _quote(value)


def _step_text(step: Step) -> str:
    text = _value_text(step.key)
    for name, value in step.selectors:
        text += f"[{name}={_value_text(value)}]"
    return text


class _Parser:
    def __init__(self, text: str, allow_placeholders: bool) -> None:
        self.text = text
        self.position = 0
        self.allow_placeholders = allow_placeholders

    def fail(self, message: str) -> DeclarationError:
        return DeclarationError(f"invalid lock path {self.text!r}: {message}")

    def peek(self) -> str:
        return self.text[self.position] if self.position < len(self.text) else ""

    def bare(self) -> str:
        start = self.position
        while self.position < len(self.text) and self.text[self.position] not in _BARE_FORBIDDEN:
            self.position += 1
        return self.text[start : self.position]

    def quoted(self) -> str:
        decoder = json.JSONDecoder()
        try:
            value, end = decoder.raw_decode(self.text, self.position)
        except json.JSONDecodeError as error:
            raise self.fail(f"bad quoted key at {self.position + 1}") from error
        if not isinstance(value, str):
            raise self.fail(f"bad quoted key at {self.position + 1}")
        self.position = end
        return value

    def placeholder(self) -> Placeholder:
        if not self.allow_placeholders:
            raise self.fail("nested placeholders are not supported")
        end = self.text.find("}", self.position)
        if end < 0:
            raise self.fail("unbalanced '{'")
        inner = self.text[self.position + 1 : end]
        self.position = end + 1
        return placeholder(inner, self.text)

    def atom(self, what: str) -> str | Placeholder:
        char = self.peek()
        if char == '"':
            return self.quoted()
        if char == "{":
            return self.placeholder()
        value = self.bare()
        if not value:
            raise self.fail(f"empty {what} at {self.position + 1}")
        return value

    def parse(self) -> LockPath:
        text = self.text
        file = VERSIONS
        for name in FILES:
            if text.startswith(name + ":"):
                file = name
                self.position = len(name) + 1
                break
        relative = False
        if self.peek() == ".":
            relative = True
            self.position += 1
        steps = []
        while True:
            key = self.atom("key")
            selectors = []
            while self.peek() == "[":
                self.position += 1
                name = self.bare()
                if not name or self.peek() != "=":
                    raise self.fail(f"bad selector at {self.position + 1}")
                self.position += 1
                value = self.atom("selector value")
                if self.peek() != "]":
                    raise self.fail(f"unclosed selector at {self.position + 1}")
                self.position += 1
                selectors.append((name, value))
            steps.append(Step(key, tuple(selectors)))
            if self.position == len(text):
                break
            if self.peek() != ".":
                raise self.fail(f"unexpected {self.peek()!r} at {self.position + 1}")
            self.position += 1
        return LockPath(file, tuple(steps), relative)


def placeholder(inner: str, context: str) -> Placeholder:
    """The placeholder named by the text between braces."""
    inner = inner.strip()
    if inner in ("key", "value"):
        return Placeholder(inner)
    if not inner:
        raise DeclarationError(f"empty placeholder in {context!r}")
    return Placeholder(inner, _Parser(inner, allow_placeholders=False).parse())


def parse_path(text: Any) -> LockPath:
    """Parses a lock path declaration; DeclarationError when invalid."""
    if not isinstance(text, str) or not text:
        raise DeclarationError(f"expected a lock path, found {text!r}")
    return _Parser(text, allow_placeholders=True).parse()


# --- Templates ------------------------------------------------------------------


@dataclass(frozen=True)
class Template:
    """A parsed text template: literal strings and placeholders."""

    source: str
    parts: tuple[str | Placeholder, ...]


def parse_template(text: Any) -> Template:
    if not isinstance(text, str):
        raise DeclarationError(f"expected a template string, found {text!r}")
    parts: list[str | Placeholder] = []
    literal = ""
    position = 0
    while position < len(text):
        char = text[position]
        if text.startswith("{{", position) or text.startswith("}}", position):
            literal += char
            position += 2
            continue
        if char == "}":
            raise DeclarationError("unbalanced '}'")
        if char == "{":
            end = text.find("}", position)
            if end < 0 or "{" in text[position + 1 : end]:
                raise DeclarationError("unbalanced '{'")
            if literal:
                parts.append(literal)
                literal = ""
            parts.append(placeholder(text[position + 1 : end], text))
            position = end + 1
            continue
        literal += char
        position += 1
    if literal:
        parts.append(literal)
    return Template(text, tuple(parts))


# --- Documents ------------------------------------------------------------------


@dataclass
class Scope:
    """Placeholder values of one evaluation: the for_each entry and the base
    object of relative paths."""

    key: str | None = None
    value: Any = None
    base: LockPath | None = None
    has_entry: bool = False


@dataclass
class Locks:
    """The two lock documents (the skills lock may be absent)."""

    documents: dict[str, Any] = field(default_factory=dict)
    labels: dict[str, str] = field(default_factory=dict)

    # -- resolution --

    def resolve(self, path: LockPath, scope: Scope | None = None) -> LockPath:
        """A concrete path: placeholders replaced, relative paths joined."""
        scope = scope or Scope()
        steps = tuple(
            Step(
                self._atom(step.key, scope),
                tuple((name, self._atom(value, scope)) for name, value in step.selectors),
            )
            for step in path.steps
        )
        if path.relative:
            if scope.base is None:
                raise DeclarationError(f"relative path {path.text()!r} outside of a rule with a base object")
            return LockPath(scope.base.file, scope.base.steps + steps)
        return LockPath(path.file, steps)

    def _atom(self, atom: str | Placeholder, scope: Scope) -> str:
        if isinstance(atom, str):
            return atom
        value = self.placeholder_value(atom, scope)
        return scalar_text(value, atom)

    def placeholder_value(self, atom: Placeholder, scope: Scope) -> Any:
        if atom.path is None:
            if not scope.has_entry:
                raise DeclarationError(f"{atom.text()} is only available with for_each")
            return scope.key if atom.name == "key" else scope.value
        return self.get(self.resolve(atom.path, scope))

    def render(self, template: Template, scope: Scope | None = None) -> str:
        scope = scope or Scope()
        return "".join(
            part if isinstance(part, str) else scalar_text(self.placeholder_value(part, scope), part)
            for part in template.parts
        )

    # -- access --

    def _walk(self, path: LockPath, steps: tuple[Step, ...]) -> Any:
        if path.file not in self.documents:
            raise KeyError(path.text())
        current = self.documents[path.file]
        for step in steps:
            if not isinstance(current, dict):
                raise TypeError(f"{path.text()}: expected an object before {_step_text(step)!r}")
            assert isinstance(step.key, str)
            if step.key not in current:
                raise KeyError(path.text())
            current = current[step.key]
            for name, value in step.selectors:
                if not isinstance(current, list):
                    raise TypeError(f"{path.text()}: expected a list for [{name}=...]")
                for item in current:
                    if isinstance(item, dict) and item.get(name) == value:
                        current = item
                        break
                else:
                    raise KeyError(path.text())
        return current

    def get(self, path: LockPath) -> Any:
        """The value at a concrete path."""
        return self._walk(path, path.steps)

    def exists(self, path: LockPath) -> bool:
        try:
            self.get(path)
        except (KeyError, TypeError):
            return False
        return True

    def get_leaf(self, path: LockPath) -> Any:
        """The value at a concrete path, None when only its last key is
        missing (its parent must exist)."""
        parent, last = path.parent()
        container = self._walk(path, parent.steps)
        if last.selectors:
            return self.get(path)
        if not isinstance(container, dict):
            raise TypeError(f"{path.text()}: expected an object before {_step_text(last)!r}")
        assert isinstance(last.key, str)
        return container.get(last.key)

    def set(self, path: LockPath, value: Any) -> None:
        """Sets the value at a concrete path; its parent must exist (sync
        never creates entries)."""
        parent, last = path.parent()
        if last.selectors:
            raise DeclarationError(f"cannot write through a selector: {path.text()}")
        container = self._walk(path, parent.steps)
        if not isinstance(container, dict):
            raise TypeError(f"{path.text()}: expected an object before {_step_text(last)!r}")
        assert isinstance(last.key, str)
        container[last.key] = value

    def entries(self, path: LockPath) -> Iterator[tuple[str, Any]]:
        """The (key, value) pairs of the object at a concrete path."""
        mapping = self.get(path)
        if not isinstance(mapping, dict):
            raise TypeError(f"{path.text()}: expected an object")
        yield from list(mapping.items())


def scalar_text(value: Any, atom: Placeholder | None = None) -> str:
    """A placeholder value as text: strings as they are, integers in
    decimal; anything else is a ValueError."""
    if isinstance(value, str):
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    name = atom.text() if atom is not None else "placeholder"
    raise ValueError(f"{name} is not a string or an integer: {value!r}")


# --- Loading ----------------------------------------------------------------------


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))
