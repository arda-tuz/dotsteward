"""The normal form of a skill: what a copy of it carries and its digest.

The list comes from git, so the skill's own ``.gitignore`` files and the one of the
instance count as they would for the repository::

    git --git-dir=<empty> --work-tree=<dir> -c core.excludesFile=<instance>/.gitignore \\
      ls-files -z --others --exclude-standard

Left out besides: the directories ``.git``, ``__pycache__`` and ``__pypackages__``,
the files ``*.pyc`` and ``metadata.json``, as in the native copy of
``cli/lib/skills.sh``. A link inside the tree counts as what it points to. A link
out of the tree or a broken one is *unsafe*: it cannot be copied, and it changes the
digest, so that it is not taken for "nothing changed". What ignore rules hold back
is *dropped* and gets reported: a ``.gitignore`` line such as ``state/`` must not
carry a skill incomplete without a word.

``digest`` is byte-compatible with ``directory_sha256`` of ``cli/lib/lib.sh`` and
``dotsteward_pins.digest`` (the SHA-256 of the ``sha256sum`` lines of the files,
sorted by the bytes of ``./<path>``), so the digest of a normal form equals the lock
digest of the copy in the repository. It lives here because ``dotsteward_cli`` is the
base of the engines and imports neither of them (docs/python.md).
"""

from __future__ import annotations

import contextlib
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass

EXCLUDED_DIRECTORIES = frozenset({b".git", b"__pycache__", b"__pypackages__"})
EXCLUDED_NAME = b"metadata.json"
_CHUNK = 1 << 20
LARGEST_FILE_BYTES = 50 * 1024 * 1024


class NormalFormError(RuntimeError):
    """The list of a skill cannot be read (no git, an unreadable directory)."""


class TooLarge(Exception):
    """The files of a skill are above the limit; nothing was read. MARKER stands for its
    content: it changes with the names, sizes and times of the files."""

    def __init__(self, marker: str) -> None:
        super().__init__(marker)
        self.marker = marker


@dataclass(frozen=True)
class NormalForm:
    """FILES maps each relative name to the path to read; DROPPED and UNSAFE hold
    relative names, sorted; DIGEST is the digest of the normal form."""

    files: Mapping[bytes, str]
    dropped: list[str]
    unsafe: list[str]
    digest: str


def _excluded(relative: bytes) -> bool:
    parts = relative.split(b"/")
    name = parts[-1]
    return name == EXCLUDED_NAME or name.endswith(b".pyc") or any(part in EXCLUDED_DIRECTORIES for part in parts)


def _clean_env() -> dict[str, str]:
    """The environment of git: a hook may run inside another repository's hook, and
    no configuration of the user may change the list."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, LC_ALL="C")
    return env


def _git_list(directory: str, excludes_file: str | None, *flags: str) -> list[bytes]:
    with tempfile.TemporaryDirectory(prefix="dotsteward-skill-") as empty:
        os.mkdir(os.path.join(empty, "objects"))
        os.mkdir(os.path.join(empty, "refs"))
        with open(os.path.join(empty, "HEAD"), "w", encoding="ascii") as head:
            head.write("ref: refs/heads/main\n")
        argv = [
            "git",
            f"--git-dir={empty}",
            f"--work-tree={directory}",
            "-c",
            f"core.excludesFile={excludes_file or os.devnull}",
            "ls-files",
            "-z",
            "--others",
            "--exclude-standard",
            *flags,
        ]
        try:
            result = subprocess.run(argv, cwd=directory, env=_clean_env(), capture_output=True, check=False)
        except OSError as error:
            raise NormalFormError(f"cannot run git: {error.strerror}") from error
    if result.returncode != 0:
        raise NormalFormError(result.stderr.decode(errors="replace").strip() or f"git exited {result.returncode}")
    return [name for name in result.stdout.split(b"\0") if name]


def _walk(root: bytes, real_root: bytes, relative: bytes, seen: set[bytes]) -> Iterator[tuple[bytes, bytes | None]]:
    """Yields (relative name, path to read) below the directory RELATIVE, following
    links inside the tree; the path is None for an unsafe link."""
    current = os.path.join(root, relative) if relative else root
    real = os.path.realpath(current)
    if real in seen:
        return
    seen = seen | {real}
    try:
        children = sorted(os.scandir(current), key=lambda item: item.name)
    except OSError:
        # What nobody may read cannot be copied, and takes no other skill down with it.
        yield relative, None
        return
    for entry in children:
        child = os.path.join(relative, entry.name) if relative else entry.name
        if _excluded(child):
            continue
        yield from _resolve(root, real_root, child, seen)


def _resolve(root: bytes, real_root: bytes, relative: bytes, seen: set[bytes]) -> Iterator[tuple[bytes, bytes | None]]:
    path = os.path.join(root, relative)
    try:
        mode = os.lstat(path).st_mode
    except OSError:
        return
    if stat.S_ISLNK(mode):
        target = os.path.realpath(path)
        inside = target == real_root or target.startswith(real_root + b"/")
        if not inside or not os.path.exists(target):
            yield relative, None
        elif os.path.isdir(target):
            yield from _walk(root, real_root, relative, seen)
        elif os.path.isfile(target):
            yield relative, target
    elif stat.S_ISDIR(mode):
        yield from _walk(root, real_root, relative, seen)
    elif stat.S_ISREG(mode):
        yield relative, path


def _sum_line(hexdigest: str, name: bytes) -> bytes:
    if b"\\" in name or b"\n" in name or b"\r" in name:
        escaped = name.replace(b"\\", b"\\\\").replace(b"\n", b"\\n").replace(b"\r", b"\\r")
        return b"\\" + hexdigest.encode() + b"  " + escaped + b"\n"
    return hexdigest.encode() + b"  " + name + b"\n"


def file_sha256(path: str | bytes) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(_CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def _copy_entry(source: str, target: str) -> None:
    """SOURCE, a file, a link or a tree, at TARGET, with its parents as they are at SOURCE."""
    if os.path.isdir(source) and not os.path.islink(source):
        shutil.copytree(source, target, symlinks=True)
    else:
        shutil.copy2(source, target, follow_symlinks=False)


def keep_left_out(directory: str, excludes_file: str | None, keep: str) -> None:
    """Copies to the directory KEEP what the normal form of DIRECTORY leaves out and what a
    copy of the repository cannot bring back: what ignore rules drop, and the ``.git`` of a
    clone. Caches can go."""
    names = [name.rstrip(b"/") for name in _lists(directory, excludes_file)[1] if not _excluded(name.rstrip(b"/"))]
    if os.path.lexists(os.path.join(directory, ".git")):
        names.append(b".git")
    for name in names:
        relative = os.fsdecode(name)
        source = os.path.join(directory, relative)
        parent = ""
        for part in os.path.dirname(relative).split("/"):
            parent = os.path.join(parent, part) if part else parent
            if parent and not os.path.isdir(os.path.join(keep, parent)):
                os.mkdir(os.path.join(keep, parent))
                shutil.copystat(os.path.join(directory, parent), os.path.join(keep, parent))
        with contextlib.suppress(FileNotFoundError):
            _copy_entry(source, os.path.join(keep, relative))


def restore_left_out(keep: str, directory: str, excludes_file: str | None) -> list[str]:
    """Puts what ``keep_left_out`` kept back into DIRECTORY; what the new copy holds wins.
    Only what a rule of the new copy still leaves out comes back: anything else would be
    content of the skill from now on, and would be published. Returns those names."""
    restored: list[str] = []
    for current, directories, files in os.walk(keep):
        relative = os.path.relpath(current, keep)
        for name in list(directories) + files:
            source = os.path.join(current, name)
            target = os.path.normpath(os.path.join(directory, relative, name))
            if os.path.isdir(source) and not os.path.islink(source):
                if not os.path.lexists(target):
                    os.mkdir(target)
                    shutil.copystat(source, target)
            elif not os.path.lexists(target):
                _copy_entry(source, target)
                restored.append(os.path.normpath(os.path.join(relative, name)))
    listed = {os.fsdecode(name.rstrip(b"/")) for name in _lists(directory, excludes_file)[0]}
    uncovered = sorted(name for name in restored if name in listed)
    for name in uncovered:
        os.unlink(os.path.join(directory, name))
    for current, directories, files in os.walk(directory, topdown=False):
        if not directories and not files and current != directory:
            with contextlib.suppress(OSError):
                os.rmdir(current)
    return uncovered


def ignored_by(rules: bytes, names: Iterable[str]) -> list[str]:
    """Which of the relative NAMES the text RULES of a ``.gitignore`` leaves out."""
    given = [os.fsencode(name) for name in names]
    if not rules.strip() or not given:
        return []
    with tempfile.TemporaryDirectory(prefix="dotsteward-skill-") as empty:
        git_dir = os.path.join(empty, "git")
        os.makedirs(os.path.join(git_dir, "objects"))
        os.mkdir(os.path.join(git_dir, "refs"))
        with open(os.path.join(git_dir, "HEAD"), "w", encoding="ascii") as head:
            head.write("ref: refs/heads/main\n")
        work_tree = os.path.join(empty, "tree")
        os.mkdir(work_tree)
        with open(os.path.join(work_tree, ".gitignore"), "wb") as handle:
            handle.write(rules)
        result = subprocess.run(
            ["git", f"--git-dir={git_dir}", f"--work-tree={work_tree}", "check-ignore", "--no-index", "-z", "--stdin"],
            cwd=work_tree,
            env=_clean_env(),
            input=b"\0".join(given) + b"\0",
            capture_output=True,
            check=False,
        )
    if result.returncode not in (0, 1):
        raise NormalFormError(result.stderr.decode(errors="replace").strip() or "git check-ignore failed")
    return sorted(os.fsdecode(name) for name in result.stdout.split(b"\0") if name)


def plain_digest(directory: str) -> str:
    """``directory_sha256`` of lib.sh for a tree that holds what it holds: the regular
    files below DIRECTORY without ``__pycache__`` and ``*.pyc``, no link followed."""
    root = os.fsencode(directory)
    names: list[bytes] = []
    pending = [b""]
    while pending:
        relative = pending.pop()
        with os.scandir(os.path.join(root, relative) if relative else root) as entries:
            for entry in entries:
                child = os.path.join(relative, entry.name) if relative else entry.name
                mode = entry.stat(follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    if entry.name != b"__pycache__":
                        pending.append(child)
                elif stat.S_ISREG(mode) and not entry.name.endswith(b".pyc"):
                    names.append(child)
    outer = hashlib.sha256()
    for relative in sorted(names, key=lambda name: b"./" + name):
        outer.update(_sum_line(file_sha256(os.path.join(root, relative)), b"./" + relative))
    return outer.hexdigest()


_PLUGIN_MANIFESTS = (
    os.path.join(".claude-plugin", "plugin.json"),
    os.path.join(".codex-plugin", "plugin.json"),
    "plugin.json",
)
_REPOSITORY_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR")


def _repository_list(directory: str) -> set[bytes] | None:
    """What git itself lists in a plugin that is a repository of the user: tracked files and
    files no ignore source of git (its .gitignore files, .git/info/exclude, the global excludes
    file) ignores. None for anything else: a skill keeps the list of the rules above."""
    if not os.path.exists(os.path.join(directory, ".git")):
        return None
    if not any(os.path.isfile(os.path.join(directory, manifest)) for manifest in _PLUGIN_MANIFESTS):
        return None
    from dotsteward_cli.skills import origin

    env = {key: value for key, value in os.environ.items() if key not in _REPOSITORY_VARIABLES}
    env["LC_ALL"] = "C"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    # Nothing the repository configures runs (fsmonitor, hooks).
    argv = [
        "git",
        *origin.SAFE_OPTIONS,
        "-C",
        directory,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
    ]
    try:
        result = subprocess.run(argv, env=env, capture_output=True, check=False)
    except OSError as error:
        raise NormalFormError(f"cannot run git: {error.strerror}") from error
    if result.returncode != 0:
        raise NormalFormError(result.stderr.decode(errors="replace").strip() or f"git exited {result.returncode}")
    return {name for name in result.stdout.split(b"\0") if name}


def _lists(directory: str, excludes_file: str | None, top: bool = True) -> tuple[list[bytes], list[bytes]]:
    """The names of the normal form below DIRECTORY and the names ignore rules drop. A
    nested clone comes as one entry from git and has ignore rules of its own; a plugin that
    is a repository also keeps out what git ignores there (``_repository_list``)."""
    listed: list[bytes] = []
    ignored = _git_list(directory, excludes_file, "--ignored")
    for entry in _git_list(directory, excludes_file):
        nested = entry.rstrip(b"/")
        if entry.endswith(b"/") and not _excluded(nested):
            inner_listed, inner_ignored = _lists(os.path.join(directory, os.fsdecode(nested)), excludes_file, False)
            listed += [os.path.join(nested, name) for name in inner_listed]
            ignored += [os.path.join(nested, name) for name in inner_ignored]
        else:
            listed.append(entry)
    own = _repository_list(directory) if top else None
    if own is not None:
        ignored += [name for name in listed if name not in own and not name.endswith(b"/")]
        listed = [name for name in listed if name in own or name.endswith(b"/")]
    return listed, ignored


def _above_limit(found: Mapping[bytes, bytes | None], limit_bytes: int) -> str | None:
    """The marker of TooLarge when the files of FOUND are above the limit."""
    total = 0
    largest = 0
    marker = hashlib.sha256()
    for relative in sorted(found):
        target = found[relative]
        if target is None:
            continue
        try:
            status = os.stat(target)
        except OSError:
            continue
        total += status.st_size
        largest = max(largest, status.st_size)
        marker.update(b"%s %d %d\n" % (relative, status.st_size, status.st_mtime_ns))
    return marker.hexdigest() if total > limit_bytes or largest > LARGEST_FILE_BYTES else None


def normal_form(directory: str, excludes_file: str | None = None, limit_bytes: int | None = None) -> NormalForm:
    """The normal form of the skill in DIRECTORY (a real path); EXCLUDES_FILE is the
    ``.gitignore`` of the instance. NormalFormError when the list cannot be read; TooLarge,
    with LIMIT_BYTES, before any file is read."""
    root = os.fsencode(directory)
    real_root = os.path.realpath(root)
    listed, ignored = _lists(directory, excludes_file)
    found: dict[bytes, bytes | None] = {}
    for entry in listed:
        relative = entry.rstrip(b"/")
        if not _excluded(relative):
            found.update(_resolve(root, real_root, relative, {real_root}))
    if limit_bytes is not None:
        marker = _above_limit(found, limit_bytes)
        if marker is not None:
            raise TooLarge(marker)
    dropped = sorted(os.fsdecode(name) for name in ignored if not _excluded(name.rstrip(b"/")))

    files: dict[bytes, str] = {}
    unsafe: list[str] = []
    outer = hashlib.sha256()
    for relative in sorted(found, key=lambda name: b"./" + name):
        target = found[relative]
        name = b"./" + relative
        if target is None:
            unsafe.append(os.fsdecode(relative))
            try:
                text = os.readlink(os.path.join(root, relative))
            except OSError:
                text = b"unreadable"
            outer.update(_sum_line(hashlib.sha256(b"unsafe-link:" + text).hexdigest(), name))
            continue
        try:
            sum_hex = file_sha256(target)
        except OSError:
            unsafe.append(os.fsdecode(relative))
            outer.update(_sum_line(hashlib.sha256(b"unreadable").hexdigest(), name))
            continue
        files[relative] = os.fsdecode(target)
        outer.update(_sum_line(sum_hex, name))
    return NormalForm(files, dropped, sorted(unsafe), outer.hexdigest())
