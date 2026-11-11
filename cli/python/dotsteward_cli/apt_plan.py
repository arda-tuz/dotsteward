"""The apt engine for `dotsteward upgrade`, on the side of the CLI's own python.

The work happens in ``cli/libexec/apt_helper.py``, which runs under the system's
``/usr/bin/python3`` with python3-apt; this module builds its request, starts it and
turns its answer into report items. Nothing here decides about a package.

    request = apt_plan.Request(mode="tracked", tracked=("example-app",))
    apt_plan.recover(request)                      # sudo: dpkg left half way
    apt_plan.policy(request)                       # sudo: the pin file from what dpkg has
    answer = apt_plan.commit(request)              # sudo: plan and apply one depcache
    apt_plan.record(run, answer)

``plan``, ``analysis`` and ``files`` need no privileges and change nothing; ``check_files``
holds the files there to what ``files`` says (``dotsteward e2e``, core:apt-files). The three others ask
sudo without a prompt, so the caller opens the sudo window first, and they run as a
protected child: Ctrl-C at the terminal does not stop dpkg half way, it ends up in
``interrupted`` of the answer. What dpkg prints goes to a file below the state root
(``log`` of the answer) and from there to standard error while it lasts: a terminal that
closes must not fail a write of dpkg, which then stops half way.

The internal command line of the same functions, for tests and for a look by hand:

    python3 -m dotsteward_cli.apt_plan ACTION [--request FILE|-] [--report COMMAND] [--state-root DIR]
    python3 -m dotsteward_cli.apt_plan check-files --instance DIR | --request FILE|-

prints the answer of the helper. With ``--report`` it also writes a run report and
``review.json`` for COMMAND and exits with the code of that run; without, it exits 0
after an answer and 1 when the helper could not run.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, machine, procs, report
from dotsteward_cli.upgrade import facts, holds

_HELPER = Path(__file__).resolve().parents[2] / "libexec" / "apt_helper.py"
_SYSTEM_PYTHON = "/usr/bin/python3"
_INSTALL_APT_BINDING = "sudo apt-get install python3-apt"
_MODULE_SIGNER = "Canonical Ltd. Kernel Module Signing"
_SYSTEM_MODINFO = ("/usr/sbin/modinfo", "/sbin/modinfo")
_LOG_DIRECTORY = "apt-logs"
# The newest logs that stay.
_KEEP_LOGS = 20

MODES = ("tracked", "all")


class AptEngineError(Exception):
    """The helper could not run; ``code`` names the reason, ``message`` says it."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.interrupted: Sequence[str] = ()


@dataclass(frozen=True)
class Request:
    """What one apt step needs to know. ``tracked`` is the set T of the enabled deb
    components. ``accept`` holds the keys of ``--accept``. ``constraints`` maps a
    constrained server to its version constraint (``{"sampledbms": "16.*"}``). ``kept``
    are the constraints and holds of the machine, which bind the depcache of the engine and no
    file: ``{component, kind (constraint or hold), version, reason, packages}``. ``gated`` is false only for
    ``[apt.gated] enable = false`` of the machine."""

    mode: str = "tracked"
    tracked: Sequence[str] = ()
    accept: Sequence[str] = ()
    constraints: Mapping[str, str] = field(default_factory=dict)
    kept: Sequence[Mapping[str, Any]] = ()
    gated: bool = True
    running_kernel: str | None = None
    codename: str | None = None
    boot_path: str | None = None
    boot_low_mib: int | None = None
    lock_timeout: int | None = None
    rollback_dir: str | None = None

    def to_json(self) -> dict[str, Any]:
        """The request as the helper reads it."""
        data: dict[str, Any] = {
            "mode": self.mode,
            "tracked": sorted(self.tracked),
            "accept": list(self.accept),
            "constraints": dict(self.constraints),
            "kept": [dict(rule) for rule in self.kept],
            "gated": self.gated,
            "running_kernel": self.running_kernel or os.uname().release,
        }
        if self.codename:
            data["codename"] = self.codename
        if self.boot_path:
            data["boot_path"] = self.boot_path
        if self.boot_low_mib:
            data["boot_low_mib"] = self.boot_low_mib
        if self.lock_timeout is not None:
            data["lock_timeout"] = self.lock_timeout
        if self.rollback_dir:
            data["rollback_dir"] = self.rollback_dir
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
            kept=tuple(dict(rule) for rule in data.get("kept") or ()),
            gated=bool(data.get("gated", True)),
            running_kernel=data.get("running_kernel"),
            codename=data.get("codename"),
            boot_path=data.get("boot_path"),
            boot_low_mib=data.get("boot_low_mib"),
            lock_timeout=data.get("lock_timeout"),
            rollback_dir=data.get("rollback_dir"),
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
    """The plan of one run; it needs no privileges and changes nothing. ``applicable`` is about the
    plan; ``items`` also hold what the module of the newest kernel looks like now, which a commit
    may have to leave as it is. Raises AptEngineError."""
    answer = _read_only("plan", request)
    answer["items"] = [*answer.get("items", ()), *module_check(answer)]
    return answer


def files(request: Request) -> dict[str, Any]:
    """The pin file as ``policy`` would write it from what dpkg has now: ``{pin: {path, text,
    header}}``, ``text`` null where no pin file belongs. Raises AptEngineError."""
    return _read_only("files", request)


_FIRST_TERMINAL_RUN = "the first 'dotsteward upgrade' on a terminal writes it"
_NEXT_TERMINAL_RUN = "the next 'dotsteward upgrade' on a terminal sets it"
_RULE = "Pin: version *"


def _pin_parts(text: str) -> tuple[str, frozenset[str], frozenset[str]]:
    """The header line, the pair blocks and the rule blocks of a pin file, as the dpkg hook reads
    it: what follows the header, split at empty lines; a block with ``Pin: version *`` is a rule."""
    header, _, rest = text.partition("\n")
    blocks = [block.strip("\n") for block in rest.split("\n\n") if block.strip("\n")]
    return (
        header,
        frozenset(block for block in blocks if _RULE not in block),
        frozenset(block for block in blocks if _RULE in block),
    )


def check_files(request: Request) -> list[dict[str, str]]:
    """The files of the apt engine there against ``files`` (design 10.3). The dpkg hook keeps the
    pairs of the pin file at what dpkg has after every dpkg run, whoever ran it; so a header or pairs
    that are not what dpkg has is the one finding (``apt-file-mismatch``). What the owner's own apt can
    bring is a note: the rule, which classes the file holds back, not yet what the next terminal run
    writes (``apt-file-rule``); a file there that the machine does not want (``apt-file-unwanted``); a
    file not there yet (``apt-file-missing``); an engine that cannot say (``apt-files-unchecked``). The
    constraints and holds of the instance have no file: they bind only what the engine itself does.
    The drop-in of unattended-upgrades is the system component apt-policy's, which checks it."""
    try:
        answer = files(request)
        entry = answer.get("pin")
        if not isinstance(entry, dict):
            raise AptEngineError("apt-helper-failed", "the answer has no pin file")
        path, wanted = str(entry.get("path") or ""), entry.get("text")
        if not path or not (wanted is None or isinstance(wanted, str)):
            raise AptEngineError("apt-helper-failed", "the answer has no pin file")
    except (AptEngineError, AttributeError) as failure:
        detail = f"{failure.code}: {failure.message}" if isinstance(failure, AptEngineError) else str(failure)
        return [_note("apt-files-unchecked", "", f"the pin file was not checked: {detail}")]
    return _check_pin(path, wanted)


def _read_there(path: str) -> tuple[str | None, str | None]:
    """The text of PATH (None when it is not there) and, when it cannot be read, why."""
    try:
        return Path(path).read_bytes().decode("utf-8", errors="replace"), None
    except FileNotFoundError:
        return None, None
    except OSError as error:
        return None, str(error.strerror)


def _check_pin(path: str, wanted: str | None) -> list[dict[str, str]]:
    there, unreadable = _read_there(path)
    if unreadable is not None:
        return [_note("apt-files-unchecked", path, f"the pin file was not checked: {path}: {unreadable}")]
    if there is None:
        return (
            []
            if wanted is None
            else [_note("apt-file-missing", path, f"{path} is not there yet: {_FIRST_TERMINAL_RUN}")]
        )
    if wanted is None:
        return [
            _note(
                "apt-file-unwanted",
                path,
                f"{path} is there, but this machine has no gated class to pin or [apt.gated] enable = false: "
                "the next 'dotsteward upgrade' on a terminal removes it",
            )
        ]
    if there == wanted:
        return []
    header, pairs, rules = _pin_parts(there)
    want_header, want_pairs, want_rules = _pin_parts(wanted)
    if header != want_header or pairs != want_pairs:
        return [
            _finding(
                "apt-file-mismatch",
                path,
                f"{path} does not hold what dpkg has now: run 'dotsteward upgrade' on a terminal, which rewrites it",
            )
        ]
    if rules != want_rules:
        return [
            _note(
                "apt-file-rule",
                path,
                f"{path} holds back other classes than this machine has now: {_NEXT_TERMINAL_RUN}",
            )
        ]
    return []


def _finding(code: str, path: str, message: str) -> dict[str, str]:
    return {"kind": "finding", "code": code, "path": path, "message": message}


def _note(code: str, path: str, message: str) -> dict[str, str]:
    return {"kind": "note", "code": code, "path": path, "message": message}


def _check_files_main(arguments: Sequence[str]) -> int:
    """One line per finding or note: KIND, CODE, PATH (- for none) and MESSAGE, tab separated.
    ``--instance DIR``: the request of this machine ([apt.gated] of its host file, the constraints
    and holds of its components); ``--request
    FILE|-``: a request as the other actions read it."""
    if len(arguments) != 2 or arguments[0] not in ("--instance", "--request"):
        print(
            "usage: python3 -m dotsteward_cli.apt_plan check-files --instance DIR | --request FILE|-", file=sys.stderr
        )
        return 2
    try:
        if arguments[0] == "--request":
            request = _load_request(arguments[1])
        else:
            instance = config.load_instance(arguments[1])
            name = machine.current_name(machine.read_machine(config.state_root(instance, os.environ)), os.environ)
            active = facts.active_components(instance, machine.effective(instance, os.environ)["profile"], os.environ)
            held = holds.component_holds(instance.root, name)
            request = Request(gated=facts.gated(instance, name), kept=facts.kept(active, instance, os.environ, held))
    except (config.DotstewardError, OSError, ValueError) as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return report.FAILED
    for item in check_files(request):
        fields = [item["kind"], item["code"], item["path"] or "-", item["message"]]
        print("\t".join(field.replace("\t", " ").replace("\n", " ") for field in fields))
    return report.OK


def analysis(request: Request) -> dict[str, Any]:
    """The read only look at the apt channel: upgradable packages outside ``tracked``,
    what phasing defers, the kernels and the free space of /boot. Raises AptEngineError."""
    return _read_only("analysis", request)


def sudo_prefix() -> list[str]:
    """Root needs no sudo; ``DOTSTEWARD_APT_SUDO`` is the way in for tests of rootless worlds."""
    configured = os.environ.get("DOTSTEWARD_APT_SUDO")
    if configured is not None:
        return shlex.split(configured)
    return [] if os.geteuid() == 0 else ["sudo", "-n"]


def _new_log(action: str, state_root: str | os.PathLike[str] | None) -> Path:
    """An empty private file for the output of ACTION; older ones beyond the newest few go."""
    try:
        root = os.fspath(state_root) if state_root is not None else config.required_state_root()
    except config.DotstewardError as error:
        raise AptEngineError("no-state-root", str(error)) from error
    directory = Path(root) / _LOG_DIRECTORY
    atomic.make_private_dirs(directory)
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%S")
    path = directory / f"{action}-{stamp}-{os.getpid()}.log"
    path.touch(mode=0o600)
    logs = sorted(directory.glob("*.log"), key=lambda log: log.stat().st_mtime_ns, reverse=True)
    for old in logs[_KEEP_LOGS:]:
        old.unlink(missing_ok=True)
    return path


@contextlib.contextmanager
def _shown_on_stderr(log: Path) -> Iterator[None]:
    """Standard error shows what the file gets, while there is someone to see it. A failed write
    ends this and nothing else; a stream nobody reads does not hold up the end of the run. Without
    a standard error descriptor 2 can be any file of this process, so nothing is shown."""
    if sys.stderr is None:
        yield
        return
    finished = threading.Event()

    def show() -> None:
        with contextlib.suppress(OSError), log.open("rb") as source:
            while True:
                last_round = finished.is_set()
                data = source.read(65536)
                while data:
                    data = data[os.write(2, data) :]
                if last_round:
                    return
                finished.wait(0.1)

    shower = threading.Thread(target=show, daemon=True)
    shower.start()
    try:
        yield
    finally:
        finished.set()
        shower.join(timeout=5)


def _privileged(action: str, request: Request, state_root: str | os.PathLike[str] | None) -> dict[str, Any]:
    """Runs an action of the helper as a protected child, its answer in one file and what dpkg prints
    in another. Raises AptEngineError; with signals in ``interrupted``."""
    prefix = sudo_prefix()
    if prefix[:1] == ["sudo"]:
        check = subprocess.run([*prefix, "true"], capture_output=True, check=False)
        if check.returncode != 0:
            raise AptEngineError("sudo-required", "this step needs sudo: run the command in a terminal")
    log = _new_log(action, state_root)
    with tempfile.TemporaryDirectory(prefix="dotsteward-apt-") as directory:
        answer_path = Path(directory) / "answer.json"
        request_path = Path(directory) / "request.json"
        request_path.write_text(json.dumps(request.to_json()), encoding="utf-8")
        argv = [*prefix, *_helper_argv(action), "--output", str(answer_path)]
        try:
            with request_path.open("rb") as stdin, log.open("ab") as output, _shown_on_stderr(log):
                result = procs.run_protected(argv, stdin=stdin, stdout=output, stderr=output)
        except OSError as error:
            raise AptEngineError("python3-apt-missing", f"cannot start {shlex.join(argv)}: {error}") from error
        finally:
            printed = log.stat().st_size > 0
            if not printed:
                log.unlink()
        if not answer_path.exists():
            where = f", see {log}" if printed else ""
            detail = f"the apt helper ended with status {result.returncode}{where}"
            failure = AptEngineError("apt-helper-failed", detail)
            failure.interrupted = result.interrupted
            raise failure
        answer: dict[str, Any] = json.loads(answer_path.read_text(encoding="utf-8"))
    try:
        checked = _checked(answer)
    except AptEngineError as failure:
        failure.interrupted = result.interrupted
        raise
    checked["interrupted"] = list(result.interrupted)
    if printed:
        checked["log"] = str(log)
    return checked


def policy(request: Request, *, state_root: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """Writes the pin file and its dpkg hook from what dpkg has, whatever they said before: the
    first step that writes in a run, and the repair of an interrupted one."""
    return _privileged("policy", request, state_root)


def recover(request: Request, *, state_root: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """``dpkg --audit``, and ``dpkg --configure -a`` when dpkg was left half way."""
    return _privileged("recover", request, state_root)


def commit(request: Request, *, state_root: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """The plan and, when nothing refuses it, the same depcache applied under the lock of dpkg. The
    pin file follows what dpkg has afterwards. ``status`` tells the outcome: committed, nothing,
    refused, blocked, fetch-failed, dpkg-failed; the items say the rest. Without STATE_ROOT the one
    the commands agree on (config.required_state_root) holds what dpkg prints."""
    answer = _privileged("commit", request, state_root)
    answer["items"] = [*answer.get("items", ()), *module_check(answer)]
    return answer


def _modinfo() -> str | None:
    """The modinfo of the system: one from PATH may come from another prefix and look elsewhere for
    /lib/modules. DOTSTEWARD_MODINFO is the way in for tests."""
    configured = os.environ.get("DOTSTEWARD_MODINFO")
    if configured is not None:
        return configured if os.access(configured, os.X_OK) else None
    return next((path for path in _SYSTEM_MODINFO if os.access(path, os.X_OK)), None)


def module_check(answer: Mapping[str, Any]) -> list[dict[str, Any]]:
    """The module of the kernel GRUB boots by default, the newest installed one, as ``modinfo`` finds
    it: what ``newest_kernel`` of an answer names. Nothing to look at without the NVIDIA class, or when
    the plan in hand brings the module. A prebuilt module is signed by the distribution and matches
    the driver; a module the machine builds itself (DKMS) carries the key of the machine."""
    newest = answer.get("newest_kernel")
    if not newest or not newest.get("nvidia") or newest.get("planned"):
        return []
    release = newest["release"]
    modinfo = _modinfo()
    if modinfo is None:
        return [{"code": "module-unchecked", "pending": False, "kernel": release, "message": "no modinfo"}]

    def field(name: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [modinfo, "-k", release, "-F", name, "nvidia"], capture_output=True, text=True, check=False
        )

    signer = field("signer")
    if signer.returncode != 0:
        message = f"the newest kernel {release} has no nvidia module: do not reboot into it yet"
        return [{"code": "module-missing", "pending": True, "kernel": release, "message": message}]
    items: list[dict[str, Any]] = []
    name = signer.stdout.strip()
    prebuilt = bool(newest.get("prebuilt"))
    if name != _MODULE_SIGNER:
        message = f"the nvidia module of {release} is signed by {name or 'nobody'}"
        items.append(
            {"code": "module-signer", "pending": prebuilt, "kernel": release, "signer": name, "message": message}
        )
    module_version = field("version").stdout.strip()
    driver = (newest.get("driver_version") or "").split(":")[-1].split("-")[0]
    if module_version and driver and module_version != driver:
        message = f"the nvidia module of {release} is {module_version}, the driver is {driver}"
        items.append(
            {
                "code": "module-version",
                "pending": True,
                "kernel": release,
                "module": module_version,
                "driver": driver,
                "message": message,
            }
        )
    return items


_STEP_OUTCOME = {"fetch-failed": report.PARTIAL, "dpkg-failed": report.FAILED}


def record(run: report.RunReport, answer: Mapping[str, Any], *, step: str = "apt-plan") -> None:
    """Puts an answer of the helper into a run report: one step, and one review item for each
    item of the answer. An item with ``pending`` makes the run wait for a person."""
    outcome = _STEP_OUTCOME.get(answer.get("status", ""), report.OK)
    for item in answer.get("items", ()):
        fields = {key: value for key, value in item.items() if key not in {"code", "pending"}}
        pending = bool(item.get("pending"))
        run.item(item["code"], pending=pending, **fields)
        if pending:
            outcome = report.combine([outcome, report.PENDING])
    for path in answer.get("dpkg_dist", ()):
        run.item("dpkg-dist", pending=False, path=path)
    rollback = answer.get("rollback") or {}
    if rollback.get("missing"):
        run.item("rollback-missing", pending=False, packages=rollback["missing"])
    details = {"apt_status": answer["status"]} if "status" in answer else {}
    if answer.get("message"):
        details["detail"] = answer["message"]
    if answer.get("log"):
        details["log"] = answer["log"]
    run.step(step, outcome, **details)
    if answer.get("interrupted"):
        run.mark_interrupted(answer["interrupted"])


def record_failure(run: report.RunReport, failure: AptEngineError, *, step: str = "apt-plan") -> None:
    """Puts a helper that could not run into a run report."""
    if failure.interrupted:
        run.mark_interrupted(list(failure.interrupted))
    if failure.code == "python3-apt-missing":
        run.item(failure.code, run=_INSTALL_APT_BINDING, message=failure.message)
        run.step(step, report.PENDING, detail=failure.message)
        return
    if failure.code == "sudo-required":
        run.item(failure.code, run="dotsteward upgrade", message=failure.message)
        run.step(step, report.PENDING, detail=failure.message)
        return
    run.step(step, report.FAILED, detail=f"{failure.code}: {failure.message}")


def _action(name: str, request: Request, state_root: str | None) -> dict[str, Any]:
    if name == "plan":
        return plan(request)
    if name == "analysis":
        return analysis(request)
    if name == "files":
        return files(request)
    changing = {"policy": policy, "recover": recover, "commit": commit}
    return changing[name](request, state_root=state_root)


ACTIONS = ("analysis", "commit", "files", "plan", "policy", "recover")


def _load_request(source: str | None) -> Request:
    if source is None:
        return Request()
    text = sys.stdin.read() if source == "-" else Path(source).read_text(encoding="utf-8")
    return Request.from_json(json.loads(text))


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments[:1] == ["check-files"]:
        return _check_files_main(arguments[1:])
    parser = argparse.ArgumentParser(
        prog="dotsteward_cli.apt_plan", description="The apt engine, for tests and by hand."
    )
    parser.add_argument("action", choices=ACTIONS)
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
        try:
            run = report.RunReport(options.report, options.state_root or config.required_state_root())
        except config.DotstewardError as error:
            print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
            return report.FAILED
    try:
        answer = _action(options.action, request, options.state_root)
    except AptEngineError as failure:
        print(f"[dotsteward] ERROR: {failure.code}: {failure.message}", file=sys.stderr)
        if run is None:
            return report.FAILED
        record_failure(run, failure, step=options.action)
        run.write()
        return run.exit_code
    # The report first: the terminal that gets the answer may be gone by now.
    if run is not None:
        record(run, answer, step=options.action)
        run.write()
    with contextlib.suppress(OSError):
        print(json.dumps(answer, indent=2, sort_keys=True), flush=True)
    return report.OK if run is None else run.exit_code


if __name__ == "__main__":
    sys.exit(main())
