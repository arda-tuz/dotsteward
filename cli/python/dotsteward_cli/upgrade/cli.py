"""``dotsteward upgrade``: the command line, the menu, the way to the pinned CLI, the lock.

The revisions are compared before the configuration is read: a tree written for a newer framework
would stop this CLI at a key it does not know. See docs/upgrade.md.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import apt_plan, config, firmware, locks, report
from dotsteward_cli.upgrade import holds, plan, run

REEXEC = "DOTSTEWARD_UPGRADE_REEXEC"
EXIT_USAGE = 2
EXIT_INTERRUPTED = 130
_MENU = """\
Update what?
  1) Tracked only (then a read only analysis of the system and an offer)
  2) Everything ({everything})"""
_DESCRIPTION = (
    "Brings this machine and the shared lock to the newest stable versions. Without a flag a terminal "
    "asks what to update; without a terminal it is --tracked. Exit status: 0 done, 1 a refusal or a "
    "failed step, 2 usage error, 3 a decision or a sudo step waits (review.json), 4 a privacy stop, "
    "6 no network: the network steps were skipped and the checks ran, 130 interrupted: the next run "
    "finishes. Never: an OS release upgrade, autoremove, a reboot."
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward upgrade", description=_DESCRIPTION)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--tracked",
        action="store_true",
        help="what the instance tracks, then a read only analysis of everything else and one offer",
    )
    mode.add_argument(
        "--all",
        action="store_true",
        help="also apt as a whole, snap, flatpak and the tools of [[upgrade.tools]]; no second question",
    )
    parser.add_argument("--plan", action="store_true", help="say what both modes would do and change nothing")
    parser.add_argument(
        "--retry-held",
        action="store_true",
        help="take back the pin holds of this machine first (in its host file and <state>/holds.json), "
        "so the held pins move again",
    )
    parser.add_argument("--json", action="store_true", help="print the report as one JSON document")
    parser.add_argument(
        "--accept",
        action="append",
        default=[],
        metavar="KEY",
        help="answer in advance: install:PACKAGE, series:kernel=X.Y, series:nvidia=N, firmware; "
        "all of them need a terminal in the end",
    )
    return parser


def _say_error(text: str) -> None:
    print(f"[dotsteward] ERROR: {text}", file=sys.stderr)


def _choose_mode(tools: Sequence[Mapping[str, Any]]) -> str | None:
    everything = ", ".join(["apt", "snap", "flatpak", *(str(tool["name"]) for tool in tools)])
    print(_MENU.format(everything=everything), flush=True)
    for _ in range(3):
        print("Choice [1/2]: ", end="", flush=True)
        answer = sys.stdin.readline()
        if not answer:
            return None
        choice = answer.strip()
        if choice in {"1", "2"}:
            return "tracked" if choice == "1" else "all"
    return None


def _go_to_pinned_cli(root: Path, argv: Sequence[str], stdout: int | None = None) -> None:
    """Goes on with the CLI that the tree pins, once. The lock ends with this process image."""
    if os.environ.get(REEXEC) == "1" or config.revision_mismatch(root) is None:
        return
    launcher = root / ".dotsteward" / "cli.sh"
    if not os.access(launcher, os.X_OK):
        return
    os.environ[REEXEC] = "1"
    os.environ.pop(locks.HELD_VARIABLE, None)
    sys.stdout.flush()
    if stdout is not None:
        os.dup2(stdout, 1)
    os.execv(launcher, [str(launcher), "upgrade", *argv])


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    options = _parser().parse_args(arguments)
    try:
        apt_plan.Request.from_json({"accept": options.accept})
    except ValueError as error:
        _say_error(str(error))
        return EXIT_USAGE
    try:
        root = config.discover_instance(None)
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    _go_to_pinned_cli(root, arguments)

    terminal = firmware.on_terminal()
    # With --json everything else goes to standard error, of this process and its children.
    document_out = None
    if options.json:
        document_out = os.dup(1)
        os.dup2(2, 1)
    try:
        instance = config.load_instance()
        state_root = config.required_state_root()
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED

    if options.plan and options.retry_held:
        _say_error("--retry-held changes the holds and --plan changes nothing: use one of them")
        return EXIT_USAGE
    if options.plan:
        document = plan.build(instance, options.accept)
        return _finish_plan(document, document_out)

    mode = "tracked" if options.tracked else "all" if options.all else None
    if mode is None:
        try:
            mode = _choose_mode(instance.config["upgrade"]["tools"]) if terminal else "tracked"
        except KeyboardInterrupt:
            print()
            _say_error("no answer: nothing was changed")
            return EXIT_INTERRUPTED
        if mode is None:
            _say_error("no answer: nothing was changed")
            return EXIT_USAGE
        arguments = [f"--{mode}", *arguments]

    def again() -> None:
        _go_to_pinned_cli(root, arguments, document_out)

    try:
        with locks.instance_lock("upgrade", state_root=state_root):
            if options.retry_held:
                holds.retry(state_root)
                print(
                    "[upgrade] the pin holds of this machine are taken back, here and in its host file: "
                    "the held pins move again",
                    flush=True,
                )
            upgrade = run.Upgrade(instance, state_root, mode, options.accept, terminal, arguments, again)
            code = upgrade.execute()
    except locks.LockBusy as busy:
        _say_error(str(busy))
        return report.FAILED
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    if document_out is not None:
        with os.fdopen(document_out, "w", encoding="utf-8") as stream:
            json.dump(upgrade.document(), stream, indent=2, sort_keys=True)
            stream.write("\n")
    return code


def _finish_plan(document: dict[str, object], document_out: int | None) -> int:
    if document_out is None:
        print(plan.text(document))
    else:
        with os.fdopen(document_out, "w", encoding="utf-8") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
    return report.OK


if __name__ == "__main__":
    sys.exit(main())
