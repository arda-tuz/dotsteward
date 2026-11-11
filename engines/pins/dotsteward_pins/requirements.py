"""Hash-pinned Python requirements files (``pip install --require-hashes``): the version a
file pins a distribution at, and the files it allows for it (the ``--hash`` options of its
line). The writer reads them when it moves a pypi pin, ``pins check`` when it holds a signed
pin to the files its attestations vouch for."""

from __future__ import annotations

import re


def name_pattern(name: str) -> str:
    """A regular expression of the distribution NAME in every spelling its normalized name allows."""
    return "[-_.]+".join(re.escape(part) for part in re.split(r"[-_.]+", name))


def pinned_version(name: str, text: str) -> str | None:
    """The version the requirements TEXT pin the distribution NAME at."""
    found = re.search(rf"^{name_pattern(name)}==([^\s;\\]+)", text, re.MULTILINE | re.IGNORECASE)
    return found[1] if found else None


def hashes(name: str, version: str, text: str) -> tuple[str, ...]:
    """The SHA-256 digests the requirements TEXT allow for NAME==VERSION: the --hash options of
    its line, with its continuation lines."""
    logical = re.sub(r"\\[ \t]*\r?\n", " ", text)
    head = re.compile(rf"\s*{name_pattern(name)}\s*==\s*{re.escape(version)}(?=[\s;]|$)", re.IGNORECASE)
    for line in logical.splitlines():
        if head.match(line):
            found = re.findall(r"--hash[=\s]+sha256:([0-9a-fA-F]{64})\b", line)
            return tuple(dict.fromkeys(digest.lower() for digest in found))
    return ()
