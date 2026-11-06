"""Atomic file writes: a reader sees the old file or the new one, never a part
of it, also after a crash. After a power cut too, as far as the disk keeps what a
sync asks of it.

``atomic_write`` writes a temporary file in the directory of the target, syncs
it, renames it over the target and syncs the directory, and the directories above
that it created. The target is replaced, so a symbolic link at the path becomes a
file, a reader that opened the old file keeps reading it, and the file belongs to
the user who writes it, whoever owned the file before. A writer that dies leaves
the old file and a temporary file named after its process; the next write of that
target removes it.
"""

from __future__ import annotations

import contextlib
import errno
import os
import stat
import sys

from dotsteward_cli import procs

TYPE_CHECKING = False
if TYPE_CHECKING:
    from typing import Any

DEFAULT_MODE = 0o644
# A file name has at most 255 bytes, and the temporary name adds to the target's.
_STEM_BYTES = 200


def _sync(descriptor: int) -> None:
    """Asks that what the file holds reaches the disk. On macOS fsync stops at the
    cache of the drive, so it asks for more where the file system knows how."""
    if sys.platform == "darwin":
        import fcntl

        try:
            fcntl.fcntl(descriptor, fcntl.F_FULLFSYNC)
        except OSError:
            pass
        else:
            return
    os.fsync(descriptor)


def _sync_directory(directory: str) -> None:
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except PermissionError:  # a directory that can be written but not read
        return
    try:
        _sync(descriptor)
    except OSError as error:
        # Some file systems cannot sync a directory; the rename has happened.
        if error.errno not in (errno.EINVAL, errno.ENOTSUP):
            raise
    finally:
        os.close(descriptor)


def _missing_directories(directory: str) -> list[str]:
    """DIRECTORY and its parents as far as they do not exist, the deepest first."""
    missing = []
    current = directory
    while not os.path.isdir(current) and current != os.path.dirname(current):
        missing.append(current)
        current = os.path.dirname(current)
    return missing


def _sync_new_names(created: list[str]) -> None:
    """A directory is as durable as its name in the directory above it."""
    for directory in created:
        _sync_directory(os.path.dirname(directory))


def make_private_dirs(path: str | os.PathLike[str]) -> None:
    """Creates the directory PATH with mode 0700. Missing parents follow the umask:
    a first command must not close ~/.local to everyone. The directories that exist
    stay as they are."""
    target = os.path.abspath(path)
    created = _missing_directories(target)
    if created:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with contextlib.suppress(FileExistsError):
            os.mkdir(target, 0o700)
        _sync_new_names(created)


def _remove_leftovers(directory: str, stem: str) -> None:
    """Removes the temporary files of the target with this STEM that dead writers
    left, as far as it can: a directory it cannot list is no reason to fail."""
    prefix = f".{stem}."
    with contextlib.suppress(OSError), os.scandir(directory) as entries:
        for entry in entries:
            if entry.name.startswith(prefix) and entry.name.endswith(".tmp"):
                pid, dot, random = entry.name[len(prefix) : -len(".tmp")].partition(".")
                if dot and "." not in random and pid.isdecimal() and not procs.process_exists(int(pid)):
                    os.unlink(entry.path)


def _create_temporary(directory: str, stem: str) -> tuple[int, str]:
    """A new private file in DIRECTORY, named after this process and this target."""
    while True:
        temporary = os.path.join(directory, f".{stem}.{os.getpid()}.{os.urandom(4).hex()}.tmp")
        try:
            return os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600), temporary
        except FileExistsError:
            continue


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
    created = []
    if parents:
        created = _missing_directories(directory)
        os.makedirs(directory, exist_ok=True)
    stem = os.fsdecode(os.fsencode(name)[:_STEM_BYTES])
    _remove_leftovers(directory, stem)
    descriptor, temporary = _create_temporary(directory, stem)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            _sync(stream.fileno())
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
    _sync_directory(directory)
    _sync_new_names(created)


def atomic_write_json(
    path: str | os.PathLike[str], value: Any, *, mode: int | None = None, parents: bool = False
) -> None:
    """Replaces the file at PATH with VALUE as indented JSON text and a final newline."""
    import json

    text = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    atomic_write(path, text.encode("utf-8", "backslashreplace"), mode=mode, parents=parents)
