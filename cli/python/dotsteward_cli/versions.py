"""The one version order of the framework.

``compare`` answers for every version the framework reads, whichever scheme
its upstream uses, from the last dotted component of a release tag to the
``Version`` field of an APT index:

- A leading ``v`` before a digit is ignored; an epoch (``1:``) comes first.
- The core is everything up to the first ``-`` or ``~``: dot separated parts,
  each compared as runs of numbers and words with numbers first; a missing
  part sorts first (``1.2`` before ``1.2.0``).
- What follows ``~``, or ``-`` and a letter, is a pre-release and sorts before
  the release: ``1.2.3-rc1`` and ``1.2.3~rc1`` before ``1.2.3``, and so does the
  attached form of Python packages (``1.2.3rc1``, ``2.0.0b2``). What follows ``-``
  and a digit is a package revision and sorts after it: ``1.2.3-1`` after
  ``1.2.3``, as dpkg orders it.
- Build metadata (after ``+``) separates only two versions that both carry
  it: ``1.2.3+a`` equals ``1.2.3``, and ``1.2.3+1`` sorts before ``1.2.3+2``. A
  revision after the metadata counts: ``1.2+dfsg-1`` before ``1.2+dfsg-2``.
- A text without any digit sorts before every version.

``dpkg --compare-versions`` stays the authority on installed packages where
dpkg is at hand; stage 0 keeps its small bash floor check for operating system
versions (``preflight_version_at_least``), since it runs before Python exists.
"""

from __future__ import annotations

import functools
import re
from collections.abc import Iterable
from typing import Any, NamedTuple

_RUNS = re.compile(r"[0-9]+|[^0-9]+")
_EPOCH = re.compile(r"([0-9]+):(.*)", re.DOTALL)
_SUFFIX = re.compile(r"[-~]")
_ATTACHED_PRE_RELEASE = re.compile(r"(.*[0-9])((?:a|b|rc|alpha|beta|pre|dev)[0-9]+)", re.DOTALL)
_DIGITS = re.compile(r"[0-9]+")
_ASCII_DIGITS = frozenset("0123456789")


def _runs(text: str) -> tuple[tuple[int, int | str], ...]:
    """TEXT as runs: a number is (0, value), a word (1, text)."""
    return tuple((0, int(run)) if run[0] in _ASCII_DIGITS else (1, run) for run in _RUNS.findall(text))


class _Version(NamedTuple):
    order: tuple[Any, ...]
    build: tuple[tuple[int, int | str], ...]


def _parse(version: Any) -> _Version:
    text = str(version).strip()
    numbered = 1 if _DIGITS.search(text) else 0
    if text[:1] == "v" and text[1:2] in _ASCII_DIGITS:
        text = text[1:]
    epoch = 0
    match = _EPOCH.fullmatch(text)
    if match:
        epoch, text = int(match.group(1)), match.group(2)
    text, plus, build = text.partition("+")
    if plus and "-" in build:
        build, _, revision = build.rpartition("-")
        text = f"{text}-{revision}"
    core, rank, suffix = text, 0, ""
    separator = _SUFFIX.search(text)
    if separator and text[separator.end() :]:
        core, suffix = text[: separator.start()], text[separator.end() :]
        rank = 1 if separator.group() == "-" and suffix[0] in _ASCII_DIGITS else -1
    else:
        attached = _ATTACHED_PRE_RELEASE.fullmatch(text)
        if attached:
            core, rank, suffix = attached.group(1), -1, attached.group(2)
    order = (
        numbered,
        epoch,
        tuple(_runs(part) for part in core.split(".")),
        rank,
        tuple(_runs(part) for part in suffix.split(".")) if suffix else (),
    )
    return _Version(order, _runs(build))


def compare(left: Any, right: Any) -> int:
    """-1, 0 or 1: LEFT sorts before, with or after RIGHT."""
    first, second = _parse(left), _parse(right)
    if first.order != second.order:
        return -1 if first.order < second.order else 1
    if first.build and second.build and first.build != second.build:
        return -1 if first.build < second.build else 1
    return 0


sort_key = functools.cmp_to_key(compare)
"""The key for ``sorted`` and ``max`` that follows ``compare``."""


def at_least(version: Any, minimum: Any) -> bool:
    """Whether VERSION meets the floor MINIMUM."""
    return compare(version, minimum) >= 0


def newest(versions: Iterable[str]) -> str | None:
    """The highest version, or None for an empty set."""
    candidates = list(versions)
    return max(candidates, key=sort_key) if candidates else None


def numeric_parts(version: Any) -> tuple[int, ...]:
    """Every number in VERSION, in order (how far apart two versions are, not their order)."""
    return tuple(int(part) for part in _DIGITS.findall(str(version)))
