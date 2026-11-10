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
remote named origin, a commit that holds the directory, and no change to the directory
the commit does not have (an untracked file counts). The source is then that remote
(without any credentials in it), the HEAD and the directory within the clone. A clone
that falls short of that leaves the skill unknown, and the detail says why; a directory
with a .git of its own stays so even when a file tool wrote into it. Only the directory
itself and the target of a link are looked at, never the directories above a real one: a
home that is a work tree would make every skill in it downloaded. A link into a clone that
has a remote and whose HEAD holds the directory stays unknown while it has changes, also
after a file tool wrote into it; a link into any other work tree (no remote, no commit, the
directory not committed) is judged like any other directory, so a new skill an agent
writes through a link into a repository of the user stays the user's.
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


# A clone with a remote whose HEAD holds the directory, changed since: a download all the same.
UNCOMMITTED = "it has uncommitted changes in the clone it is in, which no commit of the remote holds"
_USERINFO = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@")


def _git(path: str, *argv: str) -> subprocess.CompletedProcess[str] | None:
    import subprocess

    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        return subprocess.run(
            ["git", "-C", path, *argv], env=env, capture_output=True, text=True, check=False, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _git_output(path: str, *argv: str) -> str | None:
    result = _git(path, *argv)
    if result is None or result.returncode != 0:
        return None
    return result.stdout.strip() or None


def public_url(url: str) -> str:
    """URL without the credentials an https remote may carry; an ssh user stays."""
    match = _USERINFO.match(url)
    if match is None or match.group(1).lower().startswith("ssh"):
        return url
    return match.group(1) + url[match.end() :]


def git_source(path: str) -> tuple[dict[str, Any] | None, str | None]:
    """The source of the skill at PATH (a link is followed) when a clone holds it: (source,
    None); (None, why) when the clone cannot say where it comes from; (None, None) when no
    work tree holds it."""
    real = os.path.realpath(path)
    prefix = _git(real, "rev-parse", "--show-prefix")
    if prefix is None or prefix.returncode != 0:
        return None, None
    directory = prefix.stdout.strip().rstrip("/")
    url = _git_output(real, "config", "--get", "remote.origin.url")
    if url is None:
        return None, "the clone it is in has no remote (origin), so no other machine can fetch it"
    head = _git_output(real, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
    if head is None:
        return None, "the clone it is in has no commit yet"
    if _git_output(real, "rev-parse", "--verify", "--quiet", f"HEAD:{directory}") is None:
        return None, "its directory is not committed in the clone it is in"
    changed = _git(real, "status", "--porcelain", "--untracked-files=all", "--", ".")
    if changed is None or changed.returncode != 0:
        return None, "git cannot read the state of the clone it is in"
    if changed.stdout.strip():
        return None, UNCOMMITTED
    return {"url": public_url(url), "revision": head, "path": directory or None}, None


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
        source, detail = git_source(path)
        return Origin(DOWNLOADED, source) if source is not None else Origin(UNKNOWN, None, detail)
    if os.path.islink(path):
        source, detail = git_source(path)
        if source is not None:
            return Origin(DOWNLOADED, source)
        if detail == UNCOMMITTED:
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
