"""Command line of the pins engine (``dotsteward pins``).

    dotsteward pins [--instance DIR] check [--nix]
    dotsteward pins [--instance DIR] sync [--nix] [--skill NAME]...
    dotsteward pins [--instance DIR] latest [--out FILE] [--all] [--jobs N]

check   cross-checks the lock files with every rule and validates every
        pins latest declaration (offline, read-only, no query); --nix also
        compares the resolved versions with the instance's Nix evaluation
sync    rewrites the derived values of the lock files; --nix also writes
        the evaluated resolved versions; --skill NAME refreshes the digests
        of a vendored skill
latest  reports the newest stable upstream versions (dotsteward_pins.latest)

Output lines start with ``[pins]``; problems go to standard error as
``[pins] ERROR: ...``. Exit status: 0 success, 1 inconsistencies or a
refusal (unknown --skill, untracked files before a Nix call, a sync rule
that cannot run), 2 usage errors and broken inputs (no instance, invalid
configuration, missing or invalid manifest mirror, invalid rule or latest
declaration, unreadable lock file, failed Nix evaluation).

The ``latest`` subcommand is implemented by ``dotsteward_pins.latest.runner``,
called as ``runner.run(instance, args) -> int`` with the parsed ``out``,
``all`` and ``jobs`` arguments.
"""

from __future__ import annotations

import argparse
import datetime
import importlib
import sys
from collections.abc import Sequence

from .checker import GROUP_ERRORS, Checker, describe_os_error
from .instance import EngineError, Instance, Refusal, load
from .lockfile import SKILLS, VERSIONS, DeclarationError, dump, generated_at, write_atomic
from .rules import Context, build_rules

PREFIX = "[pins]"
MAX_SYNC_PASSES = 10


def _error(message: str) -> None:
    print(f"{PREFIX} ERROR: {message}", file=sys.stderr)


def _jobs(value: str) -> int:
    try:
        jobs = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not an integer: {value!r}") from error
    if jobs < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return jobs


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward pins",
        description="Check, synchronize and research the pinned versions of an instance.",
    )
    parser.add_argument("--instance", metavar="DIR", help="instance root (default: discovered)")
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    check = commands.add_parser("check", help="cross-check the lock files with every rule")
    check.add_argument("--nix", action="store_true", help="also compare resolved versions with the Nix evaluation")
    sync = commands.add_parser("sync", help="rewrite the derived values of the lock files")
    sync.add_argument("--nix", action="store_true", help="also write resolved versions from the Nix evaluation")
    sync.add_argument(
        "--skill",
        action="append",
        default=[],
        metavar="NAME",
        help="also refresh the digests of this skill of the skills lock (repeatable)",
    )
    latest = commands.add_parser("latest", help="report the newest stable upstream versions (read-only)")
    latest.add_argument("--out", metavar="FILE", help="write the full JSON report to FILE")
    latest.add_argument("--all", action="store_true", help="also list rows that follow other pins")
    latest.add_argument("--jobs", type=_jobs, default=8, metavar="N", help="parallel queries (default 8)")
    return parser


# --- check --------------------------------------------------------------------------


def run_check(instance: Instance, nix: bool) -> int:
    if nix:
        instance.refuse_untracked()
    rules = build_rules(instance)
    # The latest declarations are only parsed here: an invalid one fails the
    # check (exit 2) instead of the next `pins latest`.
    from .latest.adapters import declared

    for declaration in instance.declarations("latest"):
        declared(declaration)
    ctx = Context(instance, instance.load_locks(), nix=nix)
    checker = Checker(instance.root)
    for rule in rules:
        checker.group(rule.group, rule.check, ctx, checker)
    for failure in checker.failures:
        _error(failure)
    if checker.failures:
        count = len(checker.failures)
        noun = "inconsistency" if count == 1 else "inconsistencies"
        print(
            f"{PREFIX} {count} {noun}; fix the source value in the lock files, "
            "then run 'dotsteward pins sync' for derived mirrors",
            file=sys.stderr,
        )
        return 1
    print(f"{PREFIX} All pin consistency checks passed ({checker.count} checks)")
    return 0


# --- sync ---------------------------------------------------------------------------


def run_sync(instance: Instance, nix: bool, skills: Sequence[str]) -> int:
    if nix:
        instance.refuse_untracked()
    rules = [rule for rule in build_rules(instance) if rule.SYNCS]
    locks = instance.load_locks()
    if skills:
        entries = locks.documents.get(SKILLS, {}).get("skills", [])
        known = {item.get("name") for item in entries if isinstance(item, dict)}
        unknown = sorted(set(skills) - known)
        if unknown:
            raise Refusal(f"skill not in lock: {', '.join(unknown)}")
    before = {kind: dump(document) for kind, document in locks.documents.items()}
    ctx = Context(instance, locks, nix=nix, extra_skills=frozenset(skills))

    for _ in range(MAX_SYNC_PASSES):
        snapshot = {kind: dump(document) for kind, document in locks.documents.items()}
        failures = []
        for rule in rules:
            try:
                rule.sync(ctx)
            except GROUP_ERRORS as error:
                failures.append(f"{rule.group}: missing or invalid lock field ({error!r})")
            except OSError as error:
                failures.append(f"{rule.group}: {describe_os_error(error, instance.root)}")
        if failures:
            raise Refusal(*failures)
        if snapshot == {kind: dump(document) for kind, document in locks.documents.items()}:
            break
    else:
        raise EngineError(f"sync did not settle after {MAX_SYNC_PASSES} passes; the derive rules form a cycle")

    now = datetime.datetime.now(datetime.UTC)
    written = []
    for kind, path, label in (
        (VERSIONS, instance.versions_path, instance.versions_label),
        (SKILLS, instance.skills_path, instance.skills_label),
    ):
        document = locks.documents.get(kind)
        if document is None or dump(document) == before[kind]:
            continue
        document["generated_at"] = generated_at(kind, now)
        write_atomic(path, dump(document))
        written.append(label)
    if written:
        print(f"{PREFIX} Synced files: {', '.join(written)}")
    else:
        print(f"{PREFIX} Mirrors already in sync; no changes")
    return 0


# --- latest -------------------------------------------------------------------------


def run_latest(instance: Instance, args: argparse.Namespace) -> int:
    try:
        runner = importlib.import_module(f"{__package__}.latest.runner")
    except ModuleNotFoundError as error:
        if error.name not in (f"{__package__}.latest", f"{__package__}.latest.runner"):
            raise
        raise EngineError("pins latest is not available in this framework version") from error
    return runner.run(instance, args)


# --- entry point --------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        instance = load(args.instance)
        if args.command == "check":
            return run_check(instance, args.nix)
        if args.command == "sync":
            return run_sync(instance, args.nix, args.skill)
        return run_latest(instance, args)
    except Refusal as refusal:
        for message in refusal.messages:
            _error(message)
        return 1
    except EngineError as error:
        for message in error.messages:
            _error(message)
        return 2
    except DeclarationError as error:
        _error(str(error))
        return 2
    except OSError as error:
        _error(describe_os_error(error, None))
        return 2
