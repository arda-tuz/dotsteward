"""The one TOML reader of the package.

``load`` and ``loads`` give a plain document. Text that is not TOML, bad syntax
or bytes that are not UTF-8, raises ``TomlError``; an unreadable file raises its
``OSError``. A caller words the error for its own file. The five modules that
edit TOML and keep its comments (``init``, ``host``, ``skills.plugins``, ``track``
and the settings engine) use tomlkit for that; a read goes through here.
"""

from __future__ import annotations

import os
import tomllib
from typing import Any


class TomlError(ValueError):
    """Text that is not TOML; the message says why."""


def loads(data: str | bytes) -> dict[str, Any]:
    """The document of a TOML text."""
    try:
        text = data.decode("utf-8") if isinstance(data, bytes) else data
    except UnicodeDecodeError as error:
        raise TomlError(f"not valid UTF-8 ({error.reason} at byte {error.start})") from error
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise TomlError(str(error)) from error


def load(path: str | os.PathLike[str]) -> dict[str, Any]:
    """The document of the TOML file at PATH."""
    with open(path, "rb") as handle:
        return loads(handle.read())
