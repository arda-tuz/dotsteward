"""What a signer of a pin may be (docs/pins-engine.md, Authenticity): the rules
the writer applies when it pins a signer and ``pins check`` applies to what
the lock holds. The install methods apply the same rules (cli/lib/methods.sh).
"""

from __future__ import annotations

import re

_SPECIAL = set("\\.^$*+?()[]{}|")
# What would let an identity_regexp match more than one identity up to the
# parts a release changes.
_LOOSE = ("|", ".*", ".+", ".?", "[^", "(?", "\\S", "\\w", "\\D", "\\W")


def escape(text: str) -> str:
    """TEXT as a literal in a regular expression (RE2 and Python agree)."""
    return "".join(f"\\{char}" if char in _SPECIAL else char for char in text)


def identity_regexp(identity: str) -> str:
    """The regular expression that pins IDENTITY: escaped, and after
    ``@refs/tags/`` every run of digits generalized, so the next release of the
    same workflow matches and nothing else does."""
    head, separator, tag = identity.partition("@refs/tags/")
    if not separator:
        return f"^{escape(identity)}$"
    return f"^{escape(head + separator)}{re.sub(r'[0-9]+', '[0-9]+', escape(tag))}$"


def repository_prefix(repository: str) -> str:
    """The start of every workflow identity of the GitHub REPOSITORY (owner/name)."""
    return f"https://github.com/{repository}/"


def pins_one_identity(regexp: str, repository: str | None = None) -> bool:
    """REGEXP names one identity: anchored at both ends, without alternation or
    wildcard, and, for a pin of a GitHub REPOSITORY, of a workflow of it."""
    if len(regexp) < 3 or not regexp.startswith("^") or not regexp.endswith("$"):
        return False
    if any(text in regexp for text in _LOOSE):
        return False
    if repository is not None:
        return regexp.lower().startswith("^" + escape(repository_prefix(repository)).lower())
    return True


def of_repository(identity: str, repository: str) -> bool:
    """IDENTITY is a workflow of the GitHub REPOSITORY (names compare without case)."""
    return identity.lower().startswith(repository_prefix(repository).lower())


def tag_of(identity: str) -> str | None:
    """The tag of an identity of a tag (``...@refs/tags/<tag>``), else None."""
    head, separator, tag = identity.partition("@refs/tags/")
    return tag if separator and head else None


def matches(regexp: str, identity: str) -> bool:
    try:
        return re.search(regexp, identity) is not None
    except re.error:
        return False
