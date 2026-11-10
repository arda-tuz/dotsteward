"""The answers to what skill tracking asks: ``track``, ``resolve``, ``diff``, ``forget``,
``restore`` and ``retry``.

An answer is a note on the pending item, which ``capture`` carries out, so it survives a
missing network like any other change. ``--all`` of a downloaded skill pins its upstream:
the HEAD of a clone, or the commit whose tree a record of `npx skills` names (the record
holds a tree digest and no commit, so a partial clone looks for it). Without such a commit
the answer is refused and offers ``--own``, a copy of your own without an upstream; a
third-party skill also needs a license, which ``static`` holds it to.

``--never`` lands in ``hosts/<machine>.toml``, so a reinstall under the same name remembers
it, and stays in pending.json for the checkout that is behind. Only ``--never`` declines:
``--later`` puts the question off, declines nothing and publishes nothing. Every answer stays
on the item as ``answered`` (which one, and when), so a decline can always be told from a
question nobody answered. ``--all`` or ``--here`` takes a decline back.

A plugin answers the same way (``plugins``). A plugin of a marketplace goes by its spec,
``NAME@MARKETPLACE``: ``--all`` and ``--here`` add it to options.plugins, and ``--own`` does
not apply, because the marketplace is where it comes from. Any other plugin in
``~/.claude/skills`` is an own plugin, or with ``--own`` your copy of somebody else's.

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

from dotsteward_cli import atomic, config, locks, publish, report, tomlfile
from dotsteward_cli.skills import capture, hooks_install, normal, origin, plugins, reconcile, state

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


def _lock_entry(loaded: config.Instance, name: str, key: str = "skills") -> dict[str, Any] | None:
    entries = state.lock_entries(loaded.root / loaded.config["skills"]["lock"], key) or []
    return next((e for e in entries if name in (e.get("name"), e.get("directory"))), None)


def _own_plugin_copy(name: str, item: Mapping[str, Any] | None) -> str | None:
    path = item.get("path") if item else None
    if isinstance(path, str) and os.path.isdir(path):
        return path
    return plugins.own_copy(name)


def _is_plugin(loaded: config.Instance, state_root: str, name: str) -> bool:
    """Whether NAME is a plugin to this machine rather than a skill."""
    items = state.load_pending(state_root)["items"]
    if isinstance(items.get(state.skill_key(name)), dict):
        return False
    if isinstance(items.get(state.plugin_key(name)), dict) or plugins.is_spec(name):
        return True
    if _lock_entry(loaded, name) is not None:
        return False
    return (
        _lock_entry(loaded, name, "own_plugins") is not None
        or state.plugin_key(name) in state.load_base(state_root)
        or _own_plugin_copy(name, None) is not None
    )


def _key(loaded: config.Instance, state_root: str, name: str) -> str:
    return state.plugin_key(name) if _is_plugin(loaded, state_root, name) else state.skill_key(name)


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


def _ended(signum: int, _frame: Any) -> None:
    raise SystemExit(128 + signum)


def _finish(context: Mapping[str, Any], loaded: config.Instance, name: str) -> int:
    """Carries out the answer now. A terminal that closes or a TERM ends it as an exception,
    so the capture lock goes and the evaluation it started ends with it; the answer waits."""
    import signal

    previous = {number: signal.signal(number, _ended) for number in (signal.SIGTERM, signal.SIGHUP)}
    try:
        summary = capture.run_now(context, capture.tree_paths(loaded), [name], maintain=True)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    return summary.code


def _plugin_answer(
    loaded: config.Instance, context: Mapping[str, Any], name: str, *, here: bool, never: bool, own: bool
) -> dict[str, Any]:
    """The fields of the item of the plugin NAME that carry the answer."""
    state_root = str(context["state_root"])
    item = state.load_pending(state_root)["items"].get(state.plugin_key(name))
    item = item if isinstance(item, dict) else None
    machine = reconcile.machine_name(context)
    if (here or never) and not machine:
        raise AnswerRefused("this machine has no name yet: 'dotsteward host init' names it")
    fields: dict[str, Any] = {
        "kind": state.PLUGIN,
        "name": name,
        "state": reconcile.CAPTURE,
        "reason": None,
        "detected_at": time.time(),
        "blocked_digest": None,
    }
    if plugins.is_spec(name):
        source = item.get("source") if item else None
        if not (isinstance(source, dict) and source.get("marketplace")):
            source = plugins.candidates().get(name)
        if source is None:
            raise AnswerRefused(f"no plugin {name} of a GitHub marketplace is installed at user scope here")
        if own:
            raise AnswerRefused(
                f"{name} comes from its marketplace, so --own does not apply; --all or --here tracks it"
            )
        answer = {"never": True} if never else {"here": here}
        return {**fields, "path": None, "origin": origin.DOWNLOADED, "source": source, "answer": answer}
    path = _own_plugin_copy(name, item)
    known = item is not None or state.plugin_key(name) in state.load_base(state_root)
    if path is None and _lock_entry(loaded, name, "own_plugins") is None and not known:
        raise AnswerRefused(f"no plugin {name} on this machine")
    if never:
        return {**fields, "path": path, "origin": (item or {}).get("origin", origin.OWN), "answer": {"never": True}}
    if path is None:
        raise AnswerRefused(f"no local copy of {name} to track")
    where = (item or {}).get("origin") or origin.classify(name, path, None).where
    if not (own or where == origin.OWN):
        raise AnswerRefused(f"{name} comes from no marketplace and was not made here; --own tracks your own copy of it")
    return {**fields, "path": path, "origin": where, "answer": {"here": here, "own": True}}


# The questions an answer can put off; the others have commands of their own.
_PUT_OFF = frozenset({reconcile.ASK, reconcile.DELETED, reconcile.NAME_TAKEN})


def _answered(answer: Mapping[str, Any]) -> dict[str, Any]:
    """What the user answered and when. It stays on the item, so a decline keeps its reason."""
    word = "never" if answer.get("never") else "here" if answer.get("here") else "all"
    return {"answer": word, "own": bool(answer.get("own")), "at": time.time()}


def put_off(loaded: config.Instance, name: str) -> int:
    """--later: nothing is decided and nothing published; no session asks about it again
    while the question stays the same, and ``skills status`` keeps listing it."""
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = _key(loaded, state_root, name)
        item = state.load_pending(state_root)["items"].get(key)
        if not isinstance(item, dict) or item.get("state") not in _PUT_OFF:
            raise AnswerRefused(f"nothing asks about {name} now")
        answered = {"answer": "later", "at": time.time(), "state": item["state"]}
        state.set_item(state_root, key, {"answered": answered})
        _say(
            f"{name}: put off, nothing declined; no session asks about it again. "
            f"dotsteward skills status lists it, and dotsteward skills track {name} --all, --here or --never "
            "answers it"
        )
        return report.OK
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED


def track(loaded: config.Instance, name: str, *, here: bool, never: bool, own: bool, capture_now: bool) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        if _is_plugin(loaded, state_root, name):
            fields = _plugin_answer(loaded, context, name, here=here, never=never, own=own)
            fields["answered"] = _answered(fields["answer"])
            state.set_item(state_root, state.plugin_key(name), fields)
            return _finish(context, loaded, name) if capture_now else 0
        key = state.skill_key(name)
        item = state.load_pending(state_root)["items"].get(key)
        item = item if isinstance(item, dict) else None
        path = _local_copy(context, name, item)
        entry = _lock_entry(loaded, name)
        known = item is not None or state.base_entry(state.load_base(state_root), name) is not None
        if path is None and entry is None and not known:
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
            if not own and known_origin != origin.OWN:
                # Looked at again: the commit a clone is at now, and a clone that was not clean
                # or had no remote when the skill was first seen may be fine by now.
                found = origin.classify(name, path, (item or {}).get("evidence"))
                known_origin = found.where
                item = {**(item or {}), "origin": found.where, "source": found.source, "origin_detail": found.detail}
            if own or known_origin == origin.OWN:
                answer["own"] = True
            elif known_origin == origin.UNKNOWN:
                detail = (item or {}).get("origin_detail")
                why = f": {detail}" if detail else ""
                raise AnswerRefused(f"nothing says where {name} comes from{why}; --own tracks your own copy of it")
            else:
                answer["source"] = _pinned_source(item or {})
        fields = {
            "kind": "skill",
            "name": name,
            "path": path,
            "state": reconcile.CAPTURE,
            "origin": (item or {}).get("origin", origin.OWN),
            "origin_detail": (item or {}).get("origin_detail"),
            "answer": answer,
            "answered": _answered(answer),
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


def _entry_at(
    context: Mapping[str, Any], loaded: config.Instance, tip: str, name: str, kind: str = state.SKILL
) -> dict[str, Any] | None:
    relative = str(loaded.config["skills"]["lock"])
    shown = publish.git(str(context["instance"]), "show", f"{tip}:{relative}")
    if shown.code != 0:
        return None
    try:
        document = json.loads(shown.stdout)
    except ValueError:
        return None
    lists = "own_plugins" if kind == state.PLUGIN else "skills"
    entries = document.get(lists) if isinstance(document, dict) else None
    for entry in entries if isinstance(entries, list) else []:
        if isinstance(entry, dict) and name in (entry.get("name"), entry.get("directory")):
            return {**entry, "kind": state.PLUGIN} if kind == state.PLUGIN else entry
    return None


def _vendor_path(loaded: config.Instance, entry: Mapping[str, Any]) -> str:
    """Where the tree keeps ENTRY; ``_entry_at`` marks an own plugin, which lives apart."""
    if entry.get("kind") == state.PLUGIN:
        root = plugins.OWN_PLUGINS_DIR
    else:
        root = str(loaded.config["skills"]["vendor_dir"]).rstrip("/")
    return f"{root}/{entry.get('directory') or entry.get('name')}"


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
    # What the normal form leaves out stays, as long as a rule of the new copy covers it.
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
        kept = os.path.join(scratch, "kept")
        os.mkdir(kept)
        if os.path.isdir(real):
            normal.keep_left_out(real, os.path.join(instance, ".gitignore"), kept)
        shutil.rmtree(real, ignore_errors=True)
        os.makedirs(os.path.dirname(real), exist_ok=True)
        shutil.move(staged, real)
        for name in normal.restore_left_out(kept, real, os.path.join(instance, ".gitignore")):
            _say(f"{entry.get('name')}: {name}: no ignore rule covers it now; it stays in the backup")
    digest = entry.get("directory_sha256")
    return str(digest) if isinstance(digest, str) and digest else normal.plain_digest(path)


def _capture_locked(state_root: str) -> locks.FileLock:
    atomic.make_private_dirs(state.directory(state_root))
    lock = locks.FileLock(os.path.join(state.directory(state_root), capture.CAPTURE_LOCK))
    lock.acquire()
    return lock


# --- the commands -----------------------------------------------------------------------------


def _kind(loaded: config.Instance, state_root: str, name: str) -> str:
    return state.PLUGIN if _is_plugin(loaded, state_root, name) else state.SKILL


def _copy_of(context: Mapping[str, Any], kind: str, name: str, item: Mapping[str, Any] | None) -> str | None:
    return _own_plugin_copy(name, item) if kind == state.PLUGIN else _local_copy(context, name, item)


def _holds_nothing_new(
    context: Mapping[str, Any], state_root: str, kind: str, name: str, item: Mapping[str, Any]
) -> bool:
    """Whether the copy in conflict is the one this machine last had in sync: the conflict is
    then only a newer copy that could not be installed here."""
    if item.get("reason") == reconcile.NOT_REFRESHED:
        return True
    record = state.base_entry(state.load_base(state_root), name, kind)
    path = item.get("path")
    if record is None or not isinstance(path, str) or not os.path.isdir(path):
        return False
    try:
        local = normal.normal_form(os.path.realpath(path), os.path.join(str(context["instance"]), ".gitignore"))
    except (normal.NormalFormError, OSError):
        return False
    return bool(local.digest == record["base_sha256"])


def resolve(loaded: config.Instance, name: str, *, ours: bool) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        kind = _kind(loaded, state_root, name)
        key = state.item_key(kind, name)
        item = state.load_pending(state_root)["items"].get(key)
        if not isinstance(item, dict) or item.get("state") != reconcile.CONFLICT:
            raise AnswerRefused(f"no conflict about {name}")
        if ours:
            if _holds_nothing_new(context, state_root, kind, name, item):
                raise AnswerRefused(
                    f"the copy of {name} here is what this machine last had in sync, and the repository "
                    f"holds a newer one: --ours would publish the older copy over it; "
                    f"'dotsteward skills resolve {name} --theirs' installs the newer one"
                )
            state.set_item(state_root, key, {"state": reconcile.CAPTURE, "answer": {"ours": True}, "reason": None})
            return _finish(context, loaded, name)
        path = item.get("path")
        if not isinstance(path, str) or not os.path.isdir(path):
            raise AnswerRefused(f"no local copy of {name}")
        lock = _capture_locked(state_root)
        try:
            tip = _fetch(context, loaded)
            entry = _entry_at(context, loaded, tip, name, kind)
            if entry is None:
                raise AnswerRefused(f"the remote has no {kind} {name}")
            backup = _backup(state_root, path)
            digest = _install_from(context, loaded, tip, entry, path)
            state.record_base(state_root, str(entry["name"]), digest, tip, path, kind)
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
        kind = _kind(loaded, state_root, name)
        item = items.get(state.item_key(kind, name))
        path = _copy_of(context, kind, name, item if isinstance(item, dict) else None)
        record = state.base_entry(state.load_base(state_root), name, kind)
        tip = _fetch(context, loaded)
        entry = _entry_at(context, loaded, tip, name, kind)
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
        kind = _kind(loaded, state_root, name)
        if plugins.is_spec(name):
            raise AnswerRefused(
                f"{name} is a plugin of a marketplace: its table in workstation.toml takes it from all machines, "
                f"'skills track {name} --never' from this one"
            )
        key = state.item_key(kind, name)
        known = state.base_entry(state.load_base(state_root), name, kind) is not None
        if _lock_entry(loaded, name, "own_plugins" if kind == state.PLUGIN else "skills") is None and not known:
            raise AnswerRefused(f"no {kind} {name} in the lock")
        item = state.load_pending(state_root)["items"].get(key)
        path = _copy_of(context, kind, name, item if isinstance(item, dict) else None)
        fields = {
            "kind": kind,
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


def _declined_at(context: Mapping[str, Any], tip: str, machine: str | None, kind: str = state.SKILL) -> set[str]:
    """``declined.skills`` (or ``declined.plugins``) of the host file of MACHINE in the commit TIP."""
    if not machine:
        return set()
    shown = publish.git(str(context["instance"]), "show", f"{tip}:hosts/{machine}.toml")
    if shown.code != 0:
        return set()
    try:
        document = tomlfile.loads(shown.stdout)
        return plugins.declined_of(document) if kind == state.PLUGIN else reconcile.declined_of(document)
    except ValueError:
        return set()


def clear(loaded: config.Instance, name: str) -> int:
    """Another answer to what ``forget`` and ``--never`` keep out, for when no copy is left to
    answer with: the name leaves the host file and the state, and nothing is kept out."""
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        kind = _kind(loaded, state_root, name)
        key = state.item_key(kind, name)
        item = state.load_pending(state_root)["items"].get(key)
        item = item if isinstance(item, dict) else None
        path = None if plugins.is_spec(name) else _copy_of(context, kind, name, item)
        if path is not None:
            raise AnswerRefused(f"a copy of {name} is at {path}: delete it first, or answer with 'skills track {name}'")
        if not (item and item.get("state") in reconcile.KEPT_OUT) and name not in _declined_at(
            context, _fetch(context, loaded), reconcile.machine_name(context), kind
        ):
            raise AnswerRefused(f"nothing keeps {name} out on this machine")
        fields = {
            "kind": kind,
            "name": name,
            "path": None,
            "state": reconcile.CAPTURE,
            "origin": item.get("origin", origin.OWN) if item else origin.OWN,
            "answer": {"clear": True},
            "reason": None,
            "detected_at": time.time(),
        }
        state.set_item(state_root, key, fields)
        return _finish(context, loaded, name)
    except AnswerRefused as refused:
        _say(f"ERROR: {refused}")
        return report.FAILED
    except Offline as offline:
        _say(f"no network or no answer from the remote: {offline}")
        return report.PARTIAL


def retry(loaded: config.Instance, name: str) -> int:
    try:
        context = _context(loaded)
        state_root = str(context["state_root"])
        key = _key(loaded, state_root, name)
        item = state.load_pending(state_root)["items"].get(key)
        answered = isinstance(item, dict) and item.get("state") == reconcile.CAPTURE and bool(item.get("answer"))
        if not isinstance(item, dict) or not (
            answered or item.get("state") in {reconcile.BLOCKED, reconcile.NAME_TAKEN}
        ):
            raise AnswerRefused(f"{name} is not kept back")
        fields = {
            "state": reconcile.CAPTURE,
            "reason": None,
            "detail": "",
            "blocked_digest": None,
            "blocked_tip": None,
            "blocked_at": None,
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
        kind = _kind(loaded, state_root, name)
        key = state.item_key(kind, name)
        item = state.load_pending(state_root)["items"].get(key)
        if _copy_of(context, kind, name, item if isinstance(item, dict) else None) is not None:
            raise AnswerRefused(f"{name} is here already; nothing to restore")
        lock = _capture_locked(state_root)
        try:
            tip = _fetch(context, loaded)
            entry = _entry_at(context, loaded, tip, name, kind)
            if entry is None:
                raise AnswerRefused(f"the remote has no {kind} {name}")
            directory = str(entry.get("directory") or entry.get("name"))
            if kind == state.PLUGIN:
                path = os.path.join(plugins.plugin_root(str((entry.get("agents") or [plugins.AGENT])[0])), directory)
            else:
                path = os.path.join(_home(), ".agents", "skills", directory)
            if os.path.lexists(path):
                # It holds something that is no copy of this one: never deleted.
                raise AnswerRefused(
                    f"{path} holds something else; move it away (or rename it) and restore again, "
                    f"or keep it with 'dotsteward skills track {name} --never'"
                )
            digest = _install_from(context, loaded, tip, entry, path)
            state.record_base(state_root, str(entry["name"]), digest, tip, path, kind)
            state.drop_item(state_root, key)
            with contextlib.suppress(OSError):
                state.change_pending(
                    state_root, lambda document: document.get("missing", {}).pop(key, None) is not None
                )
            if kind == state.PLUGIN:
                _say(f"{name}: installed from the remote into {path}")
            else:
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
