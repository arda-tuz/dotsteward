"""The commands of ``dotsteward skills`` other than the hook.

    skills status [--json]        what the machine knows about the own skills of the lock
    skills reconcile [--json] [--full]
                                  compares the skill roots with what is known, no network
    skills capture [--now|--wait] [--name SKILL]... [--json]
                                  publishes what waits; --wait sleeps until the deadline
    skills track SKILL --all|--here|--never|--own [--no-capture]
    skills resolve SKILL --ours|--theirs
    skills diff SKILL [--json]
    skills forget SKILL [--clear]
    skills restore SKILL          the answers (track.py)
    skills hooks install|check|remove [--agent claude|codex]
                                  the hooks in the configuration of an agent

Like every command it finds the instance with --instance, DOTSTEWARD_INSTANCE or the
working directory; since the question in a session names these commands and a session
runs anywhere, it then falls back to the instance the hooks know.

Exit status: 0 done, 1 refused or failed, 2 usage error, 3 a conflict or a question
waits, 4 a privacy stop, 6 no network.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from typing import Any

from dotsteward_cli import config, machine, tomlfile
from dotsteward_cli.skills import capture, hooks_install, layout, normal, reconcile, sleeper, state, threeway, track


def own_revisions(loaded: config.Instance) -> set[str]:
    """The revisions that mark a skill as the user's own."""
    revisions = {state.REPO_OWNED_REVISION}
    extra = loaded.config.get("compat", {}).get("repo_owned_revision")
    if isinstance(extra, str) and extra:
        revisions.add(extra)
    return revisions


def _lock_of(loaded: config.Instance) -> list[dict[str, Any]]:
    """The entries of the skills lock of the checkout, none when it does not exist."""
    path = loaded.root / loaded.config["skills"]["lock"]
    entries = state.lock_entries(path)
    if entries is None:
        if not path.exists():
            return []
        raise ValueError(f"{path} is not a skills lock")
    return entries


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
        for entry in _lock_of(loaded)
        if entry.get("revision") in revisions and entry.get("deployment", "copy") != "home-manager"
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
            why = f": {item['reason']}" if item.get("reason") else ""
            print(f"[dotsteward] {key}: {item.get('state')} ({item.get('origin')}){why}")
            copy = item.get("path")
            if item.get("state") in reconcile.KEPT_OUT and not (isinstance(copy, str) and os.path.isdir(copy)):
                print(f"[dotsteward] {key}: no copy is left: dotsteward skills forget --clear {item.get('name')}")
            for line in str(item.get("detail") or "").splitlines():
                print(f"[dotsteward] {key}: {line}")
    print(f"[dotsteward] {in_sync} of {len(document['own'])} own skills in sync")
    return 0


def _reconcile(args: argparse.Namespace, loaded: config.Instance) -> int:
    context = hooks_install.build_context(loaded)
    document = reconcile.reconcile(context, full=args.full)
    if args.json:
        print(json.dumps(document, indent=2, sort_keys=True))
    return 0


def _capture(args: argparse.Namespace, loaded: config.Instance) -> int:
    if not tracking_on(loaded):
        print("[dotsteward] skill tracking is off ([skills] tracking): nothing is captured", file=sys.stderr)
        if args.json:
            print(json.dumps(capture.Summary().document(), indent=2))
        return 0
    context = hooks_install.build_context(loaded)
    state_root = str(context["state_root"])
    tree = capture.tree_paths(loaded)
    if args.wait:
        return sleeper.wait(context, lambda: capture.run_now(context, tree, only_due=True).code)
    sleeper.log(state_root, f"capture pid {os.getpid()}")
    started = sleeper.read_deadline(state_root)
    summary = capture.run_now(context, tree, args.name or None)
    if started is not None and not summary.busy and (not args.name or not capture.waiting(state_root)):
        sleeper.clear_deadline(state_root, started)
    if args.json:
        print(json.dumps(summary.document(), indent=2))
    return summary.code


def _track(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.track(
        loaded, args.name, here=args.here, never=args.never, own=args.own, capture_now=not args.no_capture
    )


def _agents_of(args: argparse.Namespace, loaded: config.Instance) -> list[str]:
    if args.agent:
        return [args.agent]
    components = loaded.config.get("components", {})
    return [
        agent
        for agent in hooks_install.AGENTS
        if components.get(hooks_install.COMPONENTS[agent], {}).get("enable") is True
    ]


def _for_a_person() -> bool:
    """Whether a person asked: a rebuild and an E2E run (the hook of a component) hear
    only of what needs a person."""
    return not os.environ.get("DOTSTEWARD_COMPONENT")


def _hooks_install(agents: Sequence[str], loaded: config.Instance) -> int:
    if not tracking_on(loaded):
        if _for_a_person():
            print("[dotsteward] skills hooks: skill tracking is off ([skills] tracking)")
        for agent in agents:
            try:
                if hooks_install.remove_agent(agent):
                    print(f"[dotsteward] skills hooks: {agent}: removed, skill tracking is off")
            except hooks_install.HooksError as error:
                print(f"[dotsteward] skills hooks: {agent}: {error}")
        if not _any_installed():
            hooks_install.remove_context()
        return 0
    for agent in agents:
        hooks_install.merge_agent(agent)
    if agents:
        hooks_install.write_context(loaded)
    return 0


def _any_installed() -> bool:
    for agent in hooks_install.AGENTS:
        try:
            if hooks_install.installed_events(agent):
                return True
        except hooks_install.HooksError:
            return True
    return False


def _hooks_check(agents: Sequence[str], loaded: config.Instance) -> int:
    if not tracking_on(loaded):
        if _for_a_person():
            print("[dotsteward] skills hooks: skill tracking is off ([skills] tracking)")
        else:
            return 0
    for agent in agents:
        try:
            events = hooks_install.installed_events(agent)
            if len(events) == len(hooks_install.EVENTS[agent]):
                if _for_a_person():
                    print(f"[dotsteward] skills hooks: {agent}: installed")
            else:
                print(f"[dotsteward] skills hooks: {agent}: not installed for every event (installed: {events})")
            untrusted = hooks_install.untrusted_codex_events() if agent == "codex" and events else []
            if untrusted:
                print(
                    "[dotsteward] skills hooks: codex: waiting for trust in /hooks "
                    f"({', '.join(untrusted)}): Codex runs no untrusted hook"
                )
        except hooks_install.HooksError as error:
            print(f"[dotsteward] skills hooks: {agent}: {error}")
    return 0


def _hooks_remove(agents: Sequence[str]) -> int:
    for agent in agents:
        hooks_install.remove_agent(agent)
    if not _any_installed():
        hooks_install.remove_context()
    return 0


def _hooks(args: argparse.Namespace, loaded: config.Instance) -> int:
    agents = _agents_of(args, loaded)
    if args.action == "install":
        return _hooks_install(agents, loaded)
    if args.action == "check":
        return _hooks_check(agents, loaded)
    return _hooks_remove(agents)


def _resolve(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.resolve(loaded, args.name, ours=args.ours)


def _diff(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.diff(loaded, args.name, as_json=args.json)


def _forget(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.clear(loaded, args.name) if args.clear else track.forget(loaded, args.name)


def _restore(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.restore(loaded, args.name)


def _retry(args: argparse.Namespace, loaded: config.Instance) -> int:
    return track.retry(loaded, args.name)


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
    compare = commands.add_parser(
        "reconcile",
        help="compare the skill roots with what is known, without network",
        description="Finds new skills and changes of own skills and records them in pending.json.",
    )
    compare.add_argument("--json", action="store_true", help="print pending.json")
    compare.add_argument("--full", action="store_true", help="digest every own skill, whatever its file times say")
    publish = commands.add_parser(
        "capture",
        help="publish the skills that wait, from a separate worktree",
        description="Publishes what waits in pending.json. The checkout stays as it is.",
    )
    when = publish.add_mutually_exclusive_group()
    when.add_argument("--now", action="store_true", help="now; ends at once when nothing waits (default)")
    when.add_argument("--wait", action="store_true", help="sleep until the deadline, as one process per machine")
    publish.add_argument("--name", action="append", metavar="SKILL", help="only this skill; may be repeated")
    publish.add_argument("--json", action="store_true", help="print the result as one JSON document")
    answer = commands.add_parser(
        "track",
        help="answer the question about a skill: --all, --here or --never",
        description=(
            "--all puts the skill into the lock for every machine, --here for this machine only, --never remembers "
            "in the host file of this machine that it stays out. A downloaded skill keeps its upstream pinned; "
            "--own tracks your own copy without one, which also turns a pinned skill into yours."
        ),
    )
    answer.add_argument("name", metavar="SKILL")
    scope = answer.add_mutually_exclusive_group()
    scope.add_argument("--all", action="store_true", help="for all machines")
    scope.add_argument("--here", action="store_true", help="for this machine only")
    scope.add_argument("--never", action="store_true", help="never on this machine")
    answer.add_argument("--own", action="store_true", help="your own copy, without an upstream")
    answer.add_argument("--no-capture", action="store_true", help="record the answer; the next capture takes it")
    conflict = commands.add_parser(
        "resolve",
        help="settle a conflict: the local copy or the repository wins",
        description="--ours publishes the local copy. --theirs backs it up and installs the copy of the repository.",
    )
    conflict.add_argument("name", metavar="SKILL")
    side = conflict.add_mutually_exclusive_group(required=True)
    side.add_argument("--ours", action="store_true", help="the local copy wins")
    side.add_argument("--theirs", action="store_true", help="the repository wins")
    trees = commands.add_parser(
        "diff",
        help="the three trees of a skill, to compare them",
        description="Names the local copy, the copy on the remote and the one this machine last had in sync.",
    )
    trees.add_argument("name", metavar="SKILL")
    trees.add_argument("--json", action="store_true", help="print one JSON document")
    gone = commands.add_parser(
        "forget",
        help="take a skill out of the repository, for all machines",
        description=(
            "Removes the skill from the lock and the repository. A local copy stays, and nobody asks about it. "
            "--clear is for later, once no copy is left: this machine stops keeping the name out, of forget and of "
            "track --never alike, and a new skill of that name is a new skill."
        ),
    )
    gone.add_argument("name", metavar="SKILL")
    gone.add_argument("--clear", action="store_true", help="stop keeping out a name whose copy is gone")
    back = commands.add_parser(
        "restore",
        help="install a skill deleted here from the repository again",
        description="Copies the skill of the remote to the canonical skill root.",
    )
    back.add_argument("name", metavar="SKILL")
    again = commands.add_parser(
        "retry",
        help="try a skill that was kept back again, now",
        description=(
            "For a skill that is blocked (dotsteward skills status says why) once the cause is gone: "
            "a refusal of the remote is never tried again by itself."
        ),
    )
    again.add_argument("name", metavar="SKILL")
    hooks = commands.add_parser(
        "hooks",
        help="the hooks of skill tracking in the configuration of an agent",
        description=(
            "install puts the hooks into the configuration of an agent, or removes them when [skills] tracking "
            "is off; check reports and never fails; remove takes them out until the next rebuild."
        ),
    )
    hooks.add_argument("action", choices=["install", "check", "remove"])
    hooks.add_argument("--agent", choices=list(hooks_install.AGENTS), help="default: the enabled agents")
    return parser


def _load() -> config.Instance:
    """The instance of the command line or the working directory, else the hooks' own."""
    try:
        return config.load_instance()
    except config.ConfigError:
        raise
    except config.DotstewardError:
        context = reconcile.load_context()
        if context is None:
            raise
        return config.load_instance(str(context["instance"]))


def main(argv: Sequence[str]) -> int:
    args = _parser().parse_args(argv)
    if args.command == "effective":
        return machine.main(["effective", *(["--json"] if args.json else [])])
    try:
        loaded = _load()
        if args.command == "status":
            return _status(args, loaded)
        if args.command == "reconcile":
            return _reconcile(args, loaded)
        if args.command == "capture":
            return _capture(args, loaded)
        if args.command == "track":
            if not (args.all or args.here or args.never or args.own):
                print("dotsteward skills track: one of --all, --here, --never or --own is required", file=sys.stderr)
                return 2
            if args.never and args.own:
                print("dotsteward skills track: --never takes no --own", file=sys.stderr)
                return 2
            return _track(args, loaded)
        if args.command == "resolve":
            return _resolve(args, loaded)
        if args.command == "diff":
            return _diff(args, loaded)
        if args.command == "forget":
            return _forget(args, loaded)
        if args.command == "restore":
            return _restore(args, loaded)
        if args.command == "retry":
            return _retry(args, loaded)
        return _hooks(args, loaded)
    except config.DotstewardError as error:
        for line in error.lines():
            print(line, file=sys.stderr)
        return 1
    except (normal.NormalFormError, hooks_install.HooksError, OSError, ValueError, tomlfile.TomlError) as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return 1
