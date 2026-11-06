"""The commands of ``dotsteward skills`` other than the hook.

    skills status [--json]        what the machine knows about the own skills of the lock

Exit status: 0 done, 1 refused or failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from typing import Any

from dotsteward_cli import config, machine, tomlfile
from dotsteward_cli.skills import layout, normal, state, threeway


def own_revisions(loaded: config.Instance) -> set[str]:
    """The revisions that mark a skill as the user's own."""
    revisions = {state.REPO_OWNED_REVISION}
    extra = loaded.config.get("compat", {}).get("repo_owned_revision")
    if isinstance(extra, str) and extra:
        revisions.add(extra)
    return revisions


def read_lock(loaded: config.Instance) -> dict[str, Any]:
    """The skills lock of the checkout, an empty one when it does not exist."""
    path = loaded.root / loaded.config["skills"]["lock"]
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except FileNotFoundError:
        return {"schema_version": "1.0", "skills": []}
    if not isinstance(document, dict) or not isinstance(document.get("skills"), list):
        raise ValueError(f"{path} is not a skills lock")
    return document


def setting(loaded: config.Instance, key: str, default: Any) -> Any:
    """A key of ``[skills]`` that an instance need not name."""
    return loaded.config["skills"].get(key, default)


def tracking_on(loaded: config.Instance) -> bool:
    """``[skills] tracking``: off for an instance that does not name it."""
    return setting(loaded, "tracking", False) is True


def _lock_digest(loaded: config.Instance, entry: dict[str, Any]) -> str:
    digest = entry.get("directory_sha256")
    if isinstance(digest, str) and digest:
        return digest
    vendor = loaded.root / loaded.config["skills"]["vendor_dir"] / str(entry.get("directory"))
    return normal.normal_form(str(vendor), None).digest


def _own_entries(loaded: config.Instance) -> list[dict[str, Any]]:
    revisions = own_revisions(loaded)
    return [
        entry
        for entry in read_lock(loaded)["skills"]
        if isinstance(entry, dict)
        and entry.get("revision") in revisions
        and entry.get("deployment", "copy") != "home-manager"
    ]


def _status_document(loaded: config.Instance) -> dict[str, Any]:
    state_root = config.state_root(loaded)
    where = layout.read(loaded)
    instance = str(loaded.root)
    own = [
        threeway.assess(
            str(entry["name"]), layout.find_copy(where, entry), _lock_digest(loaded, entry), instance, state_root
        )
        for entry in _own_entries(loaded)
    ]
    return {
        "schema_version": state.SCHEMA_VERSION,
        "tracking": tracking_on(loaded),
        "own": own,
        "pending": state.load_pending(state_root)["items"],
        "last_capture": state.read_json(os.path.join(state.directory(state_root), state.LAST_CAPTURE_FILE), None),
    }


def _status(args: argparse.Namespace, loaded: config.Instance) -> int:
    document = _status_document(loaded)
    if args.json:
        print(json.dumps(document, indent=2, sort_keys=True))
        return 0
    in_sync = 0
    for skill in document["own"]:
        if skill["state"] == threeway.IN_SYNC:
            in_sync += 1
        else:
            print(f"[dotsteward] {skill['name']}: {skill['state']}")
        for path in skill["dropped"]:
            print(f"[dotsteward] {skill['name']}: left out by an ignore rule: {path}")
        for path in skill["unsafe_links"]:
            print(f"[dotsteward] {skill['name']}: link out of the tree or broken: {path}")
    for key, item in sorted(document["pending"].items()):
        if isinstance(item, dict):
            print(f"[dotsteward] {key}: {item.get('state')} ({item.get('origin')})")
    print(f"[dotsteward] {in_sync} of {len(document['own'])} own skills in sync")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward skills",
        description="Track the user's own skills, and report what the instance means for this machine.",
        epilog=(
            "Exit status: 0 done, 1 refusal, 2 usage error, 3 a conflict or a question waits, 4 a privacy stop, "
            "6 no network. `skills hook EVENT --agent AGENT` is what the agents call, and it always exits 0."
        ),
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    report = commands.add_parser(
        "effective",
        help="what this machine leaves out, and why",
        description=(
            "Prints the machine name, its profile and tags, and what it leaves out: skip.components, "
            "skip.skills and skip.plugins, with one word for each in reasons (machines: the entry is for "
            "other machines; declined: hosts/<name>.toml says never; deleted: an own skill deleted here). "
            "name_taken lists the skills of the lock that are for other machines while this machine has a "
            "skill of that name."
        ),
        allow_abbrev=False,
    )
    report.add_argument("--json", action="store_true", help="print one JSON document")
    status = commands.add_parser(
        "status",
        help="what the machine knows about the own skills of the lock",
        description=(
            "One line per own skill that is not in sync, what ignore rules leave out of a copy, links "
            "that cannot be copied and what waits. With --json the document with the state of every own skill."
        ),
    )
    status.add_argument("--json", action="store_true", help="print one JSON document")
    return parser


def main(argv: Sequence[str]) -> int:
    args = _parser().parse_args(argv)
    if args.command == "effective":
        return machine.main(["effective", *(["--json"] if args.json else [])])
    try:
        return _status(args, config.load_instance())
    except config.DotstewardError as error:
        for line in error.lines():
            print(line, file=sys.stderr)
        return 1
    except (normal.NormalFormError, OSError, ValueError, tomlfile.TomlError) as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return 1
