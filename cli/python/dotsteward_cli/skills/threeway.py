"""The decision for an own skill: never overwrite what the user changed.

Three digests decide: l, the normal form of the local copy; r, the lock of the
checkout; b, what this machine last had in sync (``base.json``):

    no l, b                                    deleted          not installed again
    no l, no b                                 missing          installed
    l == r                                     in-sync          b = r
    l != r, base_commit no ancestor of HEAD    behind           untouched
    l != r, no b                               conflict         untouched
    l != r, r == b                             pending-capture  untouched, capture takes it
    l != r, l == b                             incoming         backup and refresh
    otherwise                                  conflict         untouched

The ancestry comes first. Capture pushes to the remote and leaves the checkout
alone, so b can be ahead of the checkout's lock; a comparison of l with b alone would
then read the old lock as a change of the repository and take the local copy back.
The decision does not depend on ``[skills] tracking``: with tracking off a skill is
not captured, and still not overwritten. No state of a decision ever turns `agents
check` red; ``missing`` does, as for every accepted skill.

Command line, for ``cli/lib/skills.sh``::

    python3 -m dotsteward_cli.skills.threeway decide --instance DIR --state-root DIR \\
      --name NAME --found PATH --digest SHA --mode install|check
    python3 -m dotsteward_cli.skills.threeway record --instance DIR --state-root DIR \\
      --name NAME --found PATH --digest SHA

``decide`` prints the decision; with ``--mode install`` it records it. ``record``
says that the copy at PATH now equals the lock. Exit status: 0 done, 1 failed, 2 usage
error.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from typing import Any

from dotsteward_cli.skills import normal, state

IN_SYNC = "in-sync"
BEHIND = "behind"
PENDING_CAPTURE = "pending-capture"
INCOMING = "incoming"
CONFLICT = "conflict"
DELETED = "deleted"
MISSING = "missing"


def decide(local: str | None, repository: str, base: str | None, behind: bool) -> str:
    """The decision for the digests LOCAL, REPOSITORY and BASE; BEHIND says that
    the commit of BASE is no ancestor of the checkout."""
    if local is None:
        return MISSING if base is None else DELETED
    if local == repository:
        return IN_SYNC
    if base is None:
        return CONFLICT
    if behind:
        return BEHIND
    if repository == base:
        return PENDING_CAPTURE
    if local == base:
        return INCOMING
    return CONFLICT


def _git(instance: str, *argv: str) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    return subprocess.run(["git", "-C", instance, *argv], env=env, capture_output=True, text=True, check=False)


def head_commit(instance: str) -> str:
    """The commit of the checkout, empty outside git or without a commit."""
    result = _git(instance, "rev-parse", "--verify", "--quiet", "HEAD")
    return result.stdout.strip() if result.returncode == 0 else ""


def is_behind(instance: str, base_commit: str) -> bool:
    """Whether BASE_COMMIT is no ancestor of HEAD; a commit the checkout does not
    know counts as such, and outside git nothing is behind."""
    if not base_commit:
        return False
    result = _git(instance, "merge-base", "--is-ancestor", base_commit, "HEAD")
    if result.returncode == 0:
        return False
    if result.returncode == 1:
        return True
    return _git(instance, "rev-parse", "--verify", "--quiet", "HEAD").returncode == 0


def excludes_file(instance: str) -> str:
    return os.path.join(instance, ".gitignore")


def local_digest(found: str | None, instance: str) -> tuple[str | None, normal.NormalForm | None]:
    """The digest and the normal form of the copy at FOUND, (None, None) without one."""
    if not found or not os.path.isdir(found):
        return None, None
    form = normal.normal_form(os.path.realpath(found), excludes_file(instance))
    return form.digest, form


def assess(name: str, found: str | None, repository: str, instance: str, state_root: str) -> dict[str, Any]:
    """The whole answer for one own skill: decision and digests, for bash and for
    ``skills status``."""
    digest, form = local_digest(found, instance)
    entry = state.base_entry(state.load_base(state_root), name)
    base = entry["base_sha256"] if entry else None
    commit = str(entry.get("base_commit") or "") if entry else ""
    behind = digest != repository and is_behind(instance, commit)
    return {
        "name": name,
        "state": decide(digest, repository, base, behind),
        "path": found or None,
        "local_sha256": digest,
        "lock_sha256": repository,
        "base_sha256": base,
        "dropped": form.dropped if form else [],
        "unsafe_links": form.unsafe if form else [],
    }


def _item(name: str, found: str | None, decision: str, digest: str | None) -> dict[str, Any]:
    return {
        "kind": "skill",
        "name": name,
        "path": found or None,
        "state": decision,
        "origin": "own",
        "digest": digest,
        "detected_at": time.time(),
    }


def _record_install(answer: Mapping[str, Any], instance: str, state_root: str) -> None:
    name = str(answer["name"])
    key = state.skill_key(name)
    decision = answer["state"]
    if decision == IN_SYNC:
        state.record_base(state_root, name, str(answer["lock_sha256"]), head_commit(instance), str(answer["path"]))
        items = state.load_pending(state_root)["items"]
        if isinstance(items.get(key), dict) and items[key].get("state") in {CONFLICT, DELETED}:
            state.drop_item(state_root, key)
    elif decision in {CONFLICT, DELETED}:
        known = state.load_pending(state_root)["items"].get(key)
        if isinstance(known, dict) and known.get("state") == decision and known.get("digest") == answer["local_sha256"]:
            return
        state.set_item(state_root, key, _item(name, answer["path"], decision, answer["local_sha256"]))


def _arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="dotsteward_cli.skills.threeway", add_help=False)
    parser.add_argument("action", choices=["decide", "record"])
    parser.add_argument("--instance", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--found", default="")
    parser.add_argument("--digest", required=True)
    parser.add_argument("--mode", choices=["install", "check"], default="check")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _arguments(sys.argv[1:] if argv is None else argv)
    try:
        if args.action == "record":
            state.record_base(args.state_root, args.name, args.digest, head_commit(args.instance), args.found)
            state.drop_item(args.state_root, state.skill_key(args.name))
            return 0
        answer = assess(args.name, args.found or None, args.digest, args.instance, args.state_root)
        if args.mode == "install":
            _record_install(answer, args.instance, args.state_root)
    except (normal.NormalFormError, OSError) as error:
        print(f"[dotsteward] ERROR: skill {args.name}: {error}", file=sys.stderr)
        return 1
    print(answer["state"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
