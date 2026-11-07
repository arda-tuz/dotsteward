"""Who writes what in an instance shared by several machines (docs/machines.md, "Who writes what").

A value is either a function of the tree, which every machine computes the same way, or a function
of upstream and time, which two machines would answer differently. The second kind has one writer,
the producer (``[hosts] producer``). ``check`` holds a candidate tree to that against its base:

- on a machine that is not the producer, a value the base has in ``versions.lock.json``,
  ``flake.lock`` or the producer tables of the skill lock does not change or go: a new key is free
  (the first pin of a new component), and so is ``generated_at``;
- an entry of the skill lock that is not the instance's own keeps every field but ``machines`` and
  its files stay as they are, unless it becomes the instance's own (``skills track --own``) or goes
  (``skills forget``); a new entry is free;
- the files only the producer writes (``package-lock.json`` of ``packages/``, hashed requirements,
  ``bootstrap.sh``, ``.dotsteward/cli.sh``) do not change if the base has them;
- on every named machine, ``hosts/<other>.toml`` does not change, except that the rename of this
  machine removes its old file.

Nothing is guarded on a machine without a name or when the base names no producer: one machine,
as every instance was before. The producer of the base decides, so a commit that names another
producer moves no pin. ``gate`` checks every scope before its memo; ``skills capture`` checks its
commit.

Command line::

    python3 -m dotsteward_cli.writers check --instance ROOT --base OID --tree OID [--scope S]

prints one ``writer-class: PATH: WHY`` error line for each finding and exits 1, else 0.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from collections.abc import Collection, Iterator, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from dotsteward_cli import config, machine, tomlfile
from dotsteward_cli import publish as publishing
from dotsteward_cli.skills import state as skill_state

CODE = "writer-class"
SCOPES = ("maintain", "update", "skill")
# Free on every machine: the time a writer last ran.
_FREE_KEYS = {"generated_at"}
# What only the producer writes, whole files that the base has.
_PRODUCER_FILES = ("bootstrap.sh", ".dotsteward/cli.sh")
_PRODUCER_GLOBS = ("packages/*/package-lock.json",)
_REQUIREMENTS = "requirements*.txt"
# The parts of the skill lock that are not about the producer: the entries, by name, and the
# plugins of the instance.
_LOCK_ENTRIES = {"skills", "own_plugins"}
_FREE_ENTRY_FIELDS = {"machines"}


@dataclass(frozen=True)
class Finding:
    path: str
    why: str

    def line(self) -> str:
        return f"{CODE}: {self.path}: {self.why}"


class _Trees:
    """The files of the base and of the candidate."""

    def __init__(self, root: Path, base: str, tree: str) -> None:
        self.root = root
        self.base = base
        self.tree = tree

    def _show(self, revision: str, path: str) -> str | None:
        shown = publishing.git(self.root, "show", f"{revision}:{path}")
        return shown.stdout if shown.code == 0 else None

    def before(self, path: str) -> str | None:
        return self._show(self.base, path)

    def after(self, path: str) -> str | None:
        return self._show(self.tree, path)

    def changed(self) -> list[tuple[str, str]]:
        """(status, path) of every path the candidate changes, renames as a delete and an add."""
        listed = publishing.git(self.root, "diff", "--name-status", "--no-renames", "-z", self.base, self.tree).stdout
        words = listed.split("\0")
        return [(words[index], words[index + 1]) for index in range(0, len(words) - 1, 2)]


def _json(text: str | None) -> Any:
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def _leaves(value: Any, prefix: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], Any]]:
    """Every value of a JSON document that is not an object, by its path of keys. An empty object
    holds none: its first key is new."""
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from _leaves(inner, (*prefix, str(key)))
    else:
        yield prefix, value


def _at(document: Any, keys: Sequence[str]) -> tuple[bool, Any]:
    for key in keys:
        if not isinstance(document, dict) or key not in document:
            return False, None
        document = document[key]
    return True, document


def _kept_values(before: Any, after: Any, skip: set[str]) -> list[str]:
    """The paths of the values of BEFORE that AFTER changes or drops; top-level keys in SKIP are
    free. A new key is no change."""
    moved = []
    for keys, value in _leaves(before):
        if not keys or keys[0] in skip:
            continue
        present, now = _at(after, keys)
        if not present or now != value:
            moved.append(".".join(keys))
    return moved


def _pin_file(trees: _Trees, path: str, skip: set[str]) -> list[Finding]:
    before = _json(trees.before(path))
    if before is None:
        return []
    after = _json(trees.after(path))
    if after is None:
        return [Finding(path, "only the producer removes it or makes it unreadable")]
    moved = _kept_values(before, after, skip)
    if not moved:
        return []
    shown = ", ".join(moved[:5]) + (f" and {len(moved) - 5} more" if len(moved) > 5 else "")
    return [Finding(path, f"only the producer moves a pin the base has: {shown}")]


def _skill_lock(trees: _Trees, changed: Sequence[str], lock: str, vendor: str, own: set[str]) -> list[Finding]:
    before = _json(trees.before(lock))
    if not isinstance(before, dict):
        return []
    after = _json(trees.after(lock))
    if not isinstance(after, dict):
        return [Finding(lock, "only the producer removes it or makes it unreadable")]
    findings = _pin_file(trees, lock, _FREE_KEYS | _LOCK_ENTRIES)
    now = {str(entry.get("name")): entry for entry in after.get("skills") or () if isinstance(entry, dict)}
    for entry in before.get("skills") or ():
        if not isinstance(entry, dict) or entry.get("revision") in own:
            continue
        name = str(entry.get("name"))
        current = now.get(name)
        if current is None or current.get("revision") in own:
            # skills forget, or skills track --own: the instance's own now, or nothing.
            continue
        fields = sorted(
            key
            for key in set(entry) | set(current)
            if key not in _FREE_ENTRY_FIELDS and entry.get(key) != current.get(key)
        )
        if fields:
            findings.append(Finding(lock, f"only the producer moves the third-party skill {name}: {', '.join(fields)}"))
        directory = os.path.join(vendor, str(current.get("directory") or name))
        findings += [
            Finding(
                path,
                f"only the producer changes the files of the third-party skill {name}; "
                "skills track --own makes it this instance's own",
            )
            for path in changed
            if path.startswith(f"{directory}/")
        ]
    return findings


def _hosts(trees: _Trees, changed: Sequence[tuple[str, str]], name: str) -> list[Finding]:
    own = f"{machine.HOSTS_DIR}/{name}.toml"
    renamed = trees.before(own) is None and trees.after(own) is not None
    findings = []
    for status, path in changed:
        if not path.startswith(f"{machine.HOSTS_DIR}/") or path == own:
            continue
        if status == "D" and renamed:
            # host rename: the old file of this machine goes as its new one comes.
            continue
        findings.append(Finding(path, "only the machine of a host file writes it"))
    return findings


def _producer_files(trees: _Trees, changed: Sequence[tuple[str, str]]) -> list[Finding]:
    findings = []
    for status, path in changed:
        if status == "A":
            continue
        name = path.rsplit("/", 1)[-1]
        if (
            path in _PRODUCER_FILES
            or any(fnmatch.fnmatchcase(path, pattern) for pattern in _PRODUCER_GLOBS)
            or (fnmatch.fnmatchcase(name, _REQUIREMENTS) and "--hash=" in (trees.before(path) or ""))
        ):
            findings.append(Finding(path, "only the producer writes it"))
    return findings


def producer_of(root: Path, base: str) -> str | None:
    """``[hosts] producer`` of the tree of BASE."""
    shown = publishing.git(root, "show", f"{base}:{config.CONFIG_FILE}")
    if shown.code != 0:
        return None
    try:
        document = tomlfile.loads(shown.stdout)
    except tomlfile.TomlError:
        return None
    hosts = document.get("hosts")
    producer = hosts.get("producer") if isinstance(hosts, dict) else None
    return producer if isinstance(producer, str) and producer else None


def check(
    instance: config.Instance, base: str, tree: str, name: str | None, producer: str | None, scope: str
) -> list[Finding]:
    """What TREE changes against BASE that the machine NAME does not write, in SCOPE (every scope
    has the same classes). Nothing without a name or a producer."""
    return check_tree(
        instance.root,
        base,
        tree,
        name=name,
        producer=producer,
        scope=scope,
        lock=str(instance.config["skills"]["lock"]),
        vendor=str(instance.config["skills"]["vendor_dir"]),
        own=own_revisions(instance),
    )


def own_revisions(instance: config.Instance) -> set[str]:
    """The revisions that mark a skill of the lock as the instance's own (as skills.commands says;
    that module imports the capture, which imports this one)."""
    revisions = {skill_state.REPO_OWNED_REVISION}
    extra = instance.config.get("compat", {}).get("repo_owned_revision")
    if isinstance(extra, str) and extra:
        revisions.add(extra)
    return revisions


def check_tree(
    root: Path,
    base: str,
    tree: str,
    *,
    name: str | None,
    producer: str | None,
    scope: str,
    lock: str,
    vendor: str,
    own: Collection[str],
) -> list[Finding]:
    """``check`` for the repository ROOT, with the paths of the skill lock and of the vendored
    skills and the revisions that mark a skill as the instance's own."""
    if scope not in SCOPES:
        raise ValueError(f"unknown scope: {scope}")
    if not name or not producer:
        return []
    trees = _Trees(root, base, tree)
    changed = trees.changed()
    findings = _hosts(trees, changed, name)
    if name == producer:
        return findings
    paths = {path for _, path in changed}
    for path in ("versions.lock.json", "flake.lock"):
        if path in paths:
            findings += _pin_file(trees, path, _FREE_KEYS)
    if lock in paths or any(path.startswith(f"{vendor}/") for path in paths):
        findings += _skill_lock(trees, sorted(paths), lock, vendor, set(own))
    findings += _producer_files(trees, changed)
    return findings


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python3 -m dotsteward_cli.writers")
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check", help="the writer classes of a candidate tree")
    checking.add_argument("--instance", required=True, help="the instance checkout")
    checking.add_argument("--base", required=True, help="the base commit")
    checking.add_argument("--tree", required=True, help="the candidate tree")
    checking.add_argument("--scope", default="maintain", choices=SCOPES)
    return parser


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    options = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    environment = os.environ if env is None else env
    try:
        instance = config.load_instance(options.instance, env=environment)
        state_root = config.state_root(instance, environment)
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return 1
    name = machine.current_name(machine.read_machine(state_root), environment)
    producer = producer_of(instance.root, options.base)
    findings = check(instance, options.base, options.tree, name, producer, options.scope)
    for finding in findings:
        print(f"[dotsteward] ERROR: {finding.line()}", file=sys.stderr)
    if not findings:
        return 0
    if any(not finding.path.startswith(f"{machine.HOSTS_DIR}/") for finding in findings):
        print(
            f"[dotsteward] ERROR: {CODE}: {producer} is the producer of this instance and moves these values; "
            f"'dotsteward host producer {name}' makes this machine the producer",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
