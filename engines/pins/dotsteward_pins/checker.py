"""Assertion accumulator of ``pins check``.

Every assertion counts as one check; failures are collected in order and
printed together. Failure lines (after the ``[pins] ERROR: `` prefix):

    <label>: expected <expected!r>, found <actual!r>        eq
    <label>: <detail>   (or <label> alone)                  ok
    <label>: invalid format <value!r>, expected <format>    fmt
    <label>: expected to contain <needle!r>, found <value!r> contains
    <group>: missing or invalid lock field (<exception!r>)  group
    <group>: cannot read <file>: <reason>                   group (I/O)

``group`` isolates one rule: a missing key, a value of the wrong type or a
bad value (KeyError, StopIteration, TypeError, AttributeError, ValueError)
aborts only that rule and becomes one failure line; an unreadable file
becomes a "cannot read" line.
"""

from __future__ import annotations

import contextlib
import os
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

SRI = re.compile(r"sha256-[A-Za-z0-9+/]{43}=")
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX40 = re.compile(r"[0-9a-f]{40}")


def _matches(pattern: re.Pattern[str]) -> Callable[[Any], bool]:
    return lambda value: isinstance(value, str) and pattern.fullmatch(value) is not None


# Format names usable in rule declarations ("formats") and by the rules.
FORMATS: dict[str, Callable[[Any], bool]] = {
    "hex40": _matches(HEX40),
    "hex64": _matches(HEX64),
    "sri": _matches(SRI),
    "sha512": lambda value: isinstance(value, str) and value.startswith("sha512-"),
    "nonempty": lambda value: isinstance(value, str) and value != "",
    "positive-int": lambda value: isinstance(value, int) and not isinstance(value, bool) and value > 0,
    "https-url": lambda value: isinstance(value, str) and value.startswith("https://"),
}

GROUP_ERRORS = (KeyError, StopIteration, TypeError, AttributeError, ValueError)


class Checker:
    """Counts assertions and collects failure lines."""

    def __init__(self, root: Path | None = None) -> None:
        self.failures: list[str] = []
        self.count = 0
        self.root = root

    def eq(self, label: str, actual: Any, expected: Any) -> None:
        self.count += 1
        if actual != expected:
            self.failures.append(f"{label}: expected {expected!r}, found {actual!r}")

    def ok(self, label: str, condition: bool, detail: str = "") -> None:
        self.count += 1
        if not condition:
            self.failures.append(f"{label}: {detail}" if detail else label)

    def fmt(self, label: str, name: str, value: Any) -> None:
        self.count += 1
        if not FORMATS[name](value):
            self.failures.append(f"{label}: invalid format {value!r}, expected {name}")

    def contains(self, label: str, value: Any, needle: str) -> None:
        self.count += 1
        if not (isinstance(value, str) and needle in value):
            self.failures.append(f"{label}: expected to contain {needle!r}, found {value!r}")

    def fail(self, line: str) -> None:
        self.failures.append(line)

    def group(self, name: str, function: Callable[..., None], *args: Any) -> bool:
        """Runs one rule; returns False when it was aborted."""
        try:
            function(*args)
        except GROUP_ERRORS as error:
            self.failures.append(f"{name}: missing or invalid lock field ({error!r})")
            return False
        except OSError as error:
            self.failures.append(f"{name}: {describe_os_error(error, self.root)}")
            return False
        return True


def describe_os_error(error: OSError, root: Path | None) -> str:
    """'cannot read <file>: <reason>' with the file relative to root."""
    filename = error.filename
    if filename is None:
        return f"cannot read: {error.strerror or error}"
    name = os.fsdecode(filename)
    if root is not None:
        with contextlib.suppress(ValueError):
            name = str(Path(name).relative_to(root))
    return f"cannot read {name}: {error.strerror or error}"
