"""Where a skill that is not tracked yet comes from.

    1  a record in ~/.agents/.skill-lock.json (`npx skills`)   downloaded   a question
    2  a .git directory                                        downloaded   a question
    3  a file tool of an agent wrote its SKILL.md or
       plugin.json; or an own plugin: `claude plugin init`
       made ~/.claude/skills/<name>/.claude-plugin/plugin.json,
       or ${CODEX_HOME:-~/.codex}/plugins/<name> holds one     own          tracked, no question
    4  anything else: a tree no file tool touched              unknown      a question

The evidence is the write itself, not what the tool reports about it, so an edit after
a generator such as Codex's skill creator counts. A record comes first: a stale one
costs one question and nothing else, and comparing its tree digest here would add work
to the path of a hook.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from typing import Any

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


def _git_output(path: str, *argv: str) -> str | None:
    import subprocess

    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        result = subprocess.run(
            ["git", "-C", path, *argv], env=env, capture_output=True, text=True, check=False, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def git_source(path: str) -> dict[str, Any]:
    return {
        "url": _git_output(path, "remote", "get-url", "origin"),
        "revision": _git_output(path, "rev-parse", "HEAD"),
        "path": None,
    }


def classify(name: str, path: str, evidence: Mapping[str, Any] | None) -> tuple[str, dict[str, Any] | None]:
    """The origin of the candidate NAME at PATH and its source, when it has one."""
    home = os.environ.get("HOME") or os.path.expanduser("~")
    record = _skill_lock_record(name, home)
    if record is not None:
        return DOWNLOADED, {
            "url": record.get("sourceUrl"),
            "revision": None,
            "path": record.get("skillPath"),
            "tree": record.get("skillFolderHash"),
        }
    if os.path.exists(os.path.join(path, ".git")):
        return DOWNLOADED, git_source(path)
    if evidence:
        return OWN, None
    from dotsteward_cli.skills import plugins

    # `claude plugin init`, or the place the Codex documentation gives a personal plugin.
    if plugins.is_own_plugin_dir(path):
        return OWN, None
    return UNKNOWN, None
