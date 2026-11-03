#!/usr/bin/env python3
"""Shadowed skills: the warnings of the opencode-pi agents checks.

Usage: skill-shadows.py AGENT HOME SCOPED_STORE EXPECTED_JSON

AGENT (opencode or pi) reads its skills from several roots and lists a name
that more than one SKILL.md carries once, from one of those files; OpenCode
loads its roots concurrently, so the file it lists can change from run to
run. A shadow is a SKILL.md in a root of AGENT whose name (the frontmatter
name, unquoted, else the directory name) is one of EXPECTED_JSON (a JSON
array of skill names) and which is not a copy dotsteward installed: it does
not resolve to a SKILL.md below HOME/.agents/skills outside .system or below
SCOPED_STORE. For every shadow, in every run and whatever the agent lists,
one "[dotsteward] WARNING: ..." line on standard error names it together
with the installed SKILL.md of that name (and says when both files are
identical), or says that dotsteward installed none; a file reached through
several paths is named once.

The roots: opencode reads HOME/.agents/skills, HOME/.claude/skills and
${XDG_CONFIG_HOME:-HOME/.config}/opencode/skills at any depth, hidden
directories and directory links included (each resolved directory once); pi
reads the skill directories directly below HOME/.agents/skills and
HOME/.pi/agent/skills, hidden ones skipped.

Exit 0 (warnings only), 2 on a usage error.
"""

from __future__ import annotations

import json
import os
import sys

LABELS = {"opencode": "OpenCode", "pi": "Pi"}


def skill_files(root: str, deep: bool, skip_system: bool = False) -> list[str]:
    """The SKILL.md paths below ROOT as an agent finds them (the path through
    directory links, not the resolved one), sorted. DEEP walks every depth,
    hidden directories included, each resolved directory once (link cycles
    end), except .system subtrees with SKIP_SYSTEM; otherwise only the
    directories directly below ROOT that are not hidden."""
    found: list[str] = []
    if not os.path.isdir(root):
        return found
    if not deep:
        for entry in sorted(os.listdir(root)):
            path = os.path.join(root, entry, "SKILL.md")
            if not entry.startswith(".") and os.path.isfile(path):
                found.append(path)
        return found
    seen: set[str] = set()
    for directory, subdirectories, files in os.walk(root, followlinks=True):
        real = os.path.realpath(directory)
        if real in seen:
            subdirectories[:] = []
            continue
        seen.add(real)
        subdirectories[:] = sorted(name for name in subdirectories if not (skip_system and name == ".system"))
        if "SKILL.md" in files:
            found.append(os.path.join(directory, "SKILL.md"))
    return sorted(found)


def skill_name(path: str) -> str:
    """The name an agent lists for the SKILL.md at PATH: the frontmatter name
    (a quoted YAML scalar unquoted), else the name of its directory."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        lines = []
    if lines and lines[0].strip() == "---":
        for line in lines[1:]:
            if line.strip() == "---":
                break
            key, sep, value = line.partition(":")
            if sep and key.strip() == "name":
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if value:
                    return value
                break
    return os.path.basename(os.path.dirname(path))


def same_bytes(first: str, second: str) -> bool:
    try:
        with open(first, "rb") as one, open(second, "rb") as two:
            return one.read() == two.read()
    except OSError:
        return False


def shadows(agent: str, home: str, store: str, expected: set[str]) -> list[str]:
    """The warning messages of the shadows of AGENT, sorted by name and path."""
    canonical = os.path.join(home, ".agents", "skills")
    installed: set[str] = set()
    installed_path: dict[str, str] = {}
    for root, skip_system in ((canonical, True), (store, False)):
        for path in skill_files(root, deep=True, skip_system=skip_system):
            installed.add(os.path.realpath(path))
            installed_path.setdefault(skill_name(path), path)
    if agent == "opencode":
        config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
        roots = [
            (canonical, True),
            (os.path.join(home, ".claude", "skills"), True),
            (os.path.join(config, "opencode", "skills"), True),
        ]
        choice = ", and lists one of them, chosen anew in every run"
    else:
        roots = [(canonical, False), (os.path.join(home, ".pi", "agent", "skills"), False)]
        choice = ", and lists one of them"
    label = LABELS[agent]
    found: list[tuple[str, str]] = []
    reported: set[str] = set()
    for root, deep in roots:
        for path in skill_files(root, deep):
            real = os.path.realpath(path)
            if real in installed or real in reported:
                continue
            name = skill_name(path)
            if name not in expected:
                continue
            reported.add(real)
            found.append((name, path))
    messages = []
    for name, path in sorted(found):
        prefix = f"opencode-pi: {label} finds the skill {name}"
        other = installed_path.get(name)
        if other is None:
            messages.append(f"{prefix} only in {path}, which dotsteward did not install")
            continue
        message = f"{prefix} twice, in {other} (installed by dotsteward) and in {path}{choice}"
        if same_bytes(other, path):
            message += "; the two files are identical"
        messages.append(message)
    return messages


def main(argv: list[str]) -> int:
    if len(argv) != 5 or argv[1] not in LABELS:
        print("usage: skill-shadows.py opencode|pi HOME SCOPED_STORE EXPECTED_JSON", file=sys.stderr)
        return 2
    try:
        names = json.loads(argv[4])
    except ValueError:
        names = None
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        print("skill-shadows.py: EXPECTED_JSON is not a JSON array of names", file=sys.stderr)
        return 2
    for message in shadows(argv[1], argv[2], argv[3], set(names)):
        print(f"[dotsteward] WARNING: {message}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
