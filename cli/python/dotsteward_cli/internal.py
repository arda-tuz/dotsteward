"""``python3 -m dotsteward_cli.internal``: the primitives for bash.

The bash code of the framework calls this through ``ds_internal`` of
``cli/lib/python.sh``; Python code imports the modules themselves. It is no
command of the CLI and may change with the framework. Exit status: 0 done, 1
refused or failed, 2 usage error, unless a subcommand says otherwise.

    version-compare LEFT RIGHT   prints -1, 0 or 1 (dotsteward_cli.versions)
    state-root [--instance DIR]  prints the state root (config.state_root)
    atomic-write PATH [--mode M] [--parents]
                                 writes standard input to PATH (atomic.atomic_write)
    lock run --holder NAME [--state-root DIR] [--wait SECONDS] [--pending] -- COMMAND...
                                 runs COMMAND under the instance lock (locks); its
                                 status is the status; busy: exit 1, or with
                                 --pending a marker and exit 0
    lock status [--state-root DIR]
                                 prints the state of the lock as JSON
    run-protected -- COMMAND...  runs COMMAND so that signals wait for its end
                                 (procs.run_protected); its status is the status
    report combine [CODE...]     prints the heaviest exit code (report.combine)
    report write --command NAME [--state-root DIR] [--run NAME]
                                 writes a run report from the JSON on standard input,
                                 {"steps": [{"name": N, "code": STATUS, ...}], "items":
                                 [{"code": C, "pending": P, ...}], "data": {...}};
                                 prints where as JSON; its exit code is the run's
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Sequence


def _version_compare(args: argparse.Namespace) -> int:
    from dotsteward_cli import versions

    print(versions.compare(args.left, args.right))
    return 0


def _state_root(args: argparse.Namespace) -> int:
    from dotsteward_cli import config

    if args.instance is None:
        print(config.discovered_state_root())
    else:
        print(config.state_root(config.load_instance(args.instance)))
    return 0


def _atomic_write(args: argparse.Namespace) -> int:
    from dotsteward_cli import atomic, config

    mode = None
    if args.mode is not None:
        if not re.fullmatch(r"0?[0-7]{3}", args.mode):
            raise config.DotstewardError(f"invalid mode: {args.mode}")
        mode = int(args.mode, 8)
    try:
        atomic.atomic_write(args.path, sys.stdin.buffer.read(), mode=mode, parents=args.parents)
    except OSError as error:
        raise config.DotstewardError(f"cannot write {args.path}: {error.strerror}") from error
    return 0


def _command_of(args: argparse.Namespace) -> list[str]:
    """The words after ``--``."""
    command: list[str] = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        args.subparser.error("a COMMAND is required after --")
    return command


def _given_state_root(args: argparse.Namespace) -> str:
    from dotsteward_cli import config

    root: str | None = args.state_root
    return root if root is not None else config.discovered_state_root()


def _lock_run(args: argparse.Namespace) -> int:
    from dotsteward_cli import config, locks, procs

    command = _command_of(args)
    root = _given_state_root(args)
    pending = None
    pending_env = None
    if args.pending:
        # The marker starts this same call again, which waits its turn the same way.
        pending = [sys.executable, "-s", "-P", "-m", "dotsteward_cli.internal", "lock", "run"]
        pending += ["--holder", args.holder, "--pending", "--state-root", root, "--", *command]
        pending_env = {
            name: os.environ[name] for name in ("PYTHONPATH", "PYTHONDONTWRITEBYTECODE") if name in os.environ
        }
    try:
        lock = locks.InstanceLock(root, args.holder)
        lock.acquire(pending=pending, pending_env=pending_env, wait=args.wait)
    except ValueError as error:
        raise config.DotstewardError(str(error)) from error
    except locks.LockBusy as busy:
        if not busy.pending_recorded:
            raise config.DotstewardError(str(busy)) from busy
        who = "another command" if busy.holder is None else busy.holder.name
        print(f"[dotsteward] the instance lock is held by {who}; {args.holder} runs when it is free", file=sys.stderr)
        return 0
    except OSError as error:
        raise config.DotstewardError(f"cannot take the instance lock in {root}: {error.strerror}") from error
    try:
        return procs.run_attached(command)
    except OSError as error:
        print(f"[dotsteward] ERROR: cannot run {command[0]}: {error.strerror}", file=sys.stderr)
        return 127
    finally:
        lock.release()


def _lock_status(args: argparse.Namespace) -> int:
    from dotsteward_cli import locks

    status = locks.lock_status(_given_state_root(args))
    holder = None
    if status.holder is not None:
        holder = {"name": status.holder.name, "pid": status.holder.pid, "since": status.holder.since}
    print(json.dumps({"held": status.held, "holder": holder, "pending": status.pending}))
    return 0


def _run_protected(args: argparse.Namespace) -> int:
    from dotsteward_cli import procs

    command = _command_of(args)
    try:
        result = procs.run_protected(command)
    except OSError as error:
        print(f"[dotsteward] ERROR: cannot run {command[0]}: {error.strerror}", file=sys.stderr)
        return 127
    if result.interrupted:
        names = ", ".join(result.interrupted)
        print(f"[dotsteward] WARNING: interrupted while a protected command ran; it finished: {names}", file=sys.stderr)
    return result.returncode


def _report_combine(args: argparse.Namespace) -> int:
    from dotsteward_cli import config, report

    try:
        print(report.combine(int(code) for code in args.codes))
    except ValueError as error:
        raise config.DotstewardError(str(error)) from error
    return 0


def _report_write(args: argparse.Namespace) -> int:
    from dotsteward_cli import config, report

    try:
        document = json.load(sys.stdin)
        if not isinstance(document, dict):
            raise ValueError("expected a JSON object on standard input")
        run = report.RunReport(args.command, _given_state_root(args), run=args.run)
        for step in document.get("steps", []):
            details = {key: value for key, value in step.items() if key not in ("name", "code")}
            run.step(step["name"], step.get("code", report.OK), **details)
        for item in document.get("items", []):
            fields = {key: value for key, value in item.items() if key not in ("code", "pending")}
            run.item(item["code"], pending=item.get("pending", True), **fields)
        run.data.update(document.get("data", {}))
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise config.DotstewardError(f"invalid run report: {error}") from error
    paths = run.write()
    review = None if paths.review is None else str(paths.review)
    print(json.dumps({"report": str(paths.report), "review": review, "status": run.status, "exit_code": run.exit_code}))
    return run.exit_code


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward_cli.internal",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="subcommand", required=True)

    compare = commands.add_parser("version-compare", allow_abbrev=False)
    compare.add_argument("left")
    compare.add_argument("right")
    compare.set_defaults(handler=_version_compare)

    root = commands.add_parser("state-root", allow_abbrev=False)
    root.add_argument("--instance")
    root.set_defaults(handler=_state_root)

    write = commands.add_parser("atomic-write", allow_abbrev=False)
    write.add_argument("path")
    write.add_argument("--mode")
    write.add_argument("--parents", action="store_true")
    write.set_defaults(handler=_atomic_write)

    lock = commands.add_parser("lock", allow_abbrev=False)
    lock_commands = lock.add_subparsers(dest="lock_command", required=True)
    run = lock_commands.add_parser("run", allow_abbrev=False)
    run.add_argument("--holder", required=True)
    run.add_argument("--state-root")
    run.add_argument("--wait", type=float, default=0.0)
    run.add_argument("--pending", action="store_true")
    run.add_argument("command", nargs=argparse.REMAINDER)
    run.set_defaults(handler=_lock_run, subparser=run)
    status = lock_commands.add_parser("status", allow_abbrev=False)
    status.add_argument("--state-root")
    status.set_defaults(handler=_lock_status)

    protected = commands.add_parser("run-protected", allow_abbrev=False)
    protected.add_argument("command", nargs=argparse.REMAINDER)
    protected.set_defaults(handler=_run_protected, subparser=protected)

    reports = commands.add_parser("report", allow_abbrev=False)
    report_commands = reports.add_subparsers(dest="report_command", required=True)
    combine = report_commands.add_parser("combine", allow_abbrev=False)
    combine.add_argument("codes", nargs="*")
    combine.set_defaults(handler=_report_combine)
    write_report = report_commands.add_parser("write", allow_abbrev=False)
    write_report.add_argument("--command", required=True)
    write_report.add_argument("--state-root")
    write_report.add_argument("--run")
    write_report.set_defaults(handler=_report_write)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        code: int = args.handler(args)
    except Exception as error:
        # Hooks compare versions often: the configuration module loads only when used.
        config = sys.modules.get("dotsteward_cli.config")
        if config is not None and isinstance(error, config.DotstewardError):
            print("\n".join(error.lines()), file=sys.stderr)
            return 1
        if not isinstance(error, OSError):
            raise
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return 1
    return code


if __name__ == "__main__":
    sys.exit(main())
