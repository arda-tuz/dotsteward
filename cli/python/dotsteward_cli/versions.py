"""The one version order of the framework.

``compare`` answers for every version the framework reads, whichever scheme its
upstream uses, from a release tag to the ``Version`` field of an APT index. It is
the algorithm of dpkg (``verrevcmp``, deb-version(7)), so on package versions it
gives dpkg's answer and it is a real order: ``sorted`` and ``max`` do not depend on
the order of their input. A small pre-pass turns what upstreams write into what
dpkg means:

- A leading ``v`` before a digit is ignored.
- A pre-release sorts before its release: ``1.2.3-rc1`` (``-`` and a letter), the
  attached and dotted forms of Python and Ruby packages (``1.2.3rc1``, ``2.0.0b2``,
  ``1.2.3.dev0``, ``7.1.0.beta1``) all mean ``1.2.3~rc1``, and ``~`` means the same
  to dpkg.
- The Python spellings of PEP 440 mean the same: ``c`` and ``preview`` are a
  release candidate (``2.0.0c1`` is ``2.0.0rc1``), and ``N!`` is an epoch.
- A text without any digit sorts before every version.

The rest is dpkg's: an epoch (``1:``) comes first; ``-`` and a digit starts a
package revision, and ``1.2.3-1`` sorts after ``1.2.3``; what follows ``+`` counts,
so ``1.2-1+esm1`` is a newer package than ``1.2-1`` and ``1.2.3+build5`` sorts after
``1.2.3``; numbers compare as numbers and a missing part sorts first (``1.2`` before
``1.2.0``).

Where dpkg is at hand and the versions are of installed packages,
``dpkg --compare-versions`` stays the authority. Stage 0 keeps its small bash floor
check for operating system versions (``preflight_version_at_least``), since it runs
before Python exists.
"""

from __future__ import annotations

import functools
import re
from collections.abc import Iterable
from typing import Any

_ASCII_DIGITS = frozenset("0123456789")
_ASCII_LETTERS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
_EPOCH = re.compile(r"([0-9]+)[:!](.*)", re.DOTALL)
# The first - of a version, before any ~ or +, when a letter follows.
_HYPHEN_WORD = re.compile(r"^([^-~+]*)-(?=[A-Za-z])")
_WORDS = "a|b|rc|c|alpha|beta|preview|pre|dev"
# The Python spellings of a release candidate (PEP 440).
_CANDIDATE = {"c": "rc", "preview": "rc"}
# 1.2.3rc1 and 1.2.3.dev0, with or without a package revision.
_ATTACHED = re.compile(
    rf"(.*[0-9])(?:((?:{_WORDS})[0-9]+)|\.((?:{_WORDS})[0-9]*))(-[^-]*)?",
    re.DOTALL | re.IGNORECASE,
)
_DIGITS = re.compile(r"[0-9]+")


def _order(char: str) -> int:
    """The place of a character outside numbers: ~ before the end of the text, then
    letters, then everything else (a digit counts as the end of the text here)."""
    if char == "~":
        return -1
    if char in _ASCII_DIGITS:
        return 0
    if char in _ASCII_LETTERS:
        return ord(char)
    return ord(char) + 256


def _verrevcmp(left: str, right: str) -> int:
    """dpkg's comparison of two upstream versions or revisions: runs of other
    characters by _order, runs of digits as numbers, of any length."""
    i, j = 0, 0
    left_end, right_end = len(left), len(right)
    while i < left_end or j < right_end:
        while (i < left_end and left[i] not in _ASCII_DIGITS) or (j < right_end and right[j] not in _ASCII_DIGITS):
            left_order = _order(left[i]) if i < left_end else 0
            right_order = _order(right[j]) if j < right_end else 0
            if left_order != right_order:
                return -1 if left_order < right_order else 1
            i += 1
            j += 1
        while i < left_end and left[i] == "0":
            i += 1
        while j < right_end and right[j] == "0":
            j += 1
        first_difference = 0
        while i < left_end and left[i] in _ASCII_DIGITS and j < right_end and right[j] in _ASCII_DIGITS:
            if not first_difference:
                first_difference = ord(left[i]) - ord(right[j])
            i += 1
            j += 1
        if i < left_end and left[i] in _ASCII_DIGITS:
            return 1
        if j < right_end and right[j] in _ASCII_DIGITS:
            return -1
        if first_difference:
            return -1 if first_difference < 0 else 1
    return 0


def _parse(version: Any) -> tuple[int, str, str, str]:
    """(1 when the text has a digit, epoch, upstream version, revision), after the
    pre-pass of the module documentation."""
    text = str(version).strip()
    numbered = 1 if _DIGITS.search(text) else 0
    if text[:1] == "v" and text[1:2] in _ASCII_DIGITS:
        text = text[1:]
    epoch = "0"
    match = _EPOCH.fullmatch(text)
    if match:
        epoch, text = match.group(1), match.group(2)
    # A name such as example-26.05 has no pre-release to find.
    if text[:1] not in _ASCII_LETTERS:
        text = _HYPHEN_WORD.sub(r"\1~", text, count=1)
        attached = _ATTACHED.fullmatch(text)
        if attached:
            base, joined, dotted, revision = attached.groups()
            word = (joined or dotted).lower()
            letters = word.rstrip("0123456789")
            word = _CANDIDATE.get(letters, letters) + word[len(letters) :]
            text = f"{base}~{word}{revision or ''}"
    upstream, separator, revision = text.rpartition("-")
    if not separator:
        upstream, revision = text, ""
    return numbered, epoch, upstream, revision


def compare(left: Any, right: Any) -> int:
    """-1, 0 or 1: LEFT sorts before, with or after RIGHT."""
    first, second = _parse(left), _parse(right)
    if first[0] != second[0]:
        return -1 if first[0] < second[0] else 1
    return _verrevcmp(first[1], second[1]) or _verrevcmp(first[2], second[2]) or _verrevcmp(first[3], second[3])


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
    """Every number in VERSION, in order (how far apart two versions are, not their
    order); the first digits of a number too long to mean anything."""
    return tuple(int(part[:32]) for part in _DIGITS.findall(str(version)))
