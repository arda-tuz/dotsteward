"""Atomic file writes: a reader sees the old file or the new one, never a part
of it, also after a crash or a power cut.

``atomic_write`` writes a temporary file in the directory of the target, syncs
it, renames it over the target and syncs the directory. The target is replaced,
so a symbolic link at the path becomes a file and a reader that opened the old
file keeps reading it. A writer that dies leaves the old file and a temporary
file named after its process; the next write of that target removes it.
"""

from __future__ import annotations

import contextlib
import errno
import json
import os
import re
import stat
import tempfile
from typing import Any

from dotsteward_cli import procs

DEFAULT_MODE = 0o644
# A file name has at most 255 bytes, and the temporary name adds to the target's.
_STEM_BYTES = 200


def make_private_dirs(path: str | os.PathLike[str]) -> None:
    """Creates the directory PATH with mode 0700. Missing parents follow the umask:
    a first command must not close ~/.local to everyone. The directories that exist
    stay as they are."""
    target = os.path.abspath(path)
    if not os.path.isdir(target):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with contextlib.suppress(FileExistsError):
            os.mkdir(target, 0o700)


def _remove_leftovers(directory: str, stem: str) -> None:
    """Removes the temporary files of the target with this STEM that dead writers
    left, as far as it can: a directory it cannot list is no reason to fail."""
    pattern = re.compile(rf"\.{re.escape(stem)}\.([0-9]+)\.[^.]*\.tmp")
    with contextlib.suppress(OSError), os.scandir(directory) as entries:
        for entry in entries:
            match = pattern.fullmatch(entry.name)
            if match and not procs.process_exists(int(match.group(1))):
                os.unlink(entry.path)


def _sync_directory(directory: str) -> None:
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except PermissionError:  # a directory that can be written but not read
        return
    try:
        os.fsync(descriptor)
    except OSError as error:
        # Some file systems cannot sync a directory; the rename has happened.
        if error.errno not in (errno.EINVAL, errno.ENOTSUP):
            raise
    finally:
        os.close(descriptor)


def atomic_write(
    path: str | os.PathLike[str], data: bytes | str, *, mode: int | None = None, parents: bool = False
) -> None:
    """Replaces the file at PATH with DATA (a str is written as UTF-8, without
    newline translation). The file gets MODE, else the mode of the file it
    replaces, else 0644, whatever the umask. PARENTS creates missing parent
    directories; without it they are an error, FileNotFoundError."""
    target = os.path.abspath(path)
    directory, name = os.path.split(target)
    payload = data.encode("utf-8") if isinstance(data, str) else data
    if mode is None:
        try:
            mode = stat.S_IMODE(os.stat(target).st_mode)
        except FileNotFoundError:
            mode = DEFAULT_MODE
    if parents:
        os.makedirs(directory, exist_ok=True)
    stem = os.fsdecode(os.fsencode(name)[:_STEM_BYTES])
    _remove_leftovers(directory, stem)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{stem}.{os.getpid()}.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
    _sync_directory(directory)


def atomic_write_json(
    path: str | os.PathLike[str], value: Any, *, mode: int | None = None, parents: bool = False
) -> None:
    """Replaces the file at PATH with VALUE as indented JSON text and a final newline."""
    text = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    atomic_write(path, text.encode("utf-8", "backslashreplace"), mode=mode, parents=parents)
