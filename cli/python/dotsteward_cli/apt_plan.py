"""The apt engine for `dotsteward upgrade`, on the side of the CLI's own python.

The work happens in ``cli/libexec/apt_helper.py``, which runs under the system's
``/usr/bin/python3`` with python3-apt; this module builds its request, starts it and
turns its answer into report items. Nothing here decides about a package.

    request = apt_plan.Request(mode="tracked", tracked=("example-app",))
    plan = apt_plan.plan(request)
    apt_plan.record(run, plan)

The internal command line of the same functions, for tests and for a look by hand:

    python3 -m dotsteward_cli.apt_plan ACTION [--request FILE|-] [--report COMMAND] [--state-root DIR]

prints the answer of the helper. With ``--report`` it also writes a run report and
``review.json`` for COMMAND and exits with the code of that run; without, it exits 0
after an answer and 1 when the helper could not run.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import config, report

_HELPER = Path(__file__).resolve().parents[2] / "libexec" / "apt_helper.py"
_SYSTEM_PYTHON = "/usr/bin/python3"
_INSTALL_APT_BINDING = "sudo apt-get install python3-apt"

MODES = ("tracked", "all")


class AptEngineError(Exception):
    """The helper could not run; ``code`` names the reason, ``message`` says it."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Request:
    """What one apt step needs to know. ``tracked`` is the set T of the enabled deb
    components. ``accept`` holds the keys of ``--accept``. ``constraints`` maps a
    constrained server to its major version (``{"sampledbms": "16"}``). ``gated``
    is false only for ``[apt.gated] enable = false`` of the machine."""

    mode: str = "tracked"
    tracked: Sequence[str] = ()
    accept: Sequence[str] = ()
    constraints: Mapping[str, str] = field(default_factory=dict)
    gated: bool = True
    running_kernel: str | None = None
    codename: str | None = None
    boot_path: str | None = None
    boot_low_mib: int | None = None

    def to_json(self) -> dict[str, Any]:
        """The request as the helper reads it."""
        data: dict[str, Any] = {
            "mode": self.mode,
            "tracked": sorted(self.tracked),
            "accept": list(self.accept),
            "constraints": dict(self.constraints),
            "gated": self.gated,
            "running_kernel": self.running_kernel or os.uname().release,
        }
        if self.codename:
            data["codename"] = self.codename
        if self.boot_path:
            data["boot_path"] = self.boot_path
        if self.boot_low_mib:
            data["boot_low_mib"] = self.boot_low_mib
        return data

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> Request:
        """Raises ValueError for a mode or an accept key that does not exist."""
        mode = data.get("mode", "tracked")
        if mode not in MODES:
            raise ValueError(f"not a mode: {mode}")
        accept = tuple(data.get("accept") or ())
        for key in accept:
            if not (key.startswith(("install:", "series:kernel=", "series:nvidia=")) or key == "firmware"):
                raise ValueError(f"not an accept key: {key}")
        return cls(
            mode=mode,
            tracked=tuple(data.get("tracked") or ()),
            accept=accept,
            constraints=dict(data.get("constraints") or {}),
            gated=bool(data.get("gated", True)),
            running_kernel=data.get("running_kernel"),
            codename=data.get("codename"),
            boot_path=data.get("boot_path"),
            boot_low_mib=data.get("boot_low_mib"),
        )


def _helper_argv(action: str) -> list[str]:
    python = os.environ.get("DOTSTEWARD_APT_PYTHON") or _SYSTEM_PYTHON
    return [python, "-I", str(_HELPER), action]


def _answer_of(completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
    try:
        answer = json.loads(completed.stdout)
    except ValueError as error:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise AptEngineError("apt-helper-failed", f"the apt helper gave no answer: {detail}") from error
    return _checked(answer)


def _checked(answer: dict[str, Any]) -> dict[str, Any]:
    failure = answer.get("error")
    if failure:
        raise AptEngineError(failure.get("code", "apt-helper-failed"), failure.get("message", "the apt helper failed"))
    return answer


def _read_only(action: str, request: Request) -> dict[str, Any]:
    argv = _helper_argv(action)
    try:
        completed = subprocess.run(
            argv,
            input=json.dumps(request.to_json()),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise AptEngineError("python3-apt-missing", f"cannot start {shlex.join(argv[:2])}: {error}") from error
    return _answer_of(completed)


def plan(request: Request) -> dict[str, Any]:
    """The plan of one run; it needs no privileges and changes nothing. Raises AptEngineError."""
    return _read_only("plan", request)


def analysis(request: Request) -> dict[str, Any]:
    """The read only look at the apt channel: upgradable packages outside ``tracked``,
    what phasing defers, the kernels and the free space of /boot. Raises AptEngineError."""
    return _read_only("analysis", request)


def record(run: report.RunReport, answer: Mapping[str, Any], *, step: str = "apt-plan") -> None:
    """Puts an answer of the helper into a run report: one step, and one review item for each
    item of the answer. An item with ``pending`` makes the run wait for a person."""
    outcome = report.OK
    for item in answer.get("items", ()):
        fields = {key: value for key, value in item.items() if key not in {"code", "pending"}}
        pending = bool(item.get("pending"))
        run.item(item["code"], pending=pending, **fields)
        if pending:
            outcome = report.PENDING
    run.step(step, outcome)


def record_failure(run: report.RunReport, failure: AptEngineError, *, step: str = "apt-plan") -> None:
    """Puts a helper that could not run into a run report."""
    if failure.code == "python3-apt-missing":
        run.item(failure.code, run=_INSTALL_APT_BINDING, message=failure.message)
        run.step(step, report.PENDING, detail=failure.message)
        return
    run.step(step, report.FAILED, detail=f"{failure.code}: {failure.message}")


ACTIONS = {"plan": plan, "analysis": analysis}


def _load_request(source: str | None) -> Request:
    if source is None:
        return Request()
    text = sys.stdin.read() if source == "-" else Path(source).read_text(encoding="utf-8")
    return Request.from_json(json.loads(text))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="dotsteward_cli.apt_plan", description="The apt engine, for tests and by hand."
    )
    parser.add_argument("action", choices=sorted(ACTIONS))
    parser.add_argument("--request", help="a JSON file with the request, - for standard input")
    parser.add_argument("--report", metavar="COMMAND", help="write a run report and review.json for COMMAND")
    parser.add_argument("--state-root", help="the state root of the report")
    options = parser.parse_args(argv)
    try:
        request = _load_request(options.request)
    except (OSError, ValueError) as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return 2
    run = None
    if options.report:
        root = Path(options.state_root) if options.state_root else config.discovered_state_root()
        run = report.RunReport(options.report, root)
    try:
        answer = ACTIONS[options.action](request)
    except AptEngineError as failure:
        print(f"[dotsteward] ERROR: {failure.code}: {failure.message}", file=sys.stderr)
        if run is None:
            return report.FAILED
        record_failure(run, failure, step=options.action)
        run.write()
        return run.exit_code
    print(json.dumps(answer, indent=2, sort_keys=True))
    if run is None:
        return report.OK
    record(run, answer, step=options.action)
    run.write()
    return run.exit_code


if __name__ == "__main__":
    sys.exit(main())
