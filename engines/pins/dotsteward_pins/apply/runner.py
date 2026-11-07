"""``dotsteward pins apply [--latest FILE] [--plan] [--skip ID]... [--json] [--jobs N]``.

Without --latest it researches like ``pins latest``; an error row does not stop it.
With --latest it takes a saved report, which is how the producer runs again on a new
tip (design section 2.4). A second run has nothing to do, because a row whose value
the pin already holds does not move.

Under the instance lock, in the order framework, channel inputs, flake inputs, build
pins, downloads, requirements, bundles, skills, every group writes as a whole or
restores every byte it touched. After them one ``dotsteward generate --nix`` writes the
mirrors and the versions Nix resolves. Nothing is committed and nothing is published.

Exit status: the outcome of the run report ``pins-apply``: 0 done, 3 review items wait
in review.json, 6 an upstream could not be read, 1 a group failed; a usage error or a
broken input is 2, a held instance lock 1. --plan writes nothing at all, also no
report, and exits 0.
"""

from __future__ import annotations

import argparse
import datetime
import json
import shutil
import signal
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType
from typing import Any

from dotsteward_cli import atomic, locks, report
from dotsteward_cli import config as ds_config

from ..instance import EngineError, Instance, Refusal
from ..instance import load as load_instance
from ..latest import model
from ..latest import runner as research
from ..latest.adapters import Planned
from ..lockfile import Locks, load_json
from . import plan as routing
from .plan import Declared, Group, Plan
from .skills import Upstreams, relative, replace_skill
from .tools import GroupFailure, Tools, Waits
from .writers import TEMPLATE_FILES, Writer

PREFIX = "[pins]"
COMMAND = "pins-apply"


class Snapshot:
    """The bytes a group may change; restore puts back every one of them."""

    def __init__(self) -> None:
        self.files: dict[Path, tuple[bytes, int] | None] = {}
        self.trees: dict[Path, Path] = {}
        self.work: tempfile.TemporaryDirectory[str] | None = None

    def keep(self, *paths: Path) -> None:
        for path in paths:
            if path not in self.files:
                self.files[path] = (path.read_bytes(), path.stat().st_mode & 0o7777) if path.exists() else None

    def keep_tree(self, directory: Path) -> None:
        if directory in self.trees or not directory.is_dir():
            return
        if self.work is None:
            self.work = tempfile.TemporaryDirectory(prefix="dotsteward-pins-keep-")
        copy = Path(self.work.name) / str(len(self.trees))
        shutil.copytree(directory, copy, symlinks=True)
        self.trees[directory] = copy

    def restore(self) -> None:
        for path, content in self.files.items():
            if content is None:
                path.unlink(missing_ok=True)
            elif not path.exists() or path.read_bytes() != content[0] or path.stat().st_mode & 0o7777 != content[1]:
                atomic.atomic_write(path, content[0], mode=content[1])
        for directory, copy in self.trees.items():
            shutil.rmtree(directory, ignore_errors=True)
            shutil.copytree(copy, directory, symlinks=True)

    def close(self) -> None:
        if self.work is not None:
            self.work.cleanup()


@dataclass
class Outcome:
    """What the run did, for the report, the summary and the caller."""

    moved: list[dict[str, Any]] = field(default_factory=list)
    groups: list[dict[str, Any]] = field(default_factory=list)
    stage: list[str] = field(default_factory=list)
    framework_moved: bool = False
    flake_inputs_moved: list[str] = field(default_factory=list)


class Run:
    def __init__(self, instance: Instance, tools: Tools, plan: Plan, run: report.RunReport, quiet: bool) -> None:
        self.instance = instance
        self.tools = tools
        self.plan = plan
        self.run = run
        self.quiet = quiet
        self.outcome = Outcome()
        self.upstreams = Upstreams(tools)
        self.writer_notes: list[dict[str, Any]] = []

    def say(self, text: str) -> None:
        if not self.quiet:
            print(f"{PREFIX} {text}")

    def error(self, text: str) -> None:
        print(f"{PREFIX} ERROR: {text}", file=sys.stderr)

    def go(self) -> None:
        try:
            for group in self.plan.groups:
                self.group(group)
            if self.outcome.moved:
                self.generate()
        finally:
            self.upstreams.close()

    def group(self, group: Group) -> None:
        ids = [move.id for move in group.moves]
        if group.blocked:
            message = f"waits for {', '.join(group.blocked)}: its upstream could not be read"
            self.say(f"{group.name}: {message}")
            self.run.step(group.name, report.PARTIAL, ids=ids, skipped=message)
            self.outcome.groups.append({"group": group.name, "outcome": "skipped", "ids": ids, "error": message})
            return
        snapshot = Snapshot()
        try:
            self.write(group, snapshot)
            self.plan.items.extend(self.writer_notes)
        except (GroupFailure, Refusal, EngineError, OSError, KeyError, TypeError, ValueError) as failure:
            snapshot.restore()
            message = _message(failure)
            self.error(f"{group.name}: {message}")
            self.run.step(group.name, report.FAILED, ids=ids, error=message)
            self.outcome.groups.append({"group": group.name, "outcome": "failed", "ids": ids, "error": message})
        except Waits as waiting:
            snapshot.restore()
            first = group.moves[0].row
            single = len(group.moves) == 1
            self.plan.items.append(
                {
                    "code": waiting.code,
                    "id": ids[0] if single else group.name,
                    "ids": ids,
                    "current": first.get("current") if single else None,
                    "latest": first.get("latest") if single else None,
                    "source": first.get("source") if single else None,
                    **waiting.fields,
                }
            )
            self.run.step(group.name, report.OK, ids=ids, waits=waiting.code)
            self.outcome.groups.append({"group": group.name, "outcome": "review", "ids": ids})
        except BaseException:
            snapshot.restore()
            raise
        else:
            self.done(group)
        finally:
            snapshot.close()

    def write(self, group: Group, snapshot: Snapshot) -> None:
        instance = self.instance
        snapshot.keep(
            instance.path("flake.nix"), instance.path("flake.lock"), instance.versions_path, instance.skills_path
        )
        declared = Declared(instance, instance.load_locks())
        writer = Writer(instance, self.tools, declared)
        self.writer_notes = writer.notes
        if group.kind == "framework":
            snapshot.keep(*(instance.path(name) for name in TEMPLATE_FILES))
            snapshot.keep(*sorted(instance.path(".dotsteward").glob("*")))
            writer.framework(group)
            # The new release can declare other rules: what follows reads them.
            self.instance = load_instance(str(instance.root))
            self.outcome.framework_moved = True
        elif group.kind in ("channel", "flake"):
            writer.flake_inputs(group)
            self.outcome.flake_inputs_moved += [move.id for move in group.moves]
        elif group.kind == "nix-package":
            writer.nix_package(group)
        elif group.kind == "download":
            writer.download(group)
        elif group.kind == "pypi":
            snapshot.keep(instance.path(group.key))
            writer.pypi(group)
        elif group.kind == "npm":
            directory = instance.path(group.key)
            snapshot.keep(directory / "package.json", directory / "package-lock.json")
            writer.npm(group)
        elif group.kind == "skill":
            self.skill(group, writer, snapshot)
        else:
            raise GroupFailure(f"no writer for the group kind {group.kind}")

    def skill(self, group: Group, writer: Writer, snapshot: Snapshot) -> None:
        instance = self.instance
        move = group.moves[0]
        name = move.id.removeprefix("skills.")
        document = instance.load_locks()
        entry = routing.skill_entry(document, name)
        if entry is None:
            raise GroupFailure(f"{move.id}: the skill is not in the lock")
        snapshot.keep_tree(instance.path(instance.vendor_dir) / str(entry.get("directory", name)))
        directory = replace_skill(instance, self.tools, self.upstreams, document, move)

        def change(lock_files: Locks) -> None:
            found = routing.skill_entry(lock_files, name)
            assert found is not None
            found["revision"] = move.details["head"]

        writer.edit(change)
        writer.sync(name)
        self.outcome.stage.append(relative(instance, directory))

    def done(self, group: Group) -> None:
        ids = []
        for move in group.moves:
            ids.append(move.id)
            self.outcome.moved.append(
                {"id": move.id, "from": move.row.get("current"), "to": move.row.get("latest"), "group": group.name}
            )
            self.say(f"moved {move.id}: {move.row.get('current')} -> {move.row.get('latest')}")
        self.run.step(group.name, report.OK, moved=ids)
        self.outcome.groups.append({"group": group.name, "outcome": "moved", "ids": ids})

    def generate(self) -> None:
        try:
            self.tools.stage(self.outcome.stage)
            self.tools.generate("--nix")
        except GroupFailure as failure:
            message = str(failure)
            self.error(f"generate: {message}")
            self.run.step("generate", report.FAILED, error=message)
        else:
            self.run.step("generate", report.OK)


def _message(failure: BaseException) -> str:
    messages = getattr(failure, "messages", None)
    if messages:
        return "; ".join(str(message) for message in messages)
    return str(failure) or repr(failure)


def load_rows(args: argparse.Namespace, planned: list[Planned]) -> tuple[list[routing.Row], str | None]:
    if not args.latest:
        return research.research(planned, args.jobs), model.researched_at(datetime.datetime.now(datetime.UTC))
    try:
        document = load_json(Path(args.latest))
        items = document["items"]
        if not isinstance(items, list) or not all(isinstance(row, dict) and "id" in row for row in items):
            raise TypeError("items is not a list of rows")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise EngineError(f"{args.latest} is not a pins latest report: {error}") from error
    return items, document.get("researched_at")


def summary(
    plan: Plan, outcome: Outcome | None, researched: str | None, run: report.RunReport | None
) -> dict[str, Any]:
    if outcome is None:
        groups = [
            {
                "group": group.name,
                "outcome": "skipped" if group.blocked else "planned",
                "ids": [m.id for m in group.moves],
            }
            for group in plan.groups
        ]
    else:
        groups = outcome.groups
    document: dict[str, Any] = {
        "plan": outcome is None,
        "researched_at": researched,
        "moved": outcome.moved if outcome else [],
        "groups": groups,
        "lines": plan.lines,
        "items": plan.items,
        "framework_moved": outcome.framework_moved if outcome else False,
        "flake_inputs_moved": outcome.flake_inputs_moved if outcome else [],
    }
    if run is not None:
        document.update(status=report.status_name(run.exit_code), exit_code=run.exit_code)
    return document


def show_lines(plan: Plan) -> None:
    for line in plan.lines:
        note = f": {line['note']}" if line.get("note") else ""
        print(f"{PREFIX} {line['status']} {line['id']}{note}"[: model.LINE_LIMIT])
    for entry in plan.items:
        print(f"{PREFIX} review {entry['code']} {entry['id']}"[: model.LINE_LIMIT])


def report_lines(plan: Plan, run: report.RunReport) -> None:
    code = report.PARTIAL if any(line["status"] == "error" for line in plan.lines) else report.OK
    run.step("rows", code, lines=plan.lines)


def _terminated(_number: int, _frame: FrameType | None) -> None:
    """A group that is ended restores its bytes like one that failed: no placeholder
    hash stays behind."""
    raise KeyboardInterrupt


def run(instance: Instance, args: argparse.Namespace) -> int:
    planned = research.plan(instance, False)
    rows, researched = load_rows(args, planned)
    tools = Tools(instance.root)
    route = routing.route(instance, instance.load_locks(), planned, rows, list(args.skip), tools)

    if args.plan:
        if args.json:
            print(json.dumps(summary(route, None, researched, None), indent=2, ensure_ascii=False))
            return 0
        for group in route.groups:
            word = "waits" if group.blocked else "would move"
            for move in group.moves:
                print(
                    f"{PREFIX} {word} {move.id}: {move.row.get('current')} -> {move.row.get('latest')} ({group.name})"
                )
        show_lines(route)
        return 0

    state_root = ds_config.state_root(ds_config.load_instance(str(instance.root)))
    run_report = report.RunReport(COMMAND, state_root)
    signal.signal(signal.SIGTERM, _terminated)
    try:
        with locks.instance_lock(COMMAND, state_root=state_root):
            work = Run(instance, tools, route, run_report, args.json)
            if not args.json:
                show_lines(route)
            try:
                work.go()
            except KeyboardInterrupt:
                run_report.mark_interrupted(["SIGINT"])
                run_report.step("interrupted", report.FAILED)
            report_lines(route, run_report)
            run_report.data.update(
                researched_at=researched,
                moved=work.outcome.moved,
                framework_moved=work.outcome.framework_moved,
                flake_inputs_moved=work.outcome.flake_inputs_moved,
            )
            for entry in route.items:
                fields = {key: value for key, value in entry.items() if key != "code"}
                run_report.item(entry["code"], **fields)
            paths = run_report.write()
    except locks.LockBusy as busy:
        print(f"{PREFIX} ERROR: {busy}", file=sys.stderr)
        return report.FAILED
    if args.json:
        document = summary(route, work.outcome, researched, run_report)
        document["report"] = str(paths.report)
        print(json.dumps(document, indent=2, ensure_ascii=False))
    else:
        print(f"{PREFIX} {len(work.outcome.moved)} moved, {len(route.items)} for review: {paths.report}")
    return run_report.exit_code
