"""Where a skill that is not tracked yet comes from.

    1  a record in ~/.agents/.skill-lock.json (`npx skills`)   downloaded   a question
    2  a clean clone with a remote: the directory is one, or
       a link from the skill root resolves into one            downloaded   a question
    3  a file tool of an agent wrote its SKILL.md or
       plugin.json; or an own plugin: `claude plugin init`
       made ~/.claude/skills/<name>/.claude-plugin/plugin.json,
       or ${CODEX_HOME:-~/.codex}/plugins/<name> holds one     own          tracked, no question
    4  anything else: a tree no file tool touched              unknown      a question

The evidence is the write itself, not what the tool reports about it, so an edit after
a generator such as Codex's skill creator counts. A record comes first: a stale one
costs one question and nothing else, and comparing its tree digest here would add work
to the path of a hook.

A clone is where the skill comes from only when it can say so for another machine: a
remote named origin that is https or ssh (a path of this machine is not), a commit HEAD
that holds the directory and that a remote branch of the clone holds too (no commit of its
own), and files that are exactly the tree of that commit in the normal form capture
publishes (an uncommitted change, an untracked file or one git ignores, such as an .env,
counts). The source is then that remote without any credentials, the HEAD and the
directory within the clone. A clone that falls short of that leaves the skill unknown, and
the detail says why; a directory with a .git of its own, or a link into a clone whose
upstream has the directory, stays so even when a file tool wrote into it. Only the
directory itself and the target of a link are looked at, never the directories above a
real one: a home that is a work tree would make every skill in it downloaded. A link into
any other work tree is judged like any other directory, so a new skill an agent writes
through a link into a repository of the user stays the user's.

Nothing a clone configures runs: git reads its objects and configuration with fsmonitor,
the untracked cache and hooks off, without optional locks and without the system
configuration (``git``), and the tree of a commit is written from its objects.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any, NamedTuple

if TYPE_CHECKING:
    import subprocess

OWN = "own"
DOWNLOADED = "downloaded"
UNKNOWN = "unknown"
PLUGIN_MANIFEST = os.path.join(".claude-plugin", "plugin.json")


def _skill_lock_record(name: str, home: str) -> dict[str, Any] | None:
    try:
        with open(os.path.join(home, ".agents", ".skill-lock.json"), encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return None
    skills = document.get("skills") if isinstance(document, dict) else None
    record = skills.get(name) if isinstance(skills, dict) else None
    return record if isinstance(record, dict) else None


class Origin(NamedTuple):
    """Where a candidate comes from, its source when it has one, and why it is unknown."""

    where: str
    source: dict[str, Any] | None
    detail: str | None = None


class Clone(NamedTuple):
    """A clone that holds a skill: its top, the directory of the skill in it ('' for the top),
    the remote origin as configured, the commit HEAD, and whether that commit holds the
    directory while the remote is one another machine can reach (the upstream has it)."""

    top: str
    directory: str
    url: str | None
    head: str | None
    held: bool


# The start of the detail of a clone whose files differ from its commit HEAD.
UNCOMMITTED = "it holds files the commit HEAD of its clone does not (uncommitted, untracked or ignored)"
# What git may run on behalf of a repository: nothing of a clone runs here.
SAFE_OPTIONS = (
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.untrackedCache=false",
    "-c",
    f"core.hooksPath={os.devnull}",
    "--no-optional-locks",
)
_SCP_LIKE = re.compile(r"^[A-Za-z0-9._~-]+@[A-Za-z0-9.-]+:(?!//)")
_NETWORK_SCHEMES = ("https://", "ssh://", "git+ssh://", "ssh+git://")
_SSH_SCHEMES = ("ssh", "git+ssh", "ssh+git")
_COMPARE_LIMIT_BYTES = 100 * 1024 * 1024


def safe_env() -> dict[str, str]:
    """The environment of git on a clone: no GIT_* of a caller, no system configuration."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"})
    return env


def git(path: str, *argv: str, data: bytes | None = None) -> subprocess.CompletedProcess[bytes] | None:
    """git ARGV in PATH with nothing the repository configures to run (fsmonitor, hooks)."""
    import subprocess

    try:
        return subprocess.run(
            ["git", *SAFE_OPTIONS, "-C", path, *argv],
            env=safe_env(),
            input=data,
            capture_output=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _git_output(path: str, *argv: str) -> str | None:
    result = git(path, *argv)
    if result is None or result.returncode != 0:
        return None
    return result.stdout.decode(errors="replace").strip() or None


def network_url(url: str) -> bool:
    """Whether another machine can fetch URL: https or ssh, not a path of this machine."""
    return url.lower().startswith(_NETWORK_SCHEMES) or _SCP_LIKE.match(url) is not None


def public_url(url: str) -> str:
    """URL without credentials: no userinfo of an https remote (a password may hold an @), only
    the user name of an ssh one, and no query or fragment (an access token)."""
    from urllib.parse import urlsplit, urlunsplit

    if "://" not in url:
        return url
    parts = urlsplit(url)
    userinfo, at, host = parts.netloc.rpartition("@")
    netloc = host
    if at and parts.scheme.lower() in _SSH_SCHEMES:
        netloc = f"{userinfo.partition(':')[0]}@{host}"
    return urlunsplit((parts.scheme, netloc, parts.path, "", ""))


def plain_url(url: str) -> str:
    """URL as the lock names an upstream, to compare two of them."""
    url = public_url(url.strip())
    for prefix in ("git@github.com:", "ssh://git@github.com/"):
        if url.startswith(prefix):
            url = "https://github.com/" + url[len(prefix) :]
    return url.rstrip("/").removesuffix(".git")


def clone_of(path: str) -> tuple[Clone | None, str | None]:
    """The clone that holds the skill at PATH (a link is followed): (clone, None) when it says
    where the skill comes from; (clone or None, why) when it cannot; (None, None) when no work
    tree holds it. Only objects and configuration are read: nothing of the clone runs."""
    real = os.path.realpath(path)
    top = _git_output(real, "rev-parse", "--show-toplevel")
    prefix = git(real, "rev-parse", "--show-prefix")
    if top is None or prefix is None or prefix.returncode != 0:
        return None, None
    directory = prefix.stdout.decode(errors="replace").strip().rstrip("/")
    url = _git_output(top, "config", "--get", "remote.origin.url")
    head = _git_output(top, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
    held = bool(
        url and network_url(url) and head and _git_output(top, "cat-file", "-t", f"{head}:{directory}") == "tree"
    )
    clone = Clone(top, directory, url, head, held)
    if url is None:
        return clone, "the clone it is in has no remote (origin), so no other machine can fetch it"
    if not network_url(url):
        return clone, "the remote (origin) of its clone is a path of this machine, which no other machine can fetch"
    if head is None:
        return clone, "the clone it is in has no commit yet"
    if not held:
        return clone, "its directory is not committed in the clone it is in"
    if _git_output(top, "for-each-ref", "--count=1", "--format=%(objectname)", "refs/remotes") is None:
        return clone, "the clone it is in knows no remote branch, so nothing shows its HEAD on the remote"
    if _git_output(top, "rev-list", "-n", "1", head, "--not", "--remotes") is not None:
        return clone, "the HEAD of its clone has a commit that no remote branch of the clone holds"
    return clone, None


def write_tree(clone: Clone, revision: str, destination: str) -> None:
    """The files of the directory of the skill at REVISION into DESTINATION, read as objects
    (no checkout, no attributes, no filters). ValueError when that tree cannot be written."""
    spec = f"{revision}:{clone.directory}" if clone.directory else f"{revision}^{{tree}}"
    listed = git(clone.top, "ls-tree", "-r", "-z", "-l", spec)
    if listed is None or listed.returncode != 0:
        raise ValueError(f"cannot read the tree {spec}")
    entries = []
    total = 0
    for line in listed.stdout.split(b"\0"):
        if not line:
            continue
        meta, _, raw_name = line.partition(b"\t")
        mode, kind, sha, length = meta.split()
        if kind != b"blob":
            raise ValueError(f"the tree holds a {kind.decode()} at {os.fsdecode(raw_name)}")
        total += int(length) if length.isdigit() else 0
        entries.append((mode, sha, os.fsdecode(raw_name)))
    if total > _COMPARE_LIMIT_BYTES:
        raise ValueError("the tree is too large to compare")
    os.makedirs(destination, exist_ok=True)
    batch = git(clone.top, "cat-file", "--batch", data=b"".join(sha + b"\n" for _, sha, _ in entries))
    if batch is None or batch.returncode != 0:
        raise ValueError("cannot read the objects of the tree")
    output = batch.stdout
    offset = 0
    for mode, _, name in entries:
        header_end = output.index(b"\n", offset)
        size = int(output[offset:header_end].split()[2])
        content = output[header_end + 1 : header_end + 1 + size]
        offset = header_end + 1 + size + 1
        target = os.path.join(destination, name)
        if os.path.relpath(target, destination).startswith(".."):
            raise ValueError(f"the tree names a path outside it: {name}")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if mode == b"120000":
            os.symlink(os.fsdecode(content), target)
            continue
        with open(target, "wb") as handle:
            handle.write(content)
        os.chmod(target, 0o755 if mode == b"100755" else 0o644)


def _differences(path: str, clone: Clone) -> list[str] | None:
    """The names in which the skill at PATH differs from the tree of HEAD of CLONE, in the
    normal form that capture publishes; None when the tree cannot be written."""
    import tempfile

    from dotsteward_cli.skills import normal

    with tempfile.TemporaryDirectory(prefix="dotsteward-upstream-") as scratch:
        tree = os.path.join(scratch, "tree")
        try:
            write_tree(clone, str(clone.head), tree)
            here = normal.normal_form(os.path.realpath(path))
            there = normal.normal_form(tree)
        except (ValueError, OSError, normal.NormalFormError, normal.TooLarge):
            return None
        if here.digest == there.digest:
            return []
        names = set(here.files) ^ set(there.files)
        for name in set(here.files) & set(there.files):
            if normal.file_sha256(here.files[name]) != normal.file_sha256(there.files[name]):
                names.add(name)
        names.update(os.fsencode(name) for name in set(here.unsafe) ^ set(there.unsafe))
        return sorted(os.fsdecode(name) for name in names) or ["(the file modes or links)"]


def git_source(path: str) -> tuple[dict[str, Any] | None, str | None, bool]:
    """The source of the skill at PATH when a clone holds it: (source, None, True); (None, why,
    held) when the clone cannot say where it comes from, HELD when its upstream has the
    directory all the same; (None, None, False) when no work tree holds it."""
    clone, detail = clone_of(path)
    if clone is None or detail is not None:
        return None, detail, bool(clone and clone.held)
    differences = _differences(path, clone)
    if differences is None:
        return None, "its clone cannot show the tree of its commit HEAD", True
    if differences:
        return None, f"{UNCOMMITTED}: {', '.join(differences[:5])}", True
    return {"url": public_url(str(clone.url)), "revision": clone.head, "path": clone.directory or None}, None, True


def follows(path: str, revision: str, upstream: str | None) -> str | None:
    """Whether the copy at PATH is the pinned upstream at another commit: 'ahead' when its clone
    holds exactly the tree of HEAD, every commit of it is on the remote, and HEAD descends from
    REVISION; 'other' when all that holds but the pin is ahead or elsewhere and the remote is
    UPSTREAM; None for anything else, which is drift."""
    clone, detail = clone_of(path)
    if clone is None or detail is not None or _differences(path, clone) != []:
        return None
    ancestor = git(clone.top, "merge-base", "--is-ancestor", revision, str(clone.head))
    if ancestor is not None and ancestor.returncode == 0:
        return "ahead"
    if upstream and clone.url and plain_url(clone.url) == plain_url(upstream):
        return "other"
    return None


def classify(name: str, path: str, evidence: Mapping[str, Any] | None) -> Origin:
    """The origin of the candidate NAME at PATH and its source, when it has one."""
    home = os.environ.get("HOME") or os.path.expanduser("~")
    record = _skill_lock_record(name, home)
    if record is not None:
        return Origin(
            DOWNLOADED,
            {
                "url": record.get("sourceUrl"),
                "revision": None,
                "path": record.get("skillPath"),
                "tree": record.get("skillFolderHash"),
            },
        )
    detail = None
    if os.path.exists(os.path.join(path, ".git")):
        # A clone of its own is somebody's download, whatever an agent wrote into it since.
        source, detail, _ = git_source(path)
        return Origin(DOWNLOADED, source) if source is not None else Origin(UNKNOWN, None, detail)
    if os.path.islink(path):
        source, detail, held = git_source(path)
        if source is not None:
            return Origin(DOWNLOADED, source)
        if held:
            # The upstream has this directory: an edit through the link does not make it yours.
            return Origin(UNKNOWN, None, detail)
    if evidence:
        return Origin(OWN, None)
    from dotsteward_cli.skills import plugins

    # `claude plugin init`, or the place the Codex documentation gives a personal plugin. A link
    # there says nothing about whose the plugin is.
    if plugins.is_own_plugin_dir(path) and not os.path.islink(path):
        return Origin(OWN, None)
    return Origin(UNKNOWN, None, detail)


def main(argv: list[str] | None = None) -> int:
    """``follows PATH REVISION [UPSTREAM]`` for ``agents install`` and ``check``: prints
    ``ahead``, ``other`` or nothing."""
    import sys

    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) in (3, 4) and arguments[0] == "follows":
        print(follows(arguments[1], arguments[2], arguments[3] if len(arguments) == 4 else None) or "")
        return 0
    print("usage: python -m dotsteward_cli.skills.origin follows PATH REVISION [UPSTREAM]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
