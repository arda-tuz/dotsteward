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

A file deleted here leaves the repository, because the copy replaces the directory. An
existing entry changes its digests only, so what another machine wrote into it stays. The
commit passes two checks of the instance, run by the CLI the tree pins: ``static`` (the
privacy scan with the denylist among them) and ``pins check``. Neither needs Nix, and the
copied skills and the lock are no Nix input, so nothing more is needed to trust the commit;
the next full gate proves the same tree again.

What keeps a skill back leaves it working here and is told once: a privacy finding or a red
check (no commit), a refusal of the remote (no push), a link out of the tree, a size above
the limit, no name in the frontmatter. The same digest is neither tried nor told again.
Without a network the skill stays in the list with ``reason = offline``, and every hook
that runs afterwards tries again. Redacted findings land in ``last-capture.json``; the
matched text never does.

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
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, host, locks, publish, report
from dotsteward_cli.skills import normal, reconcile, sleeper, state

CAPTURE_LOCK = "capture.lock"
WORKTREE = "worktree"
SETTLE_SECONDS = 2.0
CHECK_SECONDS = 1800
LARGEST_FILE_BYTES = 50 * 1024 * 1024
DEFAULT_MAX_MIB = 100
_FRONTMATTER_NAME = re.compile(r"^name:[ \t]*(.+?)[ \t]*$", re.MULTILINE)
_KEPT_FINDINGS = 50
_SAFE_NAME = re.compile(r"[A-Za-z0-9._-]+")


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


@dataclass
class Applied:
    """A skill whose new state is in the worktree."""

    work: Work
    entry_name: str
    digest: str | None
    forgotten: bool = False


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


def _too_large(form: normal.NormalForm, limit_mib: int) -> bool:
    total = 0
    for source in form.files.values():
        size = os.path.getsize(source)
        if size > LARGEST_FILE_BYTES:
            return True
        total += size
    return total > limit_mib * 1024 * 1024


def _rejection(path: str | None, form: normal.NormalForm | None, name: str | None, limit_mib: int) -> str | None:
    """Why this copy cannot be captured at all."""
    if path is None or form is None:
        return "skill-invalid"
    if form.unsafe:
        return "unsafe-link"
    if _too_large(form, limit_mib):
        return "too-large"
    if not name or not _SAFE_NAME.fullmatch(name) or name.startswith(reconcile.FRAMEWORK_PREFIX):
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


def _file_sha256(path: str) -> str:
    import hashlib

    with open(path, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def _notify(name: str, reason: str) -> None:
    """Tells the desktop, where there is one: a name and a word, never any content."""
    if shutil.which("notify-send") is None:
        return
    shown = name if _SAFE_NAME.fullmatch(name) else "a skill"
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
    context: Mapping[str, Any], worktree: str, machine: str, decline: str | None, accepted: str | None = None
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
    text = host.declined_text(current, facts if isinstance(facts, dict) else {}, decline, accepted=accepted)
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


def _apply_copy(
    context: Mapping[str, Any],
    work: Work,
    worktree: str,
    tree: Mapping[str, str],
    document: dict[str, Any],
    base: Mapping[str, Any],
    attempt: _Attempt,
    limit_mib: int,
) -> list[str]:
    """Replays one skill onto the tree; the paths the commit may touch."""
    machine = reconcile.machine_name(context)
    declined_here = reconcile.declined_in(worktree, machine)
    if work.name in declined_here and not work.answer:
        # The tip knows the answer, whatever this machine forgot.
        attempt.declined.append(work)
        return []
    path = work.path if work.path and os.path.isdir(work.path) else None
    form = normal.normal_form(os.path.realpath(path), os.path.join(worktree, ".gitignore")) if path else None
    declared = _frontmatter_name(path) if path else None
    if form is not None and work.item.get("blocked_digest") == form.digest:
        attempt.repeated.append(work)
        return []
    reason = _rejection(path, form, declared, limit_mib)
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
    answered = bool(answer.get("ours") or answer.get("own"))
    if entry is None:
        if known is not None and known == local:
            attempt.finished.append(work)
            return []
        if known is not None and not answered:
            attempt.conflicts.append(work)
            return []
    elif not answered and (not own or known != remote):
        attempt.conflicts.append(work)
        return []
    destination = os.path.join(worktree, tree["vendor"], directory)
    _copy_form(form, destination)
    if normal.plain_digest(destination) != local:
        # The copy changed under our feet: next time.
        attempt.repeated.append(work)
        return []
    skill_digest = _file_sha256(os.path.join(destination, reconcile.SKILL_FILE))
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
    if machine and (answer.get("here") or work.name in declined_here):
        accepted = work.name if work.name in declined_here else None
        allowed.append(_write_host_file(context, worktree, machine, None, accepted=accepted))
    return allowed


def _apply_decline(context: Mapping[str, Any], work: Work, worktree: str, attempt: _Attempt) -> list[str]:
    machine = reconcile.machine_name(context)
    if not machine:
        attempt.rejected.append((work, "machine-name-required", None))
        return []
    relative = _write_host_file(context, worktree, machine, work.name)
    attempt.applied.append(Applied(work, work.name, None))
    return [relative]


def _apply_forget(
    work: Work, worktree: str, tree: Mapping[str, str], document: dict[str, Any], attempt: _Attempt
) -> list[str]:
    entries: list[Any] = document["skills"]
    entry = _entry_named(entries, work.name) or _entry_of_copy(entries, work.name)
    if entry is None:
        attempt.finished.append(work)
        return []
    directory = str(entry.get("directory") or entry.get("name"))
    shutil.rmtree(os.path.join(worktree, tree["vendor"], directory), ignore_errors=True)
    entries.remove(entry)
    attempt.applied.append(Applied(work, str(entry["name"]), None, forgotten=True))
    return [os.path.join(tree["vendor"], directory)]


def _subject(applied: Sequence[Applied]) -> str:
    names = ", ".join(item.entry_name for item in applied)
    if any(item.forgotten for item in applied):
        return f"chore(skills): forget {names}"
    if any(item.work.answer.get("never") for item in applied):
        return f"chore(skills): decline {names}"
    return f"chore(skills): capture {names}"


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
    limit = int(context.get("capture_max_mib") or DEFAULT_MAX_MIB)
    allowed = [loaded_tree["lock"]]
    for item in work:
        if item.answer.get("never"):
            allowed += _apply_decline(context, item, worktree, attempt)
        elif item.answer.get("forget"):
            allowed += _apply_forget(item, worktree, loaded_tree, document, attempt)
        else:
            allowed += _apply_copy(context, item, worktree, loaded_tree, document, base, attempt, limit)
    if not attempt.applied:
        return None, attempt
    allowed += _announce_machine(context, worktree)
    if json.dumps(document, sort_keys=True) != before:
        _write_tree_lock(worktree, loaded_tree["lock"], document)
    for path in allowed:
        added = publish.git(worktree, "-c", f"core.excludesFile={os.devnull}", "add", "-A", "-f", "--", path)
        if added.code != 0 and os.path.lexists(os.path.join(worktree, path)):
            raise OSError(f"git add failed: {added.stderr.strip()}")
    _check_paths(worktree, tip, allowed)
    _run_checks(worktree, summary)
    message = host.commit_message(_subject(attempt.applied), reconcile.machine_name(context))
    identity = host.commit_identity(Path(worktree), tip)
    committed = publish.git(worktree, *identity, "commit", "--quiet", "-F", "-", env={"TZ": "UTC"}, stdin=message)
    if committed.code != 0:
        raise ChecksRed("commit-refused", [committed.stderr.strip()[-400:]])
    return publish.git(worktree, "rev-parse", "HEAD").stdout.strip(), attempt


# --- what a run makes of it ---------------------------------------------------------------


def _set_blocked(state_root: str, work: Work, reason: str, digest: str | None) -> None:
    fields = {
        "state": reconcile.BLOCKED,
        "reason": reason,
        "blocked_digest": digest,
        "digest": digest,
        "last_asked": None,
    }
    state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
    _notify(work.name, reason)


def _identity_fields(work: Work) -> dict[str, Any]:
    return {"kind": "skill", "name": work.name, "path": work.path, "origin": work.item.get("origin", "own")}


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
        fields = {"state": reconcile.CONFLICT, "reason": None, "digest": digest, "conflict_digest": digest}
        if work.item.get("conflict_digest") != digest:
            fields["last_asked"] = None
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        summary.conflicts.append(work.name)
        summary.codes.append(report.PENDING)
    for work in attempt.taken:
        digest = work.item.get("digest")
        fields = {"state": reconcile.NAME_TAKEN, "reason": None, "blocked_digest": digest, "last_asked": None}
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        summary.conflicts.append(work.name)
        summary.codes.append(report.PENDING)
    for work in attempt.declined:
        fields = {"state": reconcile.DECLINED, "reason": None, "last_asked": None}
        state.set_item(state_root, work.key, {**_identity_fields(work), **fields})
        state.forget_base(state_root, work.name)
        summary.done.append(work.name)
    for work, reason, digest in attempt.rejected:
        _set_blocked(state_root, work, reason, digest)
        _say(f"skill {work.name} was not published: {reason}")
        summary.blocked.append(work.name)
        summary.codes.append(report.FAILED)
    for work, name, digest in attempt.in_sync:
        state.record_base(state_root, name, digest, published.tip or "", work.path or "")
        _drop_unless_changed(state_root, work)
        summary.done.append(work.name)
    for work in attempt.repeated:
        previous = work.item
        if previous.get("blocked_digest"):
            fields = {"state": reconcile.BLOCKED, "digest": previous.get("blocked_digest")}
            state.set_item(state_root, work.key, fields)
    for work in attempt.finished:
        state.drop_item(state_root, work.key)
    summary.dropped.update({name: paths for name, paths in attempt.dropped.items() if paths})


def _record_applied(state_root: str, attempt: _Attempt, commit: str, summary: Summary) -> None:
    for applied in attempt.applied:
        work = applied.work
        if applied.forgotten:
            state.forget_base(state_root, applied.entry_name)
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
            state.forget_base(state_root, work.name)
            summary.done.append(work.name)
        else:
            state.record_base(state_root, applied.entry_name, applied.digest or "", commit, work.path or "")
            if work.key != state.skill_key(applied.entry_name):
                state.drop_item(state_root, state.skill_key(applied.entry_name))
            _drop_unless_changed(state_root, work)
            summary.captured.append(applied.entry_name)


def _mark_waiting(state_root: str, work: Sequence[Work], reason: str, summary: Summary) -> None:
    now = time.time()
    for item in work:
        since = item.item.get("offline_since") if item.item.get("reason") == reason else None
        fields = {
            **_identity_fields(item),
            "state": reconcile.CAPTURE,
            "reason": reason,
            "offline_since": since or now,
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

    def build(tip: str) -> str | None:
        commit, attempt = _build_on(context, tree, work, tip, summary)
        last["attempt"] = attempt
        return commit

    try:
        published = publish.publish(instance, tree["branch"], "skill", build)
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
        _set_blocked(state_root, item, red.reason, digest)
        summary.findings += red.findings
        summary.blocked.append(item.name)
        summary.codes.append(report.PRIVACY_STOP if red.reason == "privacy" else report.FAILED)
        _say(f"skill {item.name} was not published: {red.reason}; dotsteward skills status has the findings")
        return
    except ChecksUnavailable as unavailable:
        _say(f"the checks of the instance cannot run: {unavailable}")
        _mark_waiting(state_root, work, "checks-unavailable", summary)
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
            _set_blocked(state_root, item, "remote-refused", digest)
            summary.blocked.append(item.name)
            summary.codes.append(report.FAILED)
        return
    if published.outcome == publish.NETWORK:
        _say(f"no network or no answer from the remote: {published.detail}")
        _mark_waiting(state_root, work, "offline", summary)
        return
    _say("other machines kept pushing; the skills wait for the next run")
    _mark_waiting(state_root, work, "race", summary)


# --- a run --------------------------------------------------------------------------------


def _ready(context: Mapping[str, Any], names: Sequence[str] | None, handled: set[str]) -> list[Work]:
    """The items that wait for a capture; each only once in a run."""
    document = state.load_pending(str(context["state_root"]))
    work = []
    for key, item in document["items"].items():
        if (
            not isinstance(item, dict)
            or item.get("state") != reconcile.CAPTURE
            or item.get("kind", "skill") != "skill"
            or key in handled
        ):
            continue
        name = str(item.get("name"))
        if names and name not in names:
            continue
        path = item.get("path")
        answer = item.get("answer")
        if not answer and isinstance(path, str) and not os.path.isdir(path):
            state.drop_item(str(context["state_root"]), key)
            continue
        work.append(
            Work(key, name, item, path if isinstance(path, str) else None, answer if isinstance(answer, dict) else {})
        )
    return work


def _newest_change(path: str) -> float:
    newest = 0.0
    for directory, _, files in os.walk(path):
        for name in (".", *files):
            with contextlib.suppress(OSError):
                newest = max(newest, os.lstat(os.path.join(directory, name)).st_mtime)
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


def run_now(context: Mapping[str, Any], tree: Mapping[str, str], names: Sequence[str] | None = None) -> Summary:
    """One capture run: publishes what waits and reads pending.json again before it ends."""
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
    try:
        sleeper.log(state_root, "run")
        while True:
            work = _ready(context, names, handled)
            if not work:
                break
            ready = _settled(work)
            handled.update(item.key for item in work)
            if not ready:
                continue
            ran = True
            answers = [item for item in ready if item.answer.get("never") or item.answer.get("forget")]
            captures = [item for item in ready if item not in answers]
            for batch in [[item] for item in answers] + ([captures] if captures else []):
                _cycle(context, tree, batch, summary)
    except (normal.NormalFormError, OSError, ValueError, config.DotstewardError, host.Refusal) as error:
        _say(f"the capture failed: {error}")
        sleeper.log(state_root, f"failed: {error}")
        summary.codes.append(report.FAILED)
    finally:
        if ran:
            _remove_worktree(instance, _worktree(context))
            _write_last(state_root, summary)
        lock.release()
    return summary
