"""``skills capture``: from a change on this machine to the remote of the instance.

All of it happens in ``<state>/skills/worktree`` on the fetched tip, so a dirty checkout
is no obstacle and the checkout never moves: moving it would break a `rebuild` or a
`contribute upgrade` half way, and `agents install` knows a checkout that stayed behind.
No commit stays behind either: what waits is a list of names in pending.json. Each try
starts from the new tip and replays the copies, without any merge of text.

For each skill three digests decide, against the tip of the remote this time:

    r == l           the same content: b = r, no commit
    r == b           this machine had the old one: copy, commit
    otherwise        conflict: no commit, nothing changes here, the user answers

Three rules hold for every path into a commit, each in one place of ``_apply_copy``, whatever
the answer was:

- A copy of the remote that this machine has not seen is overwritten only by ``resolve
  --ours``. An answer to "track it?" says that a skill is yours, not that the copy another
  machine published may go. Only a pinned third-party copy turns into yours by ``--own``.
- A file that the ignore rules of the skill on the remote leave out does not go there, also
  when the local copy lost the rule. The rules in the copy itself act in the normal form.
- Two different local copies of one name stop: nothing says which one is the skill.

A name is the identity of a skill, in the directory or in the frontmatter. What ``--never``
and ``forget`` keep out is recorded by name in ``hosts/<machine>.toml``, so it holds after a
rename of the directory and after the state of this machine is gone; a new name is a new
skill.

A file deleted here leaves the repository, because the copy replaces the directory. An
existing entry changes its digests only, so what another machine wrote into it stays. The
commit passes two checks of the instance, run by the CLI the tree pins: ``static`` (the
privacy scan with the denylist among them) and ``pins check``. Neither needs Nix, and the
copied skills and the lock are no Nix input, so nothing more is needed to trust the commit;
the next full gate proves the same tree again.

What keeps a skill back leaves it working here and is told once: a privacy finding or a red
check (no commit), a refusal of the remote (no push), a link out of the tree, a size above
the limit, no name in the frontmatter. The same digest is neither tried nor told again,
with two exceptions. A red check or a refused commit belongs to a tree, so a look that
comes hours later or with ``--full`` tries again, and a tip that has not moved costs one
fetch and no check. A refusal of the remote waits for a person: ``skills retry``. Without a
network the skill stays in the list with ``reason = offline``, and every hook that runs
afterwards tries again; whatever keeps a skill waiting for more than a day is said. Redacted
findings land in ``last-capture.json``; the matched text never does.

A plugin goes the same way (``plugins``): an own plugin is copied to
``agent/plugins/<directory>`` with its ``own_plugins`` entry. The answer --all or --here to a
plugin of a marketplace is a maintenance change instead: its table goes into
``[[components.claude-code.options.plugins]]`` of ``workstation.toml``, and the manifest mirror
carries the component options, so the same commit carries what ``dotsteward generate`` (the
CLI the tree pins, in the worktree) makes of the new tree. Its evaluation runs every
assertion of the component on the table; then the same two checks, and the commit goes out
on the maintain ref. That evaluation is Nix, so only ``skills track`` and ``skills retry``
carry such an answer (``maintain``); a hook or a detached capture leaves it waiting.

One capture at a time: a busy ``capture.lock`` ends the run with status 0, and the holder
reads pending.json again before it ends.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from collections.abc import Collection, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, host, locks, publish, report, writers
from dotsteward_cli.skills import normal, plugins, reconcile, sleeper, state

CAPTURE_LOCK = "capture.lock"
WORKTREE = "worktree"
SETTLE_SECONDS = 2.0
CHECK_SECONDS = 1800
COMMIT_SECONDS = 300
_FRONTMATTER_NAME = re.compile(r"^name:[ \t]*(.+?)[ \t]*$", re.MULTILINE)
_KEPT_FINDINGS = 50
_DETAIL_LINES = 6
_DETAIL_CHARACTERS = 800


class ChecksRed(Exception):
    """The checks of the instance said no to the commit being built."""

    def __init__(self, reason: str, findings: Sequence[str]) -> None:
        super().__init__(reason)
        self.reason = reason
        self.findings = list(findings)


class ChecksUnavailable(Exception):
    """The CLI the tree pins cannot run: nothing was decided."""


@dataclass
class Summary:
    """The result of a run: what each skill became, and the exit status."""

    captured: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    blocked: list[str] = field(default_factory=list)
    waiting: list[str] = field(default_factory=list)
    done: list[str] = field(default_factory=list)
    dropped: dict[str, list[str]] = field(default_factory=dict)
    findings: list[str] = field(default_factory=list)
    codes: list[int] = field(default_factory=list)
    validation: dict[str, str] = field(default_factory=dict)
    busy: bool = False

    @property
    def code(self) -> int:
        return report.combine(self.codes)

    def document(self) -> dict[str, Any]:
        return {
            "status": report.status_name(self.code),
            "captured": self.captured,
            "conflicts": self.conflicts,
            "blocked": self.blocked,
            "waiting": self.waiting,
            "done": self.done,
            "busy": self.busy,
        }


@dataclass
class Work:
    """One item of pending.json on its way."""

    key: str
    name: str
    item: dict[str, Any]
    path: str | None
    answer: dict[str, Any]

    @property
    def kind(self) -> str:
        return str(self.item.get("kind") or state.SKILL)

    @property
    def marketplace(self) -> bool:
        """A plugin of a marketplace, which lands in workstation.toml."""
        source = self.item.get("source")
        return self.kind == state.PLUGIN and isinstance(source, dict) and bool(source.get("marketplace"))


@dataclass
class Applied:
    """A skill whose new state is in the worktree."""

    work: Work
    entry_name: str
    digest: str | None
    forgotten: bool = False
    cleared: bool = False


# --- the small pieces ---------------------------------------------------------------------


def _worktree(context: Mapping[str, Any]) -> str:
    return os.path.join(state.directory(str(context["state_root"])), WORKTREE)


def _fresh_worktree(instance: str, path: str, tip: str) -> None:
    """A clean worktree of TIP at PATH, whatever an earlier run left there."""
    publish.git(instance, "worktree", "remove", "--force", path)
    shutil.rmtree(path, ignore_errors=True)
    publish.git(instance, "worktree", "prune")
    added = publish.git(instance, "worktree", "add", "--quiet", "--detach", path, tip)
    if added.code != 0:
        raise OSError(f"cannot make the worktree: {added.stderr.strip()}")


def _remove_worktree(instance: str, path: str) -> None:
    publish.git(instance, "worktree", "remove", "--force", path)
    shutil.rmtree(path, ignore_errors=True)
    publish.git(instance, "worktree", "prune")


def _frontmatter_name(path: str) -> str | None:
    """The ``name`` of the frontmatter of SKILL.md at PATH."""
    try:
        with open(os.path.join(path, reconcile.SKILL_FILE), encoding="utf-8", errors="replace") as handle:
            text = handle.read(64 * 1024)
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    head, separator, _ = text[3:].partition("\n---")
    if not separator:
        return None
    match = _FRONTMATTER_NAME.search(head)
    return match.group(1).strip("\"'") if match else None


def _rejection(path: str | None, form: normal.NormalForm | None, name: str | None) -> str | None:
    """Why this copy cannot be captured at all."""
    if path is None or form is None:
        return "skill-invalid"
    if form.unsafe:
        return "unsafe-link"
    if not name or not state.PLAIN_NAME.fullmatch(name) or name.startswith(reconcile.FRAMEWORK_PREFIX):
        return "skill-invalid"
    return None


def _copy_form(form: normal.NormalForm, destination: str) -> None:
    """Replaces DESTINATION with the files of FORM; each keeps its mode & 0777."""
    shutil.rmtree(destination, ignore_errors=True)
    os.makedirs(destination)
    for relative, source in form.files.items():
        target = os.path.join(destination, os.fsdecode(relative))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(source, target)
        os.chmod(target, stat.S_IMODE(os.stat(source).st_mode))


def _read_tree_lock(worktree: str, relative: str) -> dict[str, Any]:
    with open(os.path.join(worktree, relative), encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict) or not isinstance(document.get("skills"), list):
        raise ValueError(f"{relative} is not a skills lock")
    return document


def _write_tree_lock(worktree: str, relative: str, document: Mapping[str, Any]) -> None:
    text = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    with open(os.path.join(worktree, relative), "w", encoding="utf-8") as handle:
        handle.write(text)


def _entry_of_copy(entries: Sequence[Any], directory: str) -> dict[str, Any] | None:
    """The entry whose copy is the directory DIRECTORY. The directory says which skill a
    copy is: its ``name`` may be what it was copied with."""
    for key in ("directory", "legacy_directory", "name"):
        for entry in entries:
            if isinstance(entry, dict) and entry.get(key) == directory:
                return entry
    return None


def _entry_named(entries: Sequence[Any], name: str) -> dict[str, Any] | None:
    for entry in entries:
        if isinstance(entry, dict) and entry.get("name") == name:
            return entry
    return None


def _insert_sorted(entries: list[Any], entry: dict[str, Any]) -> None:
    """In name order, where the list has one."""
    for index, other in enumerate(entries):
        if isinstance(other, dict) and str(other.get("name")) > str(entry["name"]):
            entries.insert(index, entry)
            return
    entries.append(entry)


def _sentinel(context: Mapping[str, Any]) -> str:
    """The sentinel of a new own skill: the instance's own, when it names one."""
    revisions = [str(item) for item in context.get("repo_owned_revisions") or []]
    other = [item for item in revisions if item != state.REPO_OWNED_REVISION]
    return other[0] if other else state.REPO_OWNED_REVISION


def _notify(name: str, reason: str) -> None:
    """Tells the desktop, where there is one: a name and a word, never any content."""
    if shutil.which("notify-send") is None:
        return
    shown = name if state.PLAIN_NAME.fullmatch(name) else "a skill"
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(
            ["notify-send", "dotsteward", f"{shown} was not published ({reason}): dotsteward skills status"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )


def _say(message: str) -> None:
    print(f"[dotsteward] {message}", file=sys.stderr)


# --- the host file ------------------------------------------------------------------------


def _write_host_file(
    context: Mapping[str, Any],
    worktree: str,
    machine: str,
    decline: str | None,
    accepted: Collection[str] = (),
    section: str = "skills",
) -> str:
    """Writes the host file of MACHINE in the worktree; its path below the tree."""
    relative = os.path.join("hosts", f"{machine}.toml")
    path = os.path.join(worktree, relative)
    try:
        with open(path, encoding="utf-8") as handle:
            current: str | None = handle.read()
    except FileNotFoundError:
        current = None
    record = state.read_json(os.path.join(str(context["state_root"]), "machine.json"), {})
    facts = record.get("host") if isinstance(record, dict) else None
    text = host.declined_text(
        current, facts if isinstance(facts, dict) else {}, decline, accepted=accepted, section=section
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return relative


def _announce_machine(context: Mapping[str, Any], worktree: str) -> list[str]:
    """A machine that has a name and no host file in the tree brings it with this commit."""
    machine = reconcile.machine_name(context)
    record = state.read_json(os.path.join(str(context["state_root"]), "machine.json"), None)
    if not machine or not isinstance(record, dict) or record.get("name") != machine:
        return []
    if os.path.exists(os.path.join(worktree, "hosts", f"{machine}.toml")):
        return []
    return [_write_host_file(context, worktree, machine, None)]


# --- the checks of the instance -----------------------------------------------------------


def _launcher(worktree: str, *arguments: str) -> publish.GitResult:
    """The CLI the tree pins, on the tree; a launcher may have to fetch that CLI first."""
    launcher = os.path.join(worktree, ".dotsteward", "cli.sh")
    argv = ["bash", launcher, *arguments]
    if not os.path.isfile(launcher):
        argv = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", worktree, *arguments]
    return publish.run(argv, cwd=worktree, seconds=CHECK_SECONDS, env={"DOTSTEWARD_INSTANCE": worktree})


def _finding_lines(text: str) -> list[str]:
    """The lines of a privacy report: rule and location, never the matched text."""
    return [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("[dotsteward]")]


def _error_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if "ERROR" in line or line.startswith("[pins]")]


def _run_checks(worktree: str, summary: Summary) -> None:
    """The two checks of the skill scope; ChecksRed when one says no."""
    checked = _launcher(worktree, "static")
    if checked.code != 0:
        if _launcher(worktree, "version").code != 0:
            raise ChecksUnavailable(checked.stderr.strip()[-400:])
        privacy = _launcher(worktree, "static", "--only", "privacy")
        if privacy.code != 0:
            summary.validation["static"] = "privacy"
            raise ChecksRed("privacy", _finding_lines(privacy.stdout)[:_KEPT_FINDINGS])
        summary.validation["static"] = "failed"
        raise ChecksRed("checks-red", _error_lines(checked.stderr)[:_KEPT_FINDINGS])
    summary.validation["static"] = "passed"
    pins = _launcher(worktree, "pins", "check")
    if pins.code != 0:
        summary.validation["pins"] = "failed"
        raise ChecksRed("checks-red", _error_lines(pins.stderr)[:_KEPT_FINDINGS])
    summary.validation["pins"] = "passed"


def _check_paths(worktree: str, tip: str, allowed: Sequence[str]) -> None:
    """A skill commit touches the skills it is about, the lock and the host file."""
    changed = publish.git(worktree, "diff", "--cached", "--name-only", "--no-renames", tip).stdout.splitlines()
    for path in changed:
        if not any(path == item or path.startswith(item + "/") for item in allowed):
            raise ChecksRed("writer-class", [f"a skill commit does not touch {path}"])


def _check_writers(context: Mapping[str, Any], loaded_tree: Mapping[str, str], worktree: str, tip: str) -> None:
    """Who writes what: a skill commit of a machine that is not the producer moves no pin of a
    third-party skill the tip has (docs/machines.md)."""
    tree = publish.git(worktree, "write-tree").stdout.strip()
    findings = writers.check_tree(
        Path(worktree),
        tip,
        tree,
        name=reconcile.machine_name(context),
        producer=writers.producer_of(Path(worktree), tip),
        scope="skill",
        lock=loaded_tree["lock"],
        vendor=loaded_tree["vendor"],
        own=[str(item) for item in context.get("repo_owned_revisions") or []],
    )
    if findings:
        raise ChecksRed(writers.CODE, [finding.line() for finding in findings])


# --- one attempt --------------------------------------------------------------------------


class _Attempt:
    """What one attempt on one tip made of the work; see ``_cycle``."""

    def __init__(self) -> None:
        self.applied: list[Applied] = []
        self.conflicts: list[Work] = []
        self.in_sync: list[tuple[Work, str, str]] = []
        self.taken: list[Work] = []
        self.declined: list[Work] = []
        self.rejected: list[tuple[Work, str, str | None]] = []
        self.repeated: list[Work] = []
        self.dropped: dict[str, list[str]] = {}
        self.finished: list[Work] = []


def _kept_back_as_before(item: Mapping[str, Any], digest: str, tip: str) -> bool:
    """The same content was kept back, and what kept it back has not changed."""
    if item.get("blocked_digest") != digest:
        return False
    return item.get("reason") not in reconcile.TREE_REASONS or item.get("blocked_tip") in (None, tip)


def _other_copy(context: Mapping[str, Any], work: Work, path: str, names: set[str], digest: str) -> str | None:
    """Another local copy of this skill with another content, under one of NAMES."""
    real = os.path.realpath(path)
    places = [os.path.join(str(root), name) for root in context.get("roots") or [] for name in sorted(names)]
    record = state.base_entry(state.load_base(str(context["state_root"])), work.name)
    if record and isinstance(record.get("local_path"), str):
        places.append(record["local_path"])
    excludes = os.path.join(str(context["instance"]), ".gitignore")
    for place in places:
        if os.path.realpath(place) == real or not os.path.isfile(os.path.join(place, reconcile.SKILL_FILE)):
            continue
        try:
            if normal.normal_form(os.path.realpath(place), excludes, reconcile.limit_bytes(context)).digest != digest:
                return place
        except (normal.TooLarge, normal.NormalFormError, OSError):
            return place
    return None


def _ignored_on_the_remote(destination: str, form: normal.NormalForm) -> list[str]:
    """The files of FORM that the ``.gitignore`` of the skill in the tree leaves out."""
    try:
        with open(os.path.join(destination, ".gitignore"), "rb") as handle:
            rules = handle.read()
    except OSError:
        return []
    return normal.ignored_by(rules, [os.fsdecode(name) for name in form.files])


def _apply_copy(
    context: Mapping[str, Any],
    work: Work,
    worktree: str,
    tip: str,
    tree: Mapping[str, str],
    document: dict[str, Any],
    base: Mapping[str, Any],
    attempt: _Attempt,
) -> list[str]:
    """Replays one skill onto the tree; the paths the commit may touch."""
    machine = reconcile.machine_name(context)
    declined_here = reconcile.declined_in(worktree, machine)
    path = work.path if work.path and os.path.isdir(work.path) else None
    declined_names = declined_here & {work.name, _frontmatter_name(path) if path else None}
    if declined_names and not work.answer:
        # The tip knows the answer, whatever this machine forgot.
        attempt.declined.append(work)
        return []
    excludes = os.path.join(worktree, ".gitignore")
    try:
        form = normal.normal_form(os.path.realpath(path), excludes, reconcile.limit_bytes(context)) if path else None
    except normal.TooLarge as large:
        digest = reconcile.TOO_LARGE_PREFIX + large.marker
        if work.item.get("blocked_digest") == digest:
            attempt.repeated.append(work)
        else:
            attempt.rejected.append((work, "too-large", digest))
        return []
    declared = _frontmatter_name(path) if path else None
    if form is not None and _kept_back_as_before(work.item, form.digest, tip):
        attempt.repeated.append(work)
        return []
    reason = _rejection(path, form, declared)
    if reason is not None or form is None or declared is None or path is None:
        attempt.rejected.append((work, reason or "skill-invalid", form.digest if form else None))
        return []
    entries: list[Any] = document["skills"]
    basename = os.path.basename(os.path.normpath(path))
    entry = _entry_of_copy(entries, basename)
    holder = _entry_named(entries, declared)
    if holder is not None and holder is not entry:
        # A copy of another skill that still carries its name: it must not land on that skill.
        work.item["digest"] = form.digest
        attempt.taken.append(work)
        return []
    directory = str(entry.get("directory") or entry["name"]) if entry else basename
    entry_name = str(entry["name"]) if entry else declared
    record = state.base_entry(base, entry_name)
    local = form.digest
    work.item["digest"] = local
    remote = ""
    if entry is not None:
        vendored = os.path.join(worktree, tree["vendor"], directory)
        remote = str(entry.get("directory_sha256") or normal.plain_digest(vendored))
    known = record["base_sha256"] if record else None
    own = entry is not None and entry.get("revision") in (context.get("repo_owned_revisions") or [])
    answer = work.answer
    if entry is not None and isinstance(entry.get("machines"), list) and machine not in entry["machines"]:
        attempt.taken.append(work)
        return []
    attempt.dropped[entry_name] = form.dropped
    if entry is not None and remote == local and (own or not answer.get("own")):
        attempt.in_sync.append((work, entry_name, local))
        return []
    if entry is None:
        if known is not None and known == local:
            attempt.finished.append(work)
            return []
        if known is not None and not (answer.get("ours") or answer.get("own")):
            attempt.conflicts.append(work)
            return []
    elif not (answer.get("ours") or (known == remote if own else answer.get("own"))):
        attempt.conflicts.append(work)
        return []
    destination = os.path.join(worktree, tree["vendor"], directory)
    other = _other_copy(context, work, path, {basename, declared, directory, entry_name}, local)
    if other is not None:
        work.item.update(taken_reason="two-copies", detail=other)
        attempt.taken.append(work)
        return []
    ignored = _ignored_on_the_remote(destination, form)
    if ignored:
        attempt.rejected.append((work, "ignored-file", local))
        work.item["detail"] = "\n".join(ignored)
        return []
    _copy_form(form, destination)
    if normal.plain_digest(destination) != local:
        # The copy changed under our feet: next time.
        attempt.repeated.append(work)
        return []
    skill_digest = normal.file_sha256(os.path.join(destination, reconcile.SKILL_FILE))
    if entry is None:
        entry = {"name": declared, "directory": directory, "revision": _sentinel(context)}
        source = answer.get("source")
        if isinstance(source, dict) and source.get("revision") and not answer.get("own"):
            entry.update({"source": source.get("url"), "revision": source["revision"]})
            if source.get("path") is not None:
                entry["source_path"] = source["path"]
        entry.update({"skill_sha256": skill_digest, "directory_sha256": local})
        if answer.get("here"):
            entry["machines"] = [machine]
        _insert_sorted(entries, entry)
    else:
        entry["skill_sha256"] = skill_digest
        entry["directory_sha256"] = local
        if answer.get("own") and not own:
            entry["revision"] = _sentinel(context)
    attempt.applied.append(Applied(work, entry_name, local))
    allowed = [os.path.join(tree["vendor"], directory)]
    if machine and (answer.get("here") or declined_names):
        allowed.append(_write_host_file(context, worktree, machine, None, accepted=declined_names))
    return allowed


def _section(work: Work) -> str:
    """The list of the host file that holds what this machine declined."""
    return "plugins" if work.kind == state.PLUGIN else "skills"


def _apply_plugin_copy(
    context: Mapping[str, Any],
    work: Work,
    worktree: str,
    tip: str,
    tree: Mapping[str, str],
    document: dict[str, Any],
    base: Mapping[str, Any],
    attempt: _Attempt,
) -> list[str]:
    """Replays one own plugin onto the tree, the way ``_apply_copy`` does a skill; the name is
    the one of its manifest."""
    machine = reconcile.machine_name(context)
    path = work.path if work.path and os.path.isdir(work.path) else None
    declined_names = plugins.declined_in(worktree, machine) & {work.name}
    if declined_names and not work.answer:
        attempt.declined.append(work)
        return []
    excludes = os.path.join(worktree, ".gitignore")
    try:
        form = normal.normal_form(os.path.realpath(path), excludes, reconcile.limit_bytes(context)) if path else None
    except normal.TooLarge as large:
        digest = reconcile.TOO_LARGE_PREFIX + large.marker
        if work.item.get("blocked_digest") == digest:
            attempt.repeated.append(work)
        else:
            attempt.rejected.append((work, "too-large", digest))
        return []
    declared = plugins.manifest_name(path) if path else None
    if form is not None and _kept_back_as_before(work.item, form.digest, tip):
        attempt.repeated.append(work)
        return []
    reason = _rejection(path, form, declared)
    if reason is not None or form is None or declared is None or path is None:
        why = "plugin-invalid" if reason is None or reason == "skill-invalid" else reason
        attempt.rejected.append((work, why, None))
        return []
    listed = document.get("own_plugins")
    entries: list[Any] = listed if isinstance(listed, list) else []
    basename = os.path.basename(os.path.normpath(path))
    entry = _entry_of_copy(entries, basename)
    holder = _entry_named(entries, declared)
    if holder is not None and holder is not entry:
        work.item["digest"] = form.digest
        attempt.taken.append(work)
        return []
    directory = str(entry.get("directory") or entry["name"]) if entry else basename
    entry_name = str(entry["name"]) if entry else declared
    record = state.base_entry(base, entry_name, state.PLUGIN)
    local = form.digest
    work.item["digest"] = local
    destination = os.path.join(worktree, tree["plugins"], directory)
    remote = str(entry.get("directory_sha256") or normal.plain_digest(destination)) if entry is not None else ""
    known = record["base_sha256"] if record else None
    answer = work.answer
    if entry is not None and isinstance(entry.get("machines"), list) and machine not in entry["machines"]:
        attempt.taken.append(work)
        return []
    agents = entry.get("agents") if entry is not None else None
    if isinstance(agents, list) and agents and plugins.agent_of(path) not in agents:
        # One name, one own plugin: a copy of another agent never lands on it.
        work.item["taken_reason"] = reconcile.OTHER_AGENT
        attempt.taken.append(work)
        return []
    attempt.dropped[entry_name] = form.dropped
    if entry is not None and remote == local:
        attempt.in_sync.append((work, entry_name, local))
        return []
    if entry is None:
        if known is not None and known == local:
            attempt.finished.append(work)
            return []
        if known is not None and not (answer.get("ours") or answer.get("own")):
            attempt.conflicts.append(work)
            return []
    elif not (answer.get("ours") or known == remote):
        attempt.conflicts.append(work)
        return []
    ignored = _ignored_on_the_remote(destination, form)
    if ignored:
        attempt.rejected.append((work, "ignored-file", local))
        work.item["detail"] = "\n".join(ignored)
        return []
    _copy_form(form, destination)
    if normal.plain_digest(destination) != local:
        attempt.repeated.append(work)
        return []
    if entry is None:
        entry = {
            "name": declared,
            "directory": directory,
            "agents": [plugins.agent_of(path) or plugins.AGENT],
            "directory_sha256": local,
        }
        if answer.get("here"):
            entry["machines"] = [machine]
        _insert_sorted(entries, entry)
        document["own_plugins"] = entries
    else:
        entry["directory_sha256"] = local
    attempt.applied.append(Applied(work, entry_name, local))
    allowed = [os.path.join(tree["plugins"], directory)]
    if machine and (answer.get("here") or declined_names):
        allowed.append(_write_host_file(context, worktree, machine, None, accepted=declined_names, section="plugins"))
    return allowed


def _apply_marketplace(
    context: Mapping[str, Any], work: Work, worktree: str, tree: Mapping[str, str], attempt: _Attempt
) -> list[str]:
    """The answer about a plugin of a marketplace: its table in options.plugins."""
    from dotsteward_cli import tomlfile

    machine = reconcile.machine_name(context)
    here = bool(work.answer.get("here"))
    if here and not machine:
        attempt.rejected.append((work, "machine-name-required", None))
        return []
    relative = tree["config"]
    path = os.path.join(worktree, relative)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    document = tomlfile.loads(text)
    existing = plugins.table_of(document, work.name)
    for_all = existing is not None and not isinstance(existing.get("machines"), list)
    if for_all or (here and work.name in plugins.tracked_specs(document, machine)):
        attempt.in_sync.append((work, work.name, ""))
        return []
    if not plugins.manages_claude(document):
        attempt.rejected.append((work, "claude-code-not-managed", None))
        return []
    if existing is not None:
        # The table of another machine's --here: this answer edits it, a second table of the
        # same spec is no valid configuration.
        known = existing.get("machines")
        machines = sorted({*(str(item) for item in known), str(machine)}) if here and isinstance(known, list) else None
        changed = plugins.with_machines(text, work.name, machines)
    else:
        source = work.item.get("source") or {}
        try:
            entry = plugins.options_entry(document, work.name, str(source.get("repo")), machine if here else None)
        except ValueError:
            attempt.rejected.append((work, "plugin-invalid", None))
            return []
        changed = plugins.with_options_entry(text, entry)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(changed)
    attempt.applied.append(Applied(work, work.name, None))
    allowed = [relative]
    accepted = plugins.declined_in(worktree, machine) & {work.name}
    if machine and (here or accepted):
        allowed.append(_write_host_file(context, worktree, machine, None, accepted=accepted, section="plugins"))
    return allowed


def _stage(worktree: str, paths: Sequence[str]) -> None:
    for path in paths:
        added = publish.git(worktree, "-c", f"core.excludesFile={os.devnull}", "add", "-A", "-f", "--", path)
        if added.code != 0 and os.path.lexists(os.path.join(worktree, path)):
            raise OSError(f"git add failed: {added.stderr.strip()}")


def _generate(worktree: str) -> list[str]:
    """The mirrors of the tree, as ``dotsteward generate`` writes them; the paths it may
    change. ChecksRed when the evaluation fails."""
    generated = _launcher(worktree, "generate")
    if generated.code != 0:
        raise ChecksRed(
            "generate-failed", _error_lines(generated.stderr)[:_KEPT_FINDINGS] or [_last_lines(generated.stderr)]
        )
    return [".dotsteward", "versions.lock.json"]


def _apply_decline(context: Mapping[str, Any], work: Work, worktree: str, attempt: _Attempt) -> list[str]:
    machine = reconcile.machine_name(context)
    if not machine:
        attempt.rejected.append((work, "machine-name-required", None))
        return []
    relative = _write_host_file(context, worktree, machine, work.name, section=_section(work))
    attempt.applied.append(Applied(work, work.name, None))
    return [relative]


def _apply_forget(
    context: Mapping[str, Any],
    work: Work,
    worktree: str,
    tree: Mapping[str, str],
    document: dict[str, Any],
    attempt: _Attempt,
) -> list[str]:
    plugin = work.kind == state.PLUGIN
    listed = document.get("own_plugins") if plugin else document["skills"]
    entries: list[Any] = listed if isinstance(listed, list) else []
    entry = _entry_named(entries, work.name) or _entry_of_copy(entries, work.name)
    if entry is None:
        attempt.finished.append(work)
        return []
    directory = str(entry.get("directory") or entry.get("name"))
    vendor = tree["plugins"] if plugin else tree["vendor"]
    shutil.rmtree(os.path.join(worktree, vendor, directory), ignore_errors=True)
    entries.remove(entry)
    attempt.applied.append(Applied(work, str(entry["name"]), None, forgotten=True))
    allowed = [os.path.join(vendor, directory)]
    machine = reconcile.machine_name(context)
    if machine:
        # This machine stays out of it, also when its state is gone.
        allowed.append(_write_host_file(context, worktree, machine, str(entry["name"]), section=_section(work)))
    return allowed


def _apply_clear(context: Mapping[str, Any], work: Work, worktree: str, attempt: _Attempt) -> list[str]:
    """The name leaves the host file of this machine; without one there, only the item goes."""
    machine = reconcile.machine_name(context)
    plugin = work.kind == state.PLUGIN
    declined = plugins.declined_in(worktree, machine) if plugin else reconcile.declined_in(worktree, machine)
    if machine and work.name in declined:
        attempt.applied.append(Applied(work, work.name, None, cleared=True))
        return [_write_host_file(context, worktree, machine, None, accepted={work.name}, section=_section(work))]
    attempt.finished.append(work)
    return []


def _subject(applied: Sequence[Applied]) -> str:
    names = ", ".join(item.entry_name for item in applied)
    scope = "plugins" if all(item.work.kind == state.PLUGIN for item in applied) else "skills"
    if any(item.cleared for item in applied):
        return f"chore({scope}): clear {names}"
    if any(item.forgotten for item in applied):
        return f"chore({scope}): forget {names}"
    if any(item.work.answer.get("never") for item in applied):
        return f"chore({scope}): decline {names}"
    if all(item.work.marketplace for item in applied):
        return f"chore({scope}): track {names}"
    return f"chore({scope}): capture {names}"


def _build_on(
    context: Mapping[str, Any], loaded_tree: Mapping[str, str], work: Sequence[Work], tip: str, summary: Summary
) -> tuple[str | None, _Attempt]:
    """One attempt on TIP: replay, check, commit. The commit, or None when nothing is to
    be published."""
    instance = str(context["instance"])
    worktree = _worktree(context)
    state_root = str(context["state_root"])
    _fresh_worktree(instance, worktree, tip)
    document = _read_tree_lock(worktree, loaded_tree["lock"])
    before = json.dumps(document, sort_keys=True)
    base = state.load_base(state_root)
    attempt = _Attempt()
    allowed = [loaded_tree["lock"]]
    for item in work:
        if item.answer.get("never"):
            allowed += _apply_decline(context, item, worktree, attempt)
        elif item.answer.get("forget"):
            allowed += _apply_forget(context, item, worktree, loaded_tree, document, attempt)
        elif item.answer.get("clear"):
            allowed += _apply_clear(context, item, worktree, attempt)
        elif item.marketplace:
            allowed += _apply_marketplace(context, item, worktree, loaded_tree, attempt)
        elif item.kind == state.PLUGIN:
            allowed += _apply_plugin_copy(context, item, worktree, tip, loaded_tree, document, base, attempt)
        else:
            allowed += _apply_copy(context, item, worktree, tip, loaded_tree, document, base, attempt)
    if not attempt.applied:
        return None, attempt
    allowed += _announce_machine(context, worktree)
    if json.dumps(document, sort_keys=True) != before:
        _write_tree_lock(worktree, loaded_tree["lock"], document)
    _stage(worktree, allowed)
    if any(_is_maintenance(item.work) for item in attempt.applied):
        # Nix sees what git knows: the mirrors are made of the staged tree.
        generated = _generate(worktree)
        _stage(worktree, generated)
        allowed += generated
    _check_paths(worktree, tip, allowed)
    _check_writers(context, loaded_tree, worktree, tip)
    _run_checks(worktree, summary)
    message = host.commit_message(_subject(attempt.applied), reconcile.machine_name(context))
    identity = host.commit_identity(Path(worktree), tip)
    # A signing program or a hook that hangs must not hold the capture lock for ever.
    committed = publish.git(
        worktree, *identity, "commit", "--quiet", "-F", "-", env={"TZ": "UTC"}, stdin=message, seconds=COMMIT_SECONDS
    )
    if committed.code != 0:
        raise ChecksRed("commit-refused", [committed.stderr.strip()[-400:]])
    return publish.git(worktree, "rev-parse", "HEAD").stdout.strip(), attempt


# --- what a run makes of it ---------------------------------------------------------------


def _last_lines(text: str) -> str:
    """The end of what a tool said, for ``skills status``."""
    return "\n".join(text.strip().splitlines()[-_DETAIL_LINES:])[-_DETAIL_CHARACTERS:]


def _set_blocked(
    state_root: str, work: Work, reason: str, digest: str | None, *, tip: str | None = None, detail: str = ""
) -> None:
    fields = {
        "state": reconcile.BLOCKED,
        "reason": reason,
        "blocked_digest": digest,
        "blocked_tip": tip,
        "blocked_at": time.time(),
        "detail": _last_lines(detail),
        "digest": digest,
        "last_asked": None,
    }
    state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
    _notify(work.name, reason)


def _identity_fields(work: Work) -> dict[str, Any]:
    return {"kind": work.kind, "name": work.name, "path": work.path, "origin": work.item.get("origin", "own")}


def _record_in_sync(state_root: str, work: Work, name: str, digest: str, commit: str) -> None:
    """This machine has NAME as the remote has it since COMMIT."""
    if work.marketplace:
        state.record_marketplace(state_root, name, commit)
    else:
        state.record_base(state_root, name, digest, commit, work.path or "", work.kind)


def _drop_unless_changed(state_root: str, work: Work) -> None:
    """A write that came in meanwhile keeps the item for the next run."""
    now = state.load_pending(state_root)["items"].get(work.key)
    if isinstance(now, dict) and now.get("detected_at") != work.item.get("detected_at"):
        fields = {"answer": None, "reason": None, "offline_since": None}
        state.set_item(state_root, work.key, fields)
        return
    state.drop_item(state_root, work.key)


def _settle(state_root: str, attempt: _Attempt, published: publish.Published, summary: Summary) -> None:
    """Records what the last attempt decided about each skill."""
    for work in attempt.conflicts:
        digest = work.item.get("digest")
        # An answer that led here is used up: only resolve goes on from a conflict.
        fields = {
            "state": reconcile.CONFLICT,
            "reason": None,
            "answer": None,
            "digest": digest,
            "conflict_digest": digest,
        }
        if work.item.get("conflict_digest") != digest:
            fields["last_asked"] = None
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        summary.conflicts.append(work.name)
        summary.codes.append(report.PENDING)
    for work in attempt.taken:
        digest = work.item.get("digest")
        fields = {
            "state": reconcile.NAME_TAKEN,
            "reason": work.item.get("taken_reason"),
            "detail": work.item.get("detail") or "",
            "answer": None,
            "blocked_digest": digest,
            "last_asked": None,
        }
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        summary.conflicts.append(work.name)
        summary.codes.append(report.PENDING)
    for work in attempt.declined:
        fields = {"state": reconcile.DECLINED, "reason": None, "last_asked": None}
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        state.forget_base(state_root, work.name, work.kind)
        summary.done.append(work.name)
    for work, reason, digest in attempt.rejected:
        _set_blocked(state_root, work, reason, digest, detail=str(work.item.get("detail") or ""))
        _say(f"skill {work.name} was not published: {reason}")
        summary.blocked.append(work.name)
        summary.codes.append(report.FAILED)
    for work, name, digest in attempt.in_sync:
        _record_in_sync(state_root, work, name, digest, published.tip or "")
        _drop_unless_changed(state_root, work)
        summary.done.append(work.name)
    for work in attempt.repeated:
        previous = work.item
        if previous.get("blocked_digest"):
            fields = {"state": reconcile.BLOCKED, "digest": previous.get("blocked_digest"), "blocked_at": time.time()}
            state.set_item(state_root, work.key, fields)
    for work in attempt.finished:
        state.drop_item(state_root, work.key)
    summary.dropped.update({name: paths for name, paths in attempt.dropped.items() if paths})


def _record_applied(state_root: str, attempt: _Attempt, commit: str, summary: Summary) -> None:
    for applied in attempt.applied:
        work = applied.work
        if applied.cleared:
            state.drop_item(state_root, work.key)
            summary.done.append(work.name)
        elif applied.forgotten:
            state.forget_base(state_root, applied.entry_name, work.kind)
            if work.path and os.path.isdir(work.path):
                fields = {"state": reconcile.FORGOTTEN, "answer": None, "reason": None, "last_asked": None}
                state.set_item(state_root, work.key, fields)
            else:
                state.drop_item(state_root, work.key)
            summary.done.append(work.name)
        elif work.answer.get("never"):
            fields = {"state": reconcile.DECLINED, "answer": None, "reason": None, "last_asked": None}
            state.set_item(state_root, work.key, fields)
            # Nothing here is in sync any more, so nothing asks about the copy that is gone.
            state.forget_base(state_root, work.name, work.kind)
            summary.done.append(work.name)
        else:
            _record_in_sync(state_root, work, applied.entry_name, applied.digest or "", commit)
            if work.key != state.item_key(work.kind, applied.entry_name):
                state.drop_item(state_root, state.item_key(work.kind, applied.entry_name))
            _drop_unless_changed(state_root, work)
            summary.captured.append(applied.entry_name)


def _mark_waiting(state_root: str, work: Sequence[Work], reason: str, summary: Summary, detail: str = "") -> None:
    now = time.time()
    for item in work:
        fields = {
            **_identity_fields(item),
            "state": reconcile.CAPTURE,
            "reason": reason,
            "detail": _last_lines(detail),
            "offline_since": item.item.get("offline_since") or now,
            "attempts": int(item.item.get("attempts") or 0) + 1,
        }
        state.set_item(state_root, item.key, fields)
        summary.waiting.append(item.name)
        summary.codes.append(report.PARTIAL)


def _cycle(context: Mapping[str, Any], tree: Mapping[str, str], work: Sequence[Work], summary: Summary) -> None:
    """Publishes WORK, or says what kept each skill back."""
    instance = str(context["instance"])
    state_root = str(context["state_root"])
    last: dict[str, _Attempt] = {}
    tips: list[str] = []

    def build(tip: str) -> str | None:
        tips.append(tip)
        commit, attempt = _build_on(context, tree, work, tip, summary)
        last["attempt"] = attempt
        return commit

    scope = "maintain" if any(_is_maintenance(item) for item in work) else "skill"
    try:
        published = publish.publish(instance, tree["branch"], scope, build)
    except ChecksRed as red:
        if len(work) > 1:
            # Which skill? Each on its own says it.
            for item in work:
                _cycle(context, tree, [item], summary)
            return
        item = work[0]
        digest = None
        if item.path:
            with contextlib.suppress(normal.NormalFormError, OSError):
                digest = normal.normal_form(os.path.realpath(item.path), os.path.join(instance, ".gitignore")).digest
        detail = "" if red.reason == "privacy" else "\n".join(red.findings)
        _set_blocked(state_root, item, red.reason, digest, tip=tips[-1] if tips else None, detail=detail)
        summary.findings += red.findings
        summary.blocked.append(item.name)
        summary.codes.append(report.PRIVACY_STOP if red.reason == "privacy" else report.FAILED)
        _say(f"{item.kind} {item.name} was not published: {red.reason}; dotsteward skills status has the findings")
        return
    except ChecksUnavailable as unavailable:
        _say(f"the checks of the instance cannot run: {unavailable}")
        _mark_waiting(state_root, work, "checks-unavailable", summary, str(unavailable))
        return
    attempt = last.get("attempt")
    if published.outcome == publish.OK:
        if attempt is not None:
            _settle(state_root, attempt, published, summary)
            if published.commit is not None:
                _record_applied(state_root, attempt, published.commit, summary)
        return
    if published.outcome == publish.REFUSED:
        _say(f"the remote refused: {published.detail}")
        for item in work:
            digest = None
            if item.path:
                with contextlib.suppress(normal.NormalFormError, OSError):
                    digest = normal.normal_form(
                        os.path.realpath(item.path), os.path.join(instance, ".gitignore")
                    ).digest
            _set_blocked(state_root, item, "remote-refused", digest, detail=published.detail)
            summary.blocked.append(item.name)
            summary.codes.append(report.FAILED)
        return
    if published.outcome == publish.NETWORK:
        _say(f"no network or no answer from the remote: {published.detail}")
        _mark_waiting(state_root, work, "offline", summary, published.detail)
        return
    _say("other machines kept pushing; the skills wait for the next run")
    _mark_waiting(state_root, work, "race", summary)


# --- a run --------------------------------------------------------------------------------


def _is_maintenance(work: Work) -> bool:
    """An answer that changes workstation.toml and its mirrors."""
    return work.marketplace and bool(work.answer) and not work.answer.get("never")


def waiting(state_root: str) -> bool:
    """Whether something still waits for a capture."""
    return any(
        isinstance(item, dict) and item.get("state") == reconcile.CAPTURE
        for item in state.load_pending(state_root)["items"].values()
    )


def _ready(
    context: Mapping[str, Any],
    names: Sequence[str] | None,
    handled: set[str],
    only_due: bool = False,
    maintain: bool = False,
) -> list[Work]:
    """The items that wait for a capture; each only once in a run. ONLY_DUE: the run of a
    deadline, which leaves alone what still has its delay to wait. MAINTAIN: the run of an
    answer, which may carry a maintenance change (Nix); no other run does."""
    document = state.load_pending(str(context["state_root"]))
    now = time.time()
    delay = sleeper.delay_seconds(context)
    work = []
    for key, item in document["items"].items():
        if (
            not isinstance(item, dict)
            or item.get("state") != reconcile.CAPTURE
            or item.get("kind", state.SKILL) not in (state.SKILL, state.PLUGIN)
            or key in handled
        ):
            continue
        name = str(item.get("name"))
        if names and name not in names:
            continue
        if only_due and not sleeper.is_due(item, now, delay):
            continue
        if only_due and _still_being_edited(item, now, delay):
            continue
        path = item.get("path")
        answer = item.get("answer")
        source = item.get("source")
        if not answer and isinstance(source, dict) and source.get("marketplace"):
            # A plugin of a marketplace moves only with an answer.
            continue
        if not answer and isinstance(path, str) and not os.path.isdir(path):
            state.drop_item(str(context["state_root"]), key)
            continue
        found = Work(
            key, name, item, path if isinstance(path, str) else None, answer if isinstance(answer, dict) else {}
        )
        if _is_maintenance(found) and not maintain:
            continue
        work.append(found)
    return work


def _still_being_edited(item: Mapping[str, Any], now: float, delay: float) -> bool:
    """A retry was due, and the copy changed meanwhile: it waits for its delay like a fresh one."""
    path = item.get("path")
    if item.get("due") or item.get("answer") or not isinstance(path, str):
        return False
    return _newest_change(path) + delay > now


def _newest_change(path: str) -> float:
    """When something below PATH last changed; a time in the future says nothing about that."""
    newest = 0.0
    now = time.time()
    for directory, _, files in os.walk(path):
        for name in (".", *files):
            with contextlib.suppress(OSError):
                changed = os.lstat(os.path.join(directory, name)).st_mtime
                if changed <= now:
                    newest = max(newest, changed)
    return newest


def _settled(work: Sequence[Work]) -> list[Work]:
    """What has not changed for two seconds: a tool may still be writing the rest."""
    now = time.time()
    newest = max((_newest_change(item.path) for item in work if item.path), default=0.0)
    if newest > now - SETTLE_SECONDS:
        time.sleep(min(SETTLE_SECONDS, newest + SETTLE_SECONDS - now))
    now = time.time()
    return [item for item in work if not item.path or _newest_change(item.path) <= now - SETTLE_SECONDS / 2]


def tree_paths(loaded: config.Instance) -> dict[str, str]:
    """The paths of the instance in a tree, and its branch."""
    return {
        "lock": str(loaded.config["skills"]["lock"]),
        "vendor": str(loaded.config["skills"]["vendor_dir"]).rstrip("/"),
        "plugins": plugins.OWN_PLUGINS_DIR,
        "config": config.CONFIG_FILE,
        "branch": str(loaded.config["instance"]["branch"]),
    }


def _write_last(state_root: str, summary: Summary) -> None:
    document = {
        "schema_version": state.SCHEMA_VERSION,
        "at": time.time(),
        **summary.document(),
        "dropped": summary.dropped,
        "findings": summary.findings,
        "validation": summary.validation,
    }
    state.write_json(os.path.join(state.directory(state_root), state.LAST_CAPTURE_FILE), document)


def run_now(
    context: Mapping[str, Any],
    tree: Mapping[str, str],
    names: Sequence[str] | None = None,
    *,
    only_due: bool = False,
    maintain: bool = False,
) -> Summary:
    """One capture run: publishes what waits and reads pending.json again before it ends.
    MAINTAIN: also an answer that changes workstation.toml (see the module text)."""
    state_root = str(context["state_root"])
    instance = str(context["instance"])
    summary = Summary()
    atomic.make_private_dirs(state.directory(state_root))
    lock = locks.FileLock(os.path.join(state.directory(state_root), CAPTURE_LOCK))
    if not lock.try_acquire():
        summary.busy = True
        return summary
    handled: set[str] = set()
    ran = False
    work: list[Work] = []
    try:
        sleeper.log(state_root, "run")
        while True:
            work = _ready(context, names, handled, only_due, maintain)
            if not work:
                break
            ready = _settled(work)
            handled.update(item.key for item in work)
            if not ready:
                continue
            ran = True
            answers = [
                item for item in ready if set(item.answer) & {"never", "forget", "clear"} or _is_maintenance(item)
            ]
            captures = [item for item in ready if item not in answers]
            for batch in [[item] for item in answers] + ([captures] if captures else []):
                _cycle(context, tree, batch, summary)
    except (normal.NormalFormError, OSError, ValueError, config.DotstewardError, host.Refusal) as error:
        _say(f"the capture failed: {error}")
        sleeper.log(state_root, f"failed: {error}")
        _mark_waiting(state_root, work, "capture-failed", summary, str(error))
        summary.codes.append(report.FAILED)
    finally:
        if ran:
            _remove_worktree(instance, _worktree(context))
            _write_last(state_root, summary)
        lock.release()
    return summary
