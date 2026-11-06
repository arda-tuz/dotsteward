"""The answers to what skill tracking asks: ``track``, ``resolve``, ``diff``, ``forget``
and ``restore``.

An answer is a note on the pending item, which ``capture`` carries out, so it survives a
missing network like any other change. ``--all`` of a downloaded skill pins its upstream:
the HEAD of a clone, or the commit whose tree a record of `npx skills` names (the record
holds a tree digest and no commit, so a partial clone looks for it). Without such a commit
the answer is refused and offers ``--own``, a copy of your own without an upstream; a
third-party skill also needs a license, which ``static`` holds it to.

``--never`` lands in ``hosts/<machine>.toml``, so a reinstall under the same name remembers
it, and stays in pending.json for the checkout that is behind.

Exit status: 0 done, 1 refused, 3 a conflict waits, 4 a privacy stop, 6 no network.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
from collections.abc import Mapping
from typing import Any

from dotsteward_cli import atomic, config, locks, publish, report
from dotsteward_cli.skills import capture, hooks_install, normal, origin, reconcile, state

_PARTIAL_CLONE_SECONDS = 180


class AnswerRefused(Exception):
    """The answer cannot be carried out; the message says why."""


class Offline(Exception):
    """The remote did not answer."""


def _say(message: str) -> None:
    print(f"[dotsteward] {message}", file=sys.stderr)


def _context(loaded: config.Instance) -> dict[str, Any]:
    from dotsteward_cli.skills import commands

    if not commands.tracking_on(loaded):
        raise AnswerRefused("skill tracking is off ([skills] tracking)")
    return hooks_install.build_context(loaded)


def _local_copy(context: Mapping[str, Any], name: str, item: Mapping[str, Any] | None) -> str | None:
    path = item.get("path") if item else None
    if isinstance(path, str) and os.path.isdir(path):
        return path
    for root in context.get("roots") or []:
        candidate = os.path.join(str(root), name)
        if os.path.isfile(os.path.join(candidate, reconcile.SKILL_FILE)):
            return candidate
    return None


def _lock_entries(loaded: config.Instance) -> list[dict[str, Any]]:
    path = loaded.root / loaded.config["skills"]["lock"]
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return []
    entries = document.get("skills") if isinstance(document, dict) else None
    return [entry for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else []


def _lock_entry(loaded: config.Instance, name: str) -> dict[str, Any] | None:
    return next((e for e in _lock_entries(loaded) if name in (e.get("name"), e.get("directory"))), None)


def _normalized_url(url: str) -> str:
    """A GitHub remote as the pins engine reads it best; anything else as it is."""
    for prefix in ("git@github.com:", "ssh://git@github.com/", "https://github.com/"):
        if url.startswith(prefix):
            path = url[len(prefix) :].removesuffix("/").removesuffix(".git")
            return f"https://github.com/{path}"
    return url


def _pin_from_record(source: Mapping[str, Any]) -> dict[str, Any]:
    """The commit of the upstream whose tree of the skill is the one the record names."""
    url, skill_path, tree = source.get("url"), source.get("path"), source.get("tree")
    if not all(isinstance(value, str) and value for value in (url, skill_path, tree)):
        raise AnswerRefused("the record of this skill names no upstream; --own tracks your own copy of it")
    directory = os.path.dirname(str(skill_path))
    with tempfile.TemporaryDirectory(prefix="dotsteward-pin-") as scratch:
        cloned = publish.git(
            scratch,
            "clone",
            "--quiet",
            "--bare",
            "--filter=blob:none",
            str(url),
            "upstream",
            seconds=_PARTIAL_CLONE_SECONDS,
        )
        outcome = publish.classify(cloned)
        if outcome == publish.NETWORK:
            raise Offline(cloned.stderr.strip())
        if outcome != publish.OK:
            raise AnswerRefused(f"cannot read the upstream {url}: {cloned.stderr.strip()}; --own tracks your own copy")
        repository = os.path.join(scratch, "upstream")

        def tree_at(commit: str) -> str:
            return publish.git(repository, "rev-parse", "--verify", "--quiet", f"{commit}:{directory}").stdout.strip()

        head = publish.git(repository, "rev-parse", "HEAD").stdout.strip()
        if tree_at(head) == tree:
            return {"url": _normalized_url(str(url)), "revision": head, "path": directory}
        log = publish.git(repository, "log", "--format=%H", "HEAD", "--", directory).stdout.split()
        for commit in log:
            if tree_at(commit) == tree:
                return {"url": _normalized_url(str(url)), "revision": commit, "path": directory}
    raise AnswerRefused(
        f"no commit of {url} has the tree this skill was installed from; --own tracks your own copy of it"
    )


def _pinned_source(item: Mapping[str, Any]) -> dict[str, Any]:
    source = item.get("source")
    if not isinstance(source, Mapping):
        raise AnswerRefused("nothing says where this skill comes from; --own tracks your own copy of it")
    if source.get("revision"):
        if not source.get("url"):
            raise AnswerRefused("this clone has no remote; --own tracks your own copy of it")
        return {
            "url": _normalized_url(str(source["url"])),
            "revision": source["revision"],
            "path": source.get("path") or ".",
        }
    return _pin_from_record(source)


def _finish(context: Mapping[str, Any], loaded: config.Instance, name: str) -> int:
    """Carries out the answer now."""
    summary = capture.run_now(context, capture.tree_paths(loaded), [name])
    return summary.code


def track(loaded: config.Instance, name: str, *, here: bool, never: bool, own: bool, capture_now: bool) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = state.skill_key(name)
        item = state.load_pending(state_root)["items"].get(key)
        item = item if isinstance(item, dict) else None
        path = _local_copy(context, name, item)
        entry = _lock_entry(loaded, name)
        if path is None and entry is None:
            raise AnswerRefused(f"no skill {name} on this machine")
        machine = reconcile.machine_name(context)
        if (here or never) and not machine:
            raise AnswerRefused("this machine has no name yet: 'dotsteward host init' names it")
        answer: dict[str, Any] = {}
        if never:
            answer["never"] = True
        else:
            if path is None:
                raise AnswerRefused(f"no local copy of {name} to track")
            answer["here"] = here
            known_origin = (item or {}).get("origin")
            if known_origin is None:
                known_origin, source = origin.classify(name, path, None)
                item = {**(item or {}), "origin": known_origin, "source": source}
            if own or known_origin == origin.OWN:
                answer["own"] = True
            elif known_origin == origin.UNKNOWN:
                raise AnswerRefused(f"nothing says where {name} comes from; --own tracks your own copy of it")
            elif os.path.exists(os.path.join(path, ".git")):
                # The commit it is at now, not when it was first seen.
                answer["source"] = _pinned_source({"source": origin.git_source(path)})
            else:
                answer["source"] = _pinned_source(item or {})
        fields = {
            "kind": "skill",
            "name": name,
            "path": path,
            "state": reconcile.CAPTURE,
            "origin": (item or {}).get("origin", origin.OWN),
            "answer": answer,
            "reason": None,
            "detected_at": time.time(),
            "blocked_digest": None,
        }
        state.set_item(state_root, key, fields)
        return _finish(context, loaded, name) if capture_now else 0
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED
    except Offline as offline:
        _say(f"no network or no answer from the upstream: {offline}")
        return report.PARTIAL


def _home() -> str:
    return os.environ.get("HOME") or os.path.expanduser("~")


# --- the tree on the remote -------------------------------------------------------------------


def _fetch(context: Mapping[str, Any], loaded: config.Instance) -> str:
    """The tip of the remote."""
    outcome, tip, detail = publish.fetch_tip(context["instance"], str(loaded.config["instance"]["branch"]), "skill")
    if outcome == publish.NETWORK:
        raise Offline(detail)
    if outcome != publish.OK:
        raise AnswerRefused(f"the remote refused: {detail}")
    return tip


def _extract(instance: str, commit: str, path: str, destination: str) -> bool:
    """The tree PATH of COMMIT at DESTINATION; False when COMMIT does not hold it."""
    import subprocess

    archive = subprocess.run(
        ["git", "-C", instance, "archive", "--format=tar", commit, "--", path],
        capture_output=True,
        env=publish.clean_env(),
        check=False,
    )
    if archive.returncode != 0:
        return False
    with tempfile.TemporaryDirectory(prefix="dotsteward-tree-") as scratch:
        with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
            tar.extractall(scratch, filter="data")
        shutil.rmtree(destination, ignore_errors=True)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.move(os.path.join(scratch, path), destination)
    return True


def _entry_at(context: Mapping[str, Any], loaded: config.Instance, tip: str, name: str) -> dict[str, Any] | None:
    relative = str(loaded.config["skills"]["lock"])
    shown = publish.git(str(context["instance"]), "show", f"{tip}:{relative}")
    if shown.code != 0:
        return None
    try:
        document = json.loads(shown.stdout)
    except ValueError:
        return None
    entries = document.get("skills") if isinstance(document, dict) else None
    for entry in entries if isinstance(entries, list) else []:
        if isinstance(entry, dict) and name in (entry.get("name"), entry.get("directory")):
            return entry
    return None


def _vendor_path(loaded: config.Instance, entry: Mapping[str, Any]) -> str:
    return f"{str(loaded.config['skills']['vendor_dir']).rstrip('/')}/{entry.get('directory') or entry.get('name')}"


def _backup(state_root: str, path: str) -> str:
    """A copy of PATH below ``<state>/backups/<UTC>-skills/files/<absolute path>``."""
    real = os.path.realpath(path)
    root = os.path.join(state_root, "backups", time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-skills")
    atomic.make_private_dirs(root)
    destination = os.path.join(root, "files", real.lstrip("/"))
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.copytree(real, destination, symlinks=True, dirs_exist_ok=True)
    return root


def _install_from(
    context: Mapping[str, Any], loaded: config.Instance, tip: str, entry: Mapping[str, Any], path: str
) -> str:
    """Replaces the copy at PATH with the skill of the commit TIP; the lock digest."""
    state_root = str(context["state_root"])
    instance = str(context["instance"])
    staging_root = os.path.join(state_root, "staging")
    atomic.make_private_dirs(staging_root)
    with tempfile.TemporaryDirectory(dir=staging_root, prefix="skill.") as scratch:
        staged = os.path.join(scratch, "copy")
        if not _extract(instance, tip, _vendor_path(loaded, entry), staged):
            raise AnswerRefused("the remote does not hold this skill")
        real = os.path.realpath(path) if os.path.lexists(path) else path
        shutil.rmtree(real, ignore_errors=True)
        os.makedirs(os.path.dirname(real), exist_ok=True)
        shutil.move(staged, real)
    digest = entry.get("directory_sha256")
    return str(digest) if isinstance(digest, str) and digest else normal.plain_digest(path)


def _capture_locked(state_root: str) -> locks.FileLock:
    atomic.make_private_dirs(state.directory(state_root))
    lock = locks.FileLock(os.path.join(state.directory(state_root), capture.CAPTURE_LOCK))
    lock.acquire()
    return lock


# --- the commands -----------------------------------------------------------------------------


def resolve(loaded: config.Instance, name: str, *, ours: bool) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = state.skill_key(name)
        item = state.load_pending(state_root)["items"].get(key)
        if not isinstance(item, dict) or item.get("state") != reconcile.CONFLICT:
            raise AnswerRefused(f"no conflict about {name}")
        if ours:
            state.set_item(state_root, key, {"state": reconcile.CAPTURE, "answer": {"ours": True}, "reason": None})
            return _finish(context, loaded, name)
        path = item.get("path")
        if not isinstance(path, str) or not os.path.isdir(path):
            raise AnswerRefused(f"no local copy of {name}")
        lock = _capture_locked(state_root)
        try:
            tip = _fetch(context, loaded)
            entry = _entry_at(context, loaded, tip, name)
            if entry is None:
                raise AnswerRefused(f"the remote has no skill {name}")
            backup = _backup(state_root, path)
            digest = _install_from(context, loaded, tip, entry, path)
            state.record_base(state_root, str(entry["name"]), digest, tip, path)
            state.drop_item(state_root, key)
            _say(f"{name}: the copy of the remote is installed; the local copy is in {backup}")
        finally:
            lock.release()
        return report.OK
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED
    except Offline as offline:
        _say(f"no network or no answer from the remote: {offline}")
        return report.PARTIAL


def diff(loaded: config.Instance, name: str, *, as_json: bool) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        items = state.load_pending(state_root)["items"]
        item = items.get(state.skill_key(name))
        path = _local_copy(context, name, item if isinstance(item, dict) else None)
        record = state.base_entry(state.load_base(state_root), name)
        tip = _fetch(context, loaded)
        entry = _entry_at(context, loaded, tip, name)
        if entry is None and path is None:
            raise AnswerRefused(f"no skill {name} on this machine or on the remote")
        trees = os.path.join(state.directory(state_root), "diff", name)
        document: dict[str, Any] = {
            "name": name,
            "local": path,
            "remote": None,
            "base": None,
            "remote_commit": tip,
            "base_commit": record.get("base_commit") if record else None,
        }
        instance = str(context["instance"])
        if entry is not None and _extract(instance, tip, _vendor_path(loaded, entry), os.path.join(trees, "remote")):
            document["remote"] = os.path.join(trees, "remote")
        commit = document["base_commit"]
        has_base = entry is not None and isinstance(commit, str) and commit
        if has_base and _extract(instance, str(commit), _vendor_path(loaded, entry or {}), os.path.join(trees, "base")):
            document["base"] = os.path.join(trees, "base")
        if as_json:
            print(json.dumps(document, indent=2))
        else:
            for key in ("local", "remote", "base"):
                print(f"[dotsteward] {key}: {document[key] or '(none)'}")
        return report.OK
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED
    except Offline as offline:
        _say(f"no network or no answer from the remote: {offline}")
        return report.PARTIAL


def forget(loaded: config.Instance, name: str) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = state.skill_key(name)
        known = state.base_entry(state.load_base(state_root), name) is not None
        if _lock_entry(loaded, name) is None and not known:
            raise AnswerRefused(f"no skill {name} in the lock")
        item = state.load_pending(state_root)["items"].get(key)
        path = _local_copy(context, name, item if isinstance(item, dict) else None)
        fields = {
            "kind": "skill",
            "name": name,
            "path": path,
            "state": reconcile.CAPTURE,
            "origin": origin.OWN,
            "answer": {"forget": True},
            "reason": None,
            "detected_at": time.time(),
        }
        state.set_item(state_root, key, fields)
        return _finish(context, loaded, name)
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED


def restore(loaded: config.Instance, name: str) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = state.skill_key(name)
        item = state.load_pending(state_root)["items"].get(key)
        if _local_copy(context, name, item if isinstance(item, dict) else None) is not None:
            raise AnswerRefused(f"{name} is here already; nothing to restore")
        lock = _capture_locked(state_root)
        try:
            tip = _fetch(context, loaded)
            entry = _entry_at(context, loaded, tip, name)
            if entry is None:
                raise AnswerRefused(f"the remote has no skill {name}")
            directory = str(entry.get("directory") or entry.get("name"))
            path = os.path.join(_home(), ".agents", "skills", directory)
            digest = _install_from(context, loaded, tip, entry, path)
            state.record_base(state_root, str(entry["name"]), digest, tip, path)
            state.drop_item(state_root, key)
            with contextlib.suppress(OSError):
                state.change_pending(
                    state_root, lambda document: document.get("missing", {}).pop(key, None) is not None
                )
            _say(f"{name}: installed from the remote into {path}; the next rebuild links it")
        finally:
            lock.release()
        return report.OK
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED
    except Offline as offline:
        _say(f"no network or no answer from the remote: {offline}")
        return report.PARTIAL
