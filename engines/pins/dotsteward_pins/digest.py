"""File and directory digests.

``directory_sha256`` is byte-compatible with ``directory_sha256`` of
``cli/lib/lib.sh``::

    cd DIR
    find . \\( -type d -name __pycache__ -prune \\) -o \\( -type f ! -name '*.pyc' -print0 \\) |
      LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) | sha256sum

that is, the SHA-256 of the ``sha256sum`` lines (``<hex>  ./<path>``) of
every regular file below DIR, sorted by the bytes of ``./<path>``. Not
hashed: directories named ``__pycache__`` (pruned at any depth), files
ending in ``.pyc``, symbolic links (never followed, also not to
directories) and other non-regular files. Like GNU ``sha256sum``, a line
whose name contains a backslash, a newline or a carriage return starts with
a backslash, and those characters are written as ``\\\\``, ``\\n`` and
``\\r``. A tree without hashed files has the digest of the empty input.
"""

from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path

_CHUNK = 1 << 20


def file_sha256(path: Path) -> str:
    """The hex SHA-256 of a file's bytes."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(_CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def _hashed_files(directory: Path) -> list[bytes]:
    """The ``./<path>`` names (bytes) of the hashed files below directory."""
    names: list[bytes] = []
    root = os.fsencode(directory)

    def walk(relative: bytes) -> None:
        current = os.path.join(root, relative) if relative else root
        with os.scandir(current) as entries:
            for entry in entries:
                name = entry.name
                child = os.path.join(relative, name) if relative else name
                mode = entry.stat(follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    if name != b"__pycache__":
                        walk(child)
                elif stat.S_ISREG(mode) and not name.endswith(b".pyc"):
                    names.append(b"./" + child)

    walk(b"")
    return sorted(names)


def _sum_line(hexdigest: str, name: bytes) -> bytes:
    if b"\\" in name or b"\n" in name or b"\r" in name:
        escaped = name.replace(b"\\", b"\\\\").replace(b"\n", b"\\n").replace(b"\r", b"\\r")
        return b"\\" + hexdigest.encode() + b"  " + escaped + b"\n"
    return hexdigest.encode() + b"  " + name + b"\n"


def directory_sha256(directory: Path) -> str:
    """The digest of a directory tree (see the module documentation)."""
    if not directory.is_dir():
        raise FileNotFoundError(2, "No such directory", str(directory))
    outer = hashlib.sha256()
    for name in _hashed_files(directory):
        path = os.path.join(os.fsencode(directory), name[2:])
        outer.update(_sum_line(file_sha256(Path(os.fsdecode(path))), name))
    return outer.hexdigest()
