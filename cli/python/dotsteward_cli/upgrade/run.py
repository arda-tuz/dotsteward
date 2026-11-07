"""A run of ``dotsteward upgrade``: convergent phases, see docs/upgrade.md.

Every run works out again what is needed and does what it can; the same command finishes what a
run left. There is no journal and no resume: the state is in dpkg, in git, in the records of
``rebuild`` and ``e2e``, and in a few files under ``<state>/upgrade``. The engines do the work and
this file only puts them in order:

    0  name, host publish, reconcile, capture, fetch, fast-forward, the questions
    1  one sudo window before all Nix work: recovery, pin, bridge, apt-get update, the apt plan
    2  writer, gate, local commit; self triggers; plugin scan; rebuild; channels of the user
    3  E2E with a key, machine checks, the red path
    4  publish, the checkout follows, analysis and the offer, firmware in a window of its own, the report

The checkout belongs to its owner. Everything the writer does happens in a clone of the fetched tip
under ``<state>/upgrade/work``, as ``dotsteward-update`` does and as a capture does in its worktree:
the writer, the gate, the commit, and the rebuild and E2E of that commit. The clone is what a failed
or interrupted run throws away; nothing here resets, cleans or adds in the checkout, which only ever
fast-forwards, when it is clean. A commit that waits for the remote is the ref WAITING_REF.

A clone and no linked worktree, because the gate and ``txn publish`` ask for a clone on the branch
of the instance, and a linked worktree cannot have the branch the checkout has. It shares the objects
of the checkout. A rebuild from the clone leaves the records of the machine naming the clone, so the
checkout runs a last rebuild when it has caught up: the build comes from the store by then.

Never here: an OS release upgrade, autoremove, a reboot.
"""

from __future__ import annotations

import collections
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import apt_plan, atomic, config, firmware, machine, procs, report
from dotsteward_cli import publish as publishing
from dotsteward_cli.host import commit_identity
from dotsteward_cli.skills import commands as skills_commands
from dotsteward_cli.skills import state as skill_state
from dotsteward_cli.upgrade import analysis, facts, holds, plugins

WAITING_REF = "refs/dotsteward/upgrade/waiting"
_WORK = "work"
_PUBLISH_SCOPE = "upgrade"
_WEEK_SECONDS = 7 * 24 * 60 * 60
_STALE_PRODUCER_SECONDS = 14 * 24 * 60 * 60
_FLAKE_INPUTS = "flake_inputs.*"
_BRIDGE = "/usr/local/lib/dotsteward/apt-bridge.sh"
_BRIDGE_CONF = "/etc/dotsteward/apt-bridge.d"
_BRIDGE_REPO = "/var/lib/dotsteward/apt-bridge"
_APT_LOCK_SECONDS = 300
_VERSION_SECONDS = 20
_INTERRUPTED = 130
_SKILL_ITEMS = {
    "ask": ("origin-unknown", "where this skill comes from is not known: say what becomes of it"),
    "conflict": ("skill-conflict", "this skill changed here and on the remote"),
    "blocked": ("capture-blocked", "this skill was not published"),
}
_NOT_COMPONENTS = {"core", "setup"}
# 128 + SIGINT, SIGTERM, SIGHUP.
_SIGNALLED = {130, 143, 129}
_APT_BUCKETS = ("install", "upgrade", "remove", "downgrade")
# Config of the checkout the clone needs to behave the same.
_CLONE_CONFIG = ("core.hooksPath", "core.sshCommand", "user.name", "user.email")
_STEP_WORDS = {"pending": "waits for you", "partial": "skipped, no network", "failed": "failed"}
# What says that the gate could not judge the tree, rather than that the tree is red: in its own
# words or in its log. A red of these holds nothing.
_GATE_LOCKED = "another gate is running"
_ENVIRONMENT_MARKERS = (
    "No space left on device",
    "Cannot allocate memory",
    "Out of memory",
    "out of memory",
    "killed by signal 9",
)
# A child killed from outside: 137 through a shell, a negative status straight from Python.
_KILLED = 137
_NO_RESULT = "unknown"
RETRY_HELD = "dotsteward upgrade --retry-held"
_WRITER_ITEMS = {
    "skill-transform": "have a newer upstream and a local transform; dotsteward-update moves them",
}


def _say(text: str) -> None:
    print(f"[upgrade] {text}", flush=True)


def _ask_yes(question: str) -> bool:
    print(f"{question} [y/N] ", end="", flush=True)
    return sys.stdin.readline().strip().lower() in {"y", "yes", "e", "evet"}


class Upgrade:
    """One run, under the instance lock of its caller."""

    def __init__(
        self,
        instance: config.Instance,
        state_root: str,
        mode: str,
        accept: Sequence[str],
        terminal: bool,
        arguments: Sequence[str],
        again: Callable[[], None],
    ) -> None:
        self.instance = instance
        self.root = instance.root
        self.state_root = state_root
        self.mode = mode
        self.accept = tuple(accept)
        self.terminal = terminal
        self.arguments = list(arguments)
        self.again = again
        self.env = os.environ
        self.run = report.RunReport("upgrade", state_root)
        self.upgrade_dir = Path(state_root) / "upgrade"
        self.linux = config.runtime_platform(self.env) == "linux"
        self.branch = str(instance.config["instance"]["branch"])
        self.name: str | None = None
        self.profile: str | None = None
        self.offline = False
        self.dirty = False
        self.tip = ""
        self.apt_changed = False
        self.apt_answer: dict[str, Any] | None = None
        self.red = False
        self.verified = False
        self.interrupted = False
        self.framework_moved = False
        self.work: Path | None = None
        self.waiting: str | None = None
        self.moved: list[dict[str, Any]] = []
        self.approved: tuple[firmware.Device, ...] = ()
        self.paths: report.ReportPaths | None = None
        self.quiet_output = ""
        self.e2e_status = 0
        last = report.load_last(state_root, "upgrade") or {}
        data = last.get("data") if isinstance(last.get("data"), dict) else {}
        if isinstance(data, dict) and isinstance(data.get("moved"), list):
            self.moved = data["moved"]
        self.run.data.update(mode=mode)

    # --- helpers ---------------------------------------------------------------------------

    def _target(self) -> Path:
        """Where the tree of this run is: the clone while it has a commit, else the checkout."""
        return self.work or self.root

    def _cli(self) -> list[str]:
        if self.framework_moved:
            return [str(self._target() / ".dotsteward" / "cli.sh")]
        return [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(self._target())]

    def _ds(self, *arguments: str) -> int:
        """A command of this CLI on this terminal. A signal that ended it ends the run as well: an
        interrupted rebuild is no red one."""
        return self._attached([*self._cli(), *arguments])

    def _attached(self, argv: list[str]) -> int:
        status = procs.run_attached(argv)
        if status in _SIGNALLED:
            raise KeyboardInterrupt
        return status

    def _ds_output(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        """A command of this CLI, its standard output kept: JSON, or noise for this report."""
        return subprocess.run(
            [*self._cli(), *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True, check=False
        )

    def _ds_quiet(self, *arguments: str) -> int:
        """A command of this CLI that prints a lot on a good day: its own lines pass as they come, the
        rest is shown only when it fails."""
        with subprocess.Popen(
            [*self._cli(), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ) as child:
            assert child.stdout is not None
            others = []
            said = []
            for line in child.stdout:
                said.append(line)
                if line.startswith("[dotsteward]"):
                    print(line, end="", flush=True)
                else:
                    others.append(line)
        self.quiet_output = "".join(said)
        if child.returncode in _SIGNALLED:
            raise KeyboardInterrupt
        if child.returncode != 0:
            print("".join(others), end="", flush=True)
        return child.returncode

    def _git(self, *arguments: str) -> publishing.GitResult:
        """Git in the checkout: reading, a fetch, a fast-forward. Nothing else ever runs there."""
        return publishing.git(self.root, *arguments)

    def _work_git(self, *arguments: str) -> publishing.GitResult:
        assert self.work is not None
        return publishing.git(self.work, *arguments)

    def _head(self) -> str:
        return self._git("rev-parse", "HEAD").stdout.strip()

    def _tree_of(self, where: Path) -> str:
        return publishing.git(where, "rev-parse", "HEAD^{tree}").stdout.strip()

    def _command_again(self) -> str:
        """The command that does what waits."""
        return " ".join(["dotsteward upgrade", *self.arguments])

    def _active(self) -> list[dict[str, Any]]:
        return facts.active_components(self.instance, self.profile, self.env)

    def _request(self, mode: str) -> apt_plan.Request:
        active = self._active()
        return apt_plan.Request(
            mode=mode,
            tracked=facts.tracked_packages(active, self.instance),
            accept=tuple(key for key in self.accept if key != "firmware"),
            constraints=facts.constraints(active, self.instance),
            gated=facts.gated(self.instance, self.name),
        )

    def _checkout_clean(self) -> bool:
        return not self._git("status", "--porcelain", "--untracked-files=normal").stdout.strip()

    # --- the run ---------------------------------------------------------------------------

    def execute(self) -> int:
        def interrupted(signum: int, frame: object) -> None:
            raise KeyboardInterrupt

        for number in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, interrupted)
        try:
            if self._front():
                self._questions()
                self._window(self.mode)
                self._producer()
                self._self_updates()
                self._plugins()
                self._rebuild()
                if self.mode == "all":
                    self._user_channels()
                self._e2e()
                self._host_checks()
                self._publish()
                self._after()
        except KeyboardInterrupt:
            # One way out, from every phase: what ran stays, what a later step would do does not
            # start. The next run finishes.
            self.interrupted = True
            self.run.mark_interrupted(self.run.interrupted or ["SIGINT"])
            self.run.step("interrupted", report.FAILED, detail="the next run finishes what this one left")
        finally:
            self._leave_work()
        return self._end()

    def _end(self) -> int:
        told = {item.get("id") for item in self.run.items if item.get("code") == "red-held"}
        for hold in holds.read(self.state_root):
            if hold.get("id") not in told:
                message = f"{hold.get('id')} stays at the version before {hold.get('version')}: {hold.get('reason')}"
                self.run.item(
                    "held",
                    pending=False,
                    id=hold.get("id"),
                    version=hold.get("version"),
                    message=message,
                    run=RETRY_HELD,
                )
        self.run.data.update(
            own_commits=[self.waiting] if self.waiting else [], moved=self.moved if self.waiting else []
        )
        self.paths = self.run.write()
        for step in self.run.steps:
            if step["status"] != "ok":
                detail = step.get("detail") or (f"exit status {step['exit_status']}" if "exit_status" in step else "")
                word = _STEP_WORDS.get(step["status"], step["status"])
                _say(f"{step['name']}: {word}" + (f" ({detail})" if detail else ""))
        _say(f"{self.run.status}: report {self.paths.report}")
        for item in self.run.items:
            said = [str(item[key]) for key in ("name", "message", "run", "accept", "hint") if item.get(key)]
            if item.get("findings"):
                said.append("checks: " + ", ".join(str(check) for check in item["findings"]))
            if item.get("log"):
                said.append(f"log: {item['log']}")
            if said:
                _say(f"{item['code']}: " + " -> ".join(said))
        self._say_writer_items()
        if self.paths.review is not None:
            _say(f"see {self.paths.review}")
        return _INTERRUPTED if self.interrupted else self.run.exit_code

    def _say_writer_items(self) -> None:
        review = report.load_review(self.state_root) or {}
        codes = collections.Counter(
            str(item.get("code")) for item in review.get("items") or () if item.get("command") == "pins-apply"
        )
        for code, count in sorted(codes.items()):
            _say(f"{count} {code}: " + _WRITER_ITEMS.get(code, "the writer left this for a person or an agent"))

    def document(self) -> dict[str, Any]:
        """The report as ``--json`` prints it."""
        assert self.paths is not None
        document: dict[str, Any] = json.loads(self.paths.report.read_text(encoding="utf-8"))
        document["report"] = str(self.paths.report)
        document["review"] = str(self.paths.review) if self.paths.review else None
        return document

    # --- the clone -------------------------------------------------------------------------

    def _open_work(self, commit: str) -> bool:
        """A clone with COMMIT as the branch of the instance, whatever an earlier run left there."""
        self._remove_work()
        atomic.make_private_dirs(self.upgrade_dir)
        path = self.upgrade_dir / _WORK
        made = self._git("clone", "--quiet", "--shared", "--no-checkout", str(self.root), str(path))
        if made.code != 0:
            self.run.step("clone", report.FAILED, detail=made.stderr.strip())
            return False
        self.work = path
        remote = str(self.instance.config["instance"]["remote"])
        self._work_git("remote", "set-url", "origin", remote)
        for key in _CLONE_CONFIG:
            value = self._git("config", "--get", key).stdout.strip()
            if value:
                self._work_git("config", key, value)
        checked = self._work_git("checkout", "--quiet", "-B", self.branch, commit)
        if checked.code != 0:
            self.run.step("clone", report.FAILED, detail=checked.stderr.strip())
            self._remove_work()
            return False
        return True

    def _remove_work(self) -> None:
        shutil.rmtree(self.upgrade_dir / _WORK, ignore_errors=True)
        self.work = None

    def _leave_work(self) -> None:
        """The clone goes. The hooks of the agents must not keep naming it, also when the checkout
        cannot take the records of the machine back yet."""
        path = self.upgrade_dir / _WORK
        named = os.path.realpath(str(self._activation().get("root"))) == os.path.realpath(path)
        self._remove_work()
        self.framework_moved = False
        if named and skills_commands.tracking_on(self.instance):
            self._ds_output("skills", "hooks", "install")

    def _keep_waiting(self) -> None:
        """The commit of the clone, in the objects of the checkout under a ref of its own."""
        assert self.work is not None
        self._git("fetch", "--quiet", "--no-tags", "--refmap=", str(self.work), f"+HEAD:{WAITING_REF}")
        self.waiting = self._work_git("rev-parse", "HEAD").stdout.strip()

    def _drop_waiting(self) -> None:
        self._git("update-ref", "-d", WAITING_REF)
        self.waiting = None
        self.moved = []

    # --- phase 0 ---------------------------------------------------------------------------

    def _front(self) -> bool:
        self._name_machine()
        if self.name is not None:
            status = self._ds_output("host", "publish").returncode
            self.run.step("host-publish", status)
        self._skills()
        return self._fetch()

    def _effective(self) -> None:
        effective = machine.effective(self.instance, self.env)
        self.name, self.profile = effective["name"], effective["profile"]
        self.run.data.update(machine=self.name, profile=self.profile)

    def _name_machine(self) -> None:
        self._effective()
        if self.name is None and self.terminal:
            self.run.step("host-init", self._ds("host", "init"))
            self._effective()
        if self.name is None:
            self.run.item(
                "machine-name-required",
                run="dotsteward host init",
                message="this machine has no name yet: no pins move, nothing is published and no firmware is applied",
            )

    def _skills(self) -> None:
        """What this machine made goes out first: a push of it must not look like a remote ahead of here."""
        if not skills_commands.tracking_on(self.instance):
            return
        self.run.step("skills-reconcile", self._ds_output("skills", "reconcile", "--full", "--json").returncode)
        self.run.step("skills-capture", self._ds_output("skills", "capture", "--now", "--json").returncode)
        pending = skill_state.load_pending(self.state_root).get("items") or {}
        for key, item in sorted(pending.items()):
            known = _SKILL_ITEMS.get(str(item.get("state"))) if isinstance(item, dict) else None
            if known:
                self.run.item(known[0], name=key.partition(":")[2], reason=item.get("reason"), message=known[1])

    def _fetch(self) -> bool:
        """The remote, and this checkout on its tip when it is clean. False: a refusal that ends the run."""
        if self._git("rev-parse", "--is-inside-work-tree").code != 0:
            return self._refuse(f"{self.root} is not a git work tree")
        current = self._git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        if current != self.branch:
            return self._refuse(f"the checkout is on {current}, not on {self.branch}")
        remote = self._git("config", "--get", "remote.origin.url").stdout.strip()
        if remote != self.instance.config["instance"]["remote"]:
            return self._refuse(f"origin is {remote or 'missing'}, not {self.instance.config['instance']['remote']}")
        self.dirty = not self._checkout_clean()
        if self.dirty:
            self.run.item(
                "checkout-dirty",
                pending=False,
                root=str(self.root),
                message="the checkout has uncommitted changes: it stays as it is, a rebuild from it waits",
            )
        waiting = self._git("rev-parse", "--verify", "--quiet", WAITING_REF).stdout.strip() or None
        outcome, tip, detail = publishing.fetch_tip(self.root, self.branch, _PUBLISH_SCOPE)
        if outcome != publishing.OK:
            self.offline = True
            self.waiting = waiting
            if outcome == publishing.REFUSED:
                self.run.item("remote-refused", message=detail)
                self.run.step("fetch", report.FAILED, detail="the remote refused")
            else:
                self.run.step("fetch", report.PARTIAL, detail="offline")
            return True
        self.tip = tip
        self.run.step("fetch", report.OK)
        head = self._head()
        ahead = self._git("rev-list", f"{tip}..{head}").stdout.split()
        behind = self._git("rev-list", f"{head}..{tip}").stdout.split()
        if ahead:
            return self._refuse(
                f"this checkout has local commits that are not published: {ahead[0][:12]}; publish them first"
            )
        if waiting and self._git("rev-parse", f"{waiting}^").stdout.strip() == tip:
            self.waiting = waiting
        elif waiting:
            # Another machine came first: no merge of pins, the writer starts again on the new tip.
            self._drop_waiting()
            _say("another machine published first: the waiting commit is made again on the new tip")
        if behind and not self.dirty:
            done = self._git("merge", "--quiet", "--ff-only", tip)
            if done.code != 0:
                return self._refuse(f"cannot fast-forward to {tip[:12]}: {done.stderr.strip()}")
            self.again()
            self.instance = config.load_instance()
            self._effective()
        return True

    def _refuse(self, message: str) -> bool:
        print(f"[dotsteward] ERROR: {message}", file=sys.stderr)
        self.run.step("guard", report.FAILED, detail=message)
        return False

    def _incoming(self) -> None:
        """The question about changes from other machines (Y3) comes here, before sudo and the long
        builds, with a later release: `dotsteward_cli.incoming` and its review items."""

    def _questions(self) -> None:
        self._incoming()
        if not self.linux:
            return
        listing = firmware.list_updates()
        if listing.error:
            self.run.step("firmware-list", report.OK, detail=listing.error)
        self.approved = firmware.approve(listing, self.run, accepted="firmware" in self.accept, tty=self.terminal)

    # --- phase 1: the sudo window ----------------------------------------------------------

    def _sudo(self) -> list[str]:
        return apt_plan.sudo_prefix()

    def _open_sudo(self) -> bool:
        return self._sudo()[:1] != ["sudo"] or subprocess.run(["sudo", "-v"], check=False).returncode == 0

    def _close_sudo(self) -> None:
        if self._sudo()[:1] == ["sudo"]:
            subprocess.run(["sudo", "-k"], check=False)

    def _hand_over(self) -> None:
        message = "this step needs sudo: run the command in a terminal"
        if sys.stdin.isatty():
            message = "this step needs sudo and a terminal, and standard output is not one: run it without a pipe"
        self.run.item("sudo-required", run=self._command_again(), message=message)

    def _sudo_ready(self) -> bool:
        """Sudo still works, or a terminal opens it once more: a long step can outlast its timestamp."""
        prefix = self._sudo()
        if prefix[:1] != ["sudo"]:
            return True
        if subprocess.run([*prefix, "true"], capture_output=True, check=False).returncode == 0:
            return True
        if self.terminal and self._open_sudo():
            return True
        self._hand_over()
        self.run.step("sudo", report.PENDING, detail="sudo closed during the window")
        return False

    def _engine(self, step: str, call: Callable[[], dict[str, Any]]) -> dict[str, Any] | None:
        """A step of the apt engine. None: the window ends here."""
        if not self._sudo_ready():
            return None
        try:
            answer = call()
        except apt_plan.AptEngineError as failure:
            if failure.code == "sudo-required":
                self._hand_over()
                self.run.step(step, report.PENDING, detail=failure.message)
            else:
                apt_plan.record_failure(self.run, failure, step=step)
            return None
        apt_plan.record(self.run, answer, step=step)
        if answer.get("interrupted"):
            # dpkg was left to finish; the run ends with it.
            raise KeyboardInterrupt
        return answer

    def _privileged(self, step: str, *command: str) -> bool:
        """A command as root, protected from Ctrl-C at the terminal. False: the window ends here."""
        if not self._sudo_ready():
            return False
        result = procs.run_protected([*self._sudo(), *command])
        self.run.step(step, result.returncode)
        if result.interrupted:
            self.run.mark_interrupted(result.interrupted)
            raise KeyboardInterrupt
        return True

    def _window(self, mode: str) -> None:
        if not self.linux:
            self.run.step("apt", report.OK, detail=f"nothing to do on {config.runtime_platform(self.env)}")
            return
        if not self.terminal:
            self._hand_over()
            self.run.step("sudo", report.PENDING, detail="no terminal: the sudo steps wait")
            return
        _say("the sudo window: apt first, sudo closes before the long builds")
        if not self._open_sudo():
            self._hand_over()
            self.run.step("sudo", report.PENDING, detail="sudo did not open")
            return
        try:
            if self._apt(mode) and mode == "all" and not self.offline:
                self._system_channels()
        finally:
            self._close_sudo()

    def _apt(self, mode: str) -> bool:
        """False: the window ended early."""
        request = self._request(mode)
        state = self.state_root
        if self._engine("dpkg-recover", lambda: apt_plan.recover(request, state_root=state)) is None:
            return False
        if self._engine("policy", lambda: apt_plan.policy(request, state_root=state)) is None:
            return False
        if self.offline:
            self.run.step("apt-commit", report.PARTIAL, detail="offline")
            return True
        root = Path(self.env.get("DOTSTEWARD_SYSTEM_ROOT") or "/")
        if (root / _BRIDGE.lstrip("/")).is_file() and not self._privileged(
            "apt-bridge", "bash", _BRIDGE, _BRIDGE_CONF, _BRIDGE_REPO
        ):
            return False
        lock_timeout = f"DPkg::Lock::Timeout={_APT_LOCK_SECONDS}"
        if not self._privileged("apt-update", "apt-get", "-q", "-o", lock_timeout, "update"):
            return False
        answer = self._engine("apt-commit", lambda: apt_plan.commit(request, state_root=state))
        if answer is None:
            return False
        self.apt_answer = answer
        changes = answer.get("changes") or {}
        counted = [f"{len(changes[bucket])} {bucket}" for bucket in _APT_BUCKETS if changes.get(bucket)]
        _say(f"apt ({mode}): " + (", ".join(counted) or "nothing to do"))
        if answer.get("committed") and counted:
            self.apt_changed = True
        return True

    def _system_channels(self) -> None:
        if shutil.which("snap") and not self._privileged("snap", "snap", "refresh"):
            return
        if shutil.which("flatpak"):
            self._privileged("flatpak-system", "flatpak", "update", "--system", "--noninteractive", "-y")

    # --- phase 2 ---------------------------------------------------------------------------

    def _week_due(self) -> bool:
        path = self.upgrade_dir / "nix-week.json"
        try:
            moved_at = float(json.loads(path.read_text(encoding="utf-8"))["moved_at"])
        except (OSError, ValueError, KeyError, TypeError):
            return True
        return time.time() - moved_at >= _WEEK_SECONDS

    def _start_week(self) -> None:
        atomic.make_private_dirs(self.upgrade_dir)
        atomic.atomic_write_json(self.upgrade_dir / "nix-week.json", {"moved_at": time.time()}, mode=0o600)

    def _not_the_producer(self, role: str) -> None:
        if role == "unnamed":
            self.run.step("pins-apply", report.OK, detail="this machine has no name")
            return
        if role == "nobody":
            self.run.item(
                "producer-unset",
                pending=False,
                run=f"dotsteward host producer {self.name or 'NAME'}",
                message="several machines and no producer: nobody moves the pins",
            )
            self.run.step("pins-apply", report.OK, detail="no producer")
            return
        last = self._git("log", "-1", "--format=%ct", "--", "flake.lock", "versions.lock.json").stdout.strip()
        age = time.time() - float(last) if last else None
        _say(f"pins move on {role}" + (f", last {int(age // 86400)} days ago" if age is not None else ""))
        if age is not None and age > _STALE_PRODUCER_SECONDS:
            self.run.item(
                "producer-stale",
                pending=False,
                producer=role,
                days=int(age // 86400),
                message=f"the pins have not moved for {int(age // 86400)} days: look at {role}",
            )
        self.run.step("pins-apply", report.OK, detail=f"the producer is {role}")

    def _apply(self, latest: Path, skips: Sequence[str]) -> dict[str, Any] | None:
        """One run of the writer in the clone. None: nothing can come of it. A group that failed is put
        back by the writer, so what the others moved still goes on."""
        arguments = ["pins", "apply", "--latest", str(latest), "--json"]
        for pattern in skips:
            arguments += ["--skip", pattern]
        done = self._ds_output(*arguments)
        if done.returncode in _SIGNALLED:
            raise KeyboardInterrupt
        try:
            answer: dict[str, Any] = json.loads(done.stdout)
        except ValueError:
            self.run.step("pins-apply", done.returncode or report.FAILED, detail="the writer gave no answer")
            return None
        self.run.step("pins-apply", done.returncode, moved=[row.get("id") for row in answer.get("moved") or ()])
        for group in answer.get("groups") or ():
            if group.get("outcome") == "failed":
                self.run.item(
                    "pins-group-failed",
                    pending=False,
                    ids=group.get("ids"),
                    message=f"{group.get('group')} did not move: {group.get('error')}",
                )
        return answer

    def _hold_moved(self, rows: Sequence[Mapping[str, Any]], red: Sequence[str], reason: str) -> None:
        """A local hold for each pin that went red: the writer leaves it until upstream has something
        newer. The pins of a component the red checks name, all of them when they name none."""
        components = {check.split(":", 1)[0] for check in red} - _NOT_COMPONENTS
        owners = facts.pin_owners(self._active())
        guilty = [row for row in rows if owners.get(str(row.get("id"))) in components]
        guilty = guilty or [row for row in rows if components & set(str(row.get("id")).split("."))]
        for row in guilty or rows:
            identifier = str(row.get("id"))
            component = owners.get(identifier) or next(iter(sorted(components)), identifier)
            holds.add(self.state_root, component, identifier, str(row.get("to")), reason)
            self.run.item(
                "red-held",
                id=identifier,
                version=row.get("to"),
                reason=reason,
                message=f"{identifier} {row.get('to')} stays back until upstream has something newer: {reason}",
            )

    def _producer(self) -> None:
        if self.waiting is not None:
            # Its tree goes on where the last run stopped: rebuild, E2E, publish.
            if self._open_work(self.waiting):
                self.run.step("pins-apply", report.OK, detail="a commit of an earlier run goes out first")
            return
        role = facts.role(self.instance, self.name)
        self.run.data.update(producer=role)
        if role != "this-machine":
            self._not_the_producer(role)
            return
        if self.profile is None:
            self.run.item(
                "profile-required",
                run="dotsteward host init --profile PROFILE",
                message="this machine has no profile: nothing can check new pins, so none move",
            )
            self.run.step("pins-apply", report.PENDING, detail="no profile")
            return
        if self.offline:
            self.run.step("pins-apply", report.PARTIAL, detail="offline")
            return
        if not self._open_work(self.tip):
            return
        prepared = self._ds_output("txn", "prepare", "--official-sources-only", "--scope", "update")
        if prepared.returncode != 0:
            self.run.step("txn-prepare", prepared.returncode)
            self._remove_work()
            return
        _say("looking for new versions")
        latest = self.upgrade_dir / "latest.json"
        latest.unlink(missing_ok=True)
        done = self._ds_output("pins", "latest", "--out", str(latest))
        # 1: some upstream gave no answer. Its rows say so, and the writer holds only their groups back.
        if done.returncode not in {0, 1} or not latest.is_file():
            self.run.step("pins-latest", done.returncode or report.FAILED)
            self._remove_work()
            return
        skips = holds.skip_patterns(self.state_root, latest)
        if not self._week_due():
            skips = [_FLAKE_INPUTS, *skips]
        answer = self._apply(latest, skips)
        if answer is None:
            self._remove_work()
            return
        moved = list(answer.get("moved") or ())
        flake_moved = bool(answer.get("flake_inputs_moved"))
        if answer.get("framework_moved"):
            # The new framework writes the rest, with its own manifest and its own engine.
            self.framework_moved = True
            answer = self._apply(latest, skips)
            if answer is None:
                self._remove_work()
                return
            moved += answer.get("moved") or ()
            flake_moved = flake_moved or bool(answer.get("flake_inputs_moved"))
        if flake_moved:
            self._start_week()
        if not self._work_git("status", "--porcelain").stdout.strip():
            self.framework_moved = False
            self._remove_work()
            return
        names = ", ".join(str(row.get("id")) for row in moved) or "derived values only"
        _say(f"pins moved: {names}; the gate decides")
        started = time.time()
        status = self._ds_quiet("gate", "--scope", "update")
        environment = self._gate_environment(started) if status != 0 else None
        if environment is not None:
            network = environment.startswith("the network")
            self.run.step("gate", report.PARTIAL if network else report.FAILED, detail=environment)
            self.run.item(
                "gate-failed",
                log=str(Path(self.state_root) / "update" / "validate.log"),
                moved=[row.get("id") for row in moved],
                environment=environment,
                run=self._command_again(),
                message=(
                    f"the gate could not judge the new pins: {environment}; nothing was committed and nothing "
                    "is held, the next run tries again"
                ),
            )
            self.framework_moved = False
            self._remove_work()
            return
        self.run.step("gate", status)
        if status != 0:
            reason = f"the gate said no ({status})"
            self._hold_moved(moved, [], reason)
            self.run.item(
                "gate-failed",
                log=str(Path(self.state_root) / "update" / "validate.log"),
                moved=[row.get("id") for row in moved],
                message="the gate refused the new pins: nothing was committed",
            )
            self.framework_moved = False
            self._remove_work()
            return
        self._work_git("add", "-A")
        subject = self.instance.config["commit"]["update_subject"]
        identity = commit_identity(self.root, self.tip)
        committed = self._work_git(*identity, "commit", "--quiet", "-m", subject)
        if committed.code != 0:
            self.run.step("commit", report.FAILED, detail=committed.stderr.strip())
            self.framework_moved = False
            self._remove_work()
            return
        self._keep_waiting()
        self.moved = moved
        # Known at once: the next run must find this commit, however this one ends.
        self.run.data.update(own_commits=[self.waiting], moved=self.moved)
        self.run.write()
        assert self.waiting is not None
        _say(f"committed {self.waiting[:12]} next to the checkout; it goes out after a green E2E")
        self.run.step("commit", report.OK, commit=self.waiting)

    def _gate_environment(self, started: float) -> str | None:
        """Why the gate could not judge the tree, or None when its no is about the tree: another gate,
        a step that never reached the tree, a full disk or no memory in its log, the network gone."""
        if _GATE_LOCKED in self.quiet_output:
            return _GATE_LOCKED
        log = Path(self.state_root) / "update" / "validate.log"
        try:
            # A log of an earlier gate says nothing about this one.
            text = log.read_text(encoding="utf-8", errors="replace") if log.stat().st_mtime >= started - 1 else ""
        except OSError:
            text = ""
        steps = re.findall(r"^== ([a-z0-9-]+):", text, re.MULTILINE)
        if steps and steps[-1] == "preflight":
            return "the preflight of the gate failed (the binary cache or the free space of the store)"
        for marker in _ENVIRONMENT_MARKERS:
            if marker in text or marker in self.quiet_output:
                return marker
        outcome, _, _ = publishing.fetch_tip(self.root, self.branch, _PUBLISH_SCOPE)
        if outcome == publishing.NETWORK:
            self.offline = True
            return "the network went away during the gate"
        return None

    def _self_updates(self) -> None:
        """What updates itself is only asked to; a second way in is never added."""
        for entry in facts.self_updates(self._active(), self.instance):
            step = f"self:{entry.component}"
            if self.offline:
                self.run.step(step, report.PARTIAL, detail="offline")
            elif shutil.which(entry.command[0]) is None:
                self.run.step(step, report.OK, detail=f"{entry.command[0]} is not installed")
            else:
                self.run.step(step, self._attached(list(entry.command)))

    def _plugins(self) -> None:
        found = plugins.scan(self.state_root, self.env)
        if found["updated"]:
            word = "plugin" if found["updated"] == 1 else "plugins"
            _say(f"{found['updated']} {word} updated itself; the scan is done")
        for key in found["findings"]:
            self.run.item(
                "plugin-scan-finding",
                pending=False,
                plugin=key,
                message=f"the scan found a secret in {key}: look at it, or remove the plugin; nothing was rolled back",
            )
        for key in found["failed"]:
            self.run.item("plugin-scan-failed", pending=False, plugin=key, message=f"the scan could not read {key}")
        self.run.data.update(plugins={"updated": found["updated"], "findings": len(found["findings"])})
        self.run.step("plugin-scan", report.OK)

    def _activation(self) -> dict[str, Any]:
        path = Path(self.state_root) / "current" / "activation.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return record if isinstance(record, dict) else {}

    def _saved_binaries(self) -> list[tuple[Path, Path]]:
        """The official binaries of the waiting move, each with the place of its saved copy."""
        moved = {str(row.get("id")) for row in self.moved}
        saved = []
        for component in self._active():
            install = component.get("install") or {}
            companions = install.get("companions") or ()
            pins = {install.get("pin"), *(companion.get("pin") for companion in companions)}
            if component.get("method") != "official-binary" or not install.get("dest") or not pins & moved:
                continue
            dest = Path(config.expand_path(install["dest"], self.env))
            directory = Path(self.state_root) / "rollback" / component["name"]
            files = [dest, *(dest.parent / companion["file"] for companion in companions if companion.get("file"))]
            saved += [(file, directory / file.name) for file in files]
        return saved

    def _save_binaries(self) -> None:
        for dest, copy in self._saved_binaries():
            # A copy that is there came from before the move, also after a run that was cut short.
            if dest.is_file() and not copy.exists():
                atomic.make_private_dirs(copy.parent.parent)
                atomic.make_private_dirs(copy.parent)
                shutil.copy2(dest, copy)

    def _restore_binaries(self, saved: Sequence[tuple[Path, Path]]) -> None:
        for dest, copy in saved:
            if copy.is_file():
                atomic.atomic_write(dest, copy.read_bytes(), mode=stat.S_IMODE(copy.stat().st_mode))
        self._forget_binaries()

    def _forget_binaries(self) -> None:
        shutil.rmtree(Path(self.state_root) / "rollback", ignore_errors=True)

    def _is_active(self, where: Path) -> bool:
        active = self._activation()
        return (
            active.get("tree_oid") == self._tree_of(where)
            and active.get("profile") == self.profile
            and os.path.realpath(str(active.get("root"))) == os.path.realpath(where)
        )

    def _rebuild(self) -> None:
        if self.profile is None:
            return
        where = self._target()
        if where == self.root and self.dirty:
            self.run.step("rebuild", report.OK, detail="the checkout is not clean")
            return
        if self._is_active(where):
            self.run.step("rebuild", report.OK, detail="skipped: this tree is active")
            return
        if self.offline and self.work is not None:
            self.run.step("rebuild", report.PARTIAL, detail="offline: the commit waits for the next run")
            return
        _say(f"rebuild of profile {self.profile}")
        if self.work is not None:
            self._save_binaries()
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        if self.work is not None and (status == _KILLED or status < 0):
            # Out of memory, or stopped from outside: it says nothing about the pins.
            self.run.step(
                "rebuild",
                report.FAILED,
                detail=f"killed (exit {status}), out of memory or from outside: the commit waits for the next run",
            )
            return
        if status != 0 and self.work is not None:
            outcome, _, _ = publishing.fetch_tip(self.root, self.branch, _PUBLISH_SCOPE)
            if outcome != publishing.OK:
                # Nix without a network says nothing about the pins.
                self.offline = True
                self.run.step("rebuild", report.PARTIAL, detail="offline: the commit waits for the next run")
                return
        self.run.step("rebuild", status)
        if status != 0 and self.work is not None:
            self._go_back(f"rebuild failed with status {status}", [])

    def _user_channels(self) -> None:
        if self.offline:
            self.run.step("user-channels", report.PARTIAL, detail="offline")
            return
        commands = facts.tracked_commands(facts.mirror(self.instance, self.env), self._active())
        tools = facts.tools(self.instance)
        for channel, status, problem in analysis.update_user_channels(tools, commands, False, self.env, self.root):
            if problem:
                _say(f"{channel}: {problem}")
                self.run.step(channel, status, detail=problem)
            else:
                self.run.step(channel, status)

    # --- phase 3 ---------------------------------------------------------------------------

    def _versions_of_tracked(self) -> dict[str, str]:
        tracked = facts.tracked_packages(self._active(), self.instance)
        if not tracked or shutil.which("dpkg-query") is None:
            return {}
        done = subprocess.run(
            ["dpkg-query", "-W", "-f=${Package} ${Version}\n", *tracked], capture_output=True, text=True, check=False
        )
        return dict(line.split(" ", 1) for line in done.stdout.splitlines() if " " in line)

    def _version_of(self, argv: Sequence[str]) -> str:
        if not argv:
            return ""
        try:
            done = subprocess.run(
                list(argv),
                capture_output=True,
                text=True,
                timeout=_VERSION_SECONDS,
                stdin=subprocess.DEVNULL,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        return done.stdout.strip()

    def _e2e_key(self, repo_checks: bool) -> str:
        """What the result depends on: the generation, the tree, the profile and what the tracked
        channels have installed. Nothing untracked is in it."""
        payload = {
            "generation": self._activation().get("generation"),
            "tree": self._tree_of(self._target()),
            "profile": self.profile,
            "repo_checks": repo_checks,
            "packages": self._versions_of_tracked(),
            "self": {
                entry.component: self._version_of(entry.version)
                for entry in facts.self_updates(self._active(), self.instance)
            },
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()

    def _e2e_green_for(self, key: str) -> bool:
        try:
            known = json.loads((self.upgrade_dir / "e2e-key.json").read_text(encoding="utf-8")).get("key")
            record = json.loads((Path(self.state_root) / "update" / "e2e.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, AttributeError):
            return False
        return bool(known == key and record.get("result") == "passed")

    def _repo_checks(self) -> bool:
        return not self.offline and (self.work is not None or not self.dirty)

    def _run_e2e(self) -> list[str] | None:
        """E2E as it stands: None when green, else the ids of what is red."""
        assert self.profile is not None
        repo_checks = self._repo_checks()
        arguments = ["e2e", "--profile", self.profile, "--keep-going", "--json"]
        if not repo_checks:
            arguments.append("--skip-repo-checks")
        elif self.waiting is not None:
            arguments += ["--expected-remote-base", self.tip]
        done = self._ds_output(*arguments)
        if done.returncode in _SIGNALLED:
            raise KeyboardInterrupt
        self.e2e_status = done.returncode
        if done.returncode == 0:
            atomic.make_private_dirs(self.upgrade_dir)
            key = self._e2e_key(repo_checks)
            atomic.atomic_write_json(self.upgrade_dir / "e2e-key.json", {"key": key}, mode=0o600)
            self._forget_binaries()
            self.verified = True
            return None
        self.verified = False
        try:
            findings = json.loads(done.stdout).get("findings") or []
        except (ValueError, AttributeError):
            findings = []
        if done.returncode == _KILLED or done.returncode < 0:
            return [_NO_RESULT]
        return sorted({str(finding.get("step")) for finding in findings}) or [_NO_RESULT]

    def _e2e(self, *, force: bool = False) -> None:
        if self.profile is None or self.red:
            return
        if self.work is not None and not self._is_active(self.work):
            # Without a network its rebuild waits; this generation says nothing about the commit.
            self.run.step("e2e", report.PARTIAL, detail="the commit that waits is not active yet")
            return
        if not force and not self.apt_changed and self._e2e_green_for(self._e2e_key(self._repo_checks())):
            self.verified = True
            self.run.step("e2e", report.OK, detail="skipped: nothing changed since the last green run")
            return
        _say(f"E2E of profile {self.profile}")
        red = self._run_e2e()
        if red is None:
            _say("E2E is green")
            self.run.step("e2e", report.OK)
        elif red == [_NO_RESULT]:
            self._no_result()
        elif self.waiting is not None:
            self._go_back(f"E2E red: {', '.join(red)}", red)
        else:
            self._still_red(red)

    def _no_result(self) -> None:
        """E2E ended without naming a check: killed, out of memory, or a crash of its own. Nothing went
        red, so nothing goes back and nothing is held; a waiting commit waits for the next run."""
        self.verified = False
        self.run.step("e2e", report.FAILED, detail=f"no result (exit {self.e2e_status})")
        self.run.item(
            "e2e-no-result",
            run=f"dotsteward e2e --profile {self.profile} --keep-going",
            message=(
                "E2E ended without a result: nothing went back and nothing is held"
                + ("; the commit waits for the next run" if self.waiting else "")
            ),
        )

    def _still_red(self, red: Sequence[str]) -> None:
        """Red, and nothing of this run to go back to: the package moved, or a setting did."""
        self.red = True
        self.run.step("e2e", report.FAILED, findings=list(red))
        names = {check.split(":", 1)[0] for check in red} - _NOT_COMPONENTS
        packages = [
            package
            for component in self._active()
            if component["name"] in names and component.get("method") == "deb"
            for package in sorted(set((component.get("install") or {}).get("packageNames") or ()))
        ]
        hint = "; ".join(f"to keep {package} where it is: sudo apt-mark hold {package}" for package in packages)
        self.run.item(
            "e2e-red",
            findings=list(red),
            run=f"dotsteward e2e --profile {self.profile} --keep-going",
            message="E2E is red on this machine",
            hint=hint or None,
        )

    def _go_back(self, reason: str, red: Sequence[str]) -> None:
        """A move of this run went red: the tree and the binaries from before. The commit goes with its
        clone; the checkout never had it. A hold comes only when the way back is green, since otherwise
        the move is not what broke the machine. The next run leaves held pins and moves the others."""
        saved = self._saved_binaries()
        moved = self.moved
        base = self._git("rev-parse", f"{self.waiting}^").stdout.strip()
        self._drop_waiting()
        self._remove_work()
        self.framework_moved = False
        if (self.dirty or self._head() != base) and not self._open_work(base):
            self._still_red(red or ["rebuild"])
            return
        assert self.profile is not None
        # The rebuild first: an installer keeps a binary newer than its pin, so the copy goes last.
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self._restore_binaries(saved)
        self.run.step("go-back", status, detail=reason)
        again = self._run_e2e() if status == 0 else ["rebuild"]
        self.red = True
        self.verified = False
        if again is None:
            self._hold_moved(moved, red, reason)
            self.run.step("e2e", report.PENDING, detail=f"went back: {reason}")
        else:
            self._still_red(again)
        self._remove_work()

    def _host_checks(self) -> None:
        if not self.linux:
            return
        answer = self.apt_answer
        if answer is None:
            # No window this run: the engine still says what a reboot would start. Only the kernel
            # matters here, the rest of that plan has not happened.
            try:
                answer = apt_plan.plan(self._request(self.mode))
            except apt_plan.AptEngineError:
                answer = {}
            for found in answer.get("items") or ():
                if str(found.get("code")).startswith("module-") and found.get("code") != "module-loss":
                    fields = {key: value for key, value in found.items() if key not in {"code", "pending"}}
                    self.run.item(found["code"], pending=bool(found.get("pending")), **fields)
        newest = answer.get("newest_kernel") or {}
        self.run.data.update(newest_kernel=newest or None)
        release = str(newest.get("release") or "")
        running = subprocess.run(["uname", "-r"], capture_output=True, text=True, check=False).stdout.strip()
        root = Path(self.env.get("DOTSTEWARD_SYSTEM_ROOT") or "/")
        flagged = (root / "run" / "reboot-required").exists()
        if flagged or (release and running and release != running):
            detail = f"{release} is installed, {running} runs" if release != running else "the system asks for it"
            message = f"a reboot is due when it suits you: {detail}. This command never reboots."
            self.run.item("reboot-required", pending=False, running=running, newest=release, message=message)
        self.run.step("host-checks", report.OK)

    # --- phase 4 ---------------------------------------------------------------------------

    def _validated(self) -> bool:
        """The gate has proven this tree; a waiting commit may be older than the last gate."""
        path = Path(self.state_root) / "update" / "validation.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            record = {}
        assert self.work is not None
        if (
            record.get("result") == "passed"
            and record.get("scope") == "update"
            and record.get("tree_oid") == self._tree_of(self.work)
        ):
            return True
        return self._ds_quiet("gate", "--scope", "update", "--force") == 0

    def _publish(self) -> None:
        if self.waiting is None:
            return
        if self.offline:
            self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
            return
        if self.work is None:
            return
        if not self.verified:
            self.run.step("publish", report.PENDING, detail="no green E2E of this tree")
            self.run.item(
                "publish-waits",
                run=self._command_again(),
                message="the commit goes out after a green E2E, which this run could not do",
            )
            return
        commit = self.waiting
        if not self._validated():
            self.run.step("publish", report.FAILED, detail="the gate does not accept this tree any more")
            self._drop_waiting()
            self._back_to_checkout()
            return
        status = self._ds_quiet("txn", "publish", "--scope", "update", "--expected-base", self.tip)
        if status == 0:
            self.run.step("publish", report.OK)
            self._drop_waiting()
            self._follow(commit)
            return
        outcome, tip, detail = publishing.fetch_tip(self.root, self.branch, _PUBLISH_SCOPE)
        if outcome == publishing.NETWORK:
            self.offline = True
            self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
            return
        if outcome == publishing.OK and tip != self.tip:
            self.run.step("publish", report.PENDING, detail="the remote moved")
            self.run.item(
                "publish-race",
                run=self._command_again(),
                message="another machine came first: the next run makes the commit again on its tip",
            )
        else:
            self.run.step("publish", status)
            self.run.item(
                "publish-refused",
                moved=[row.get("id") for row in self.moved],
                message=f"the remote or a hook refused the commit: {detail or 'see above'}; the next run tries again",
            )
        self._drop_waiting()
        self._back_to_checkout()

    def _follow(self, commit: str) -> None:
        """The commit is on the remote: the checkout fast-forwards when it is clean, and takes the
        records of the machine back from the clone. It is the only time a run moves it this late."""
        self._remove_work()
        head = self._head()
        if head != commit:
            clean = self._checkout_clean()
            if not clean or self._git("merge", "--quiet", "--ff-only", commit).code != 0:
                self.framework_moved = False
                self.run.item(
                    "checkout-behind",
                    pending=False,
                    run=f"git -C {self.root} pull --ff-only",
                    message="the checkout is not clean, so it stays behind what was published; the next run follows",
                )
                return
        if self.profile is not None and not self._is_active(self.root):
            self.dirty = False
            self.run.step("checkout-rebuild", self._ds("rebuild", "--profile", self.profile, "--switch"))

    def _back_to_checkout(self) -> None:
        """A commit that goes nowhere leaves the generation of the checkout active."""
        self._remove_work()
        self.framework_moved = False
        if self.profile is not None and not self.dirty and not self._is_active(self.root):
            self.run.step("checkout-rebuild", self._ds("rebuild", "--profile", self.profile, "--switch"))

    def _analysis(self) -> Mapping[str, Any]:
        commands = facts.tracked_commands(facts.mirror(self.instance, self.env), self._active())
        channels = analysis.read_user_channels(facts.tools(self.instance), commands, self.offline, self.env, self.root)
        channels["apt"] = {"available": False, "count": 0}
        if self.linux:
            try:
                channels["apt"] = apt_plan.analysis(self._request("tracked"))
            except apt_plan.AptEngineError as failure:
                channels["apt"] = {"available": True, "count": 0, "error": f"{failure.code}: {failure.message}"}
        path = analysis.store(self.state_root, channels)
        counts = analysis.counts(channels)
        self.run.item("analysis", pending=False, counts=counts, path=str(path))
        if channels["apt"].get("boot_low"):
            self.run.item(
                "boot-space-low",
                pending=False,
                free_mib=channels["apt"].get("boot_free_mib"),
                message="/boot is nearly full; nothing is removed by this command",
            )
        _say("outside what is tracked, nothing changed:")
        for line in analysis.lines(channels):
            _say(f"  {line}")
        self.run.step("analysis", report.OK)
        return channels

    def _after(self) -> None:
        if self.mode == "tracked":
            channels = self._analysis()
            # The offer may stay open for hours: what happened so far is on disk.
            self.run.write()
            if (
                self.terminal
                and not self.offline
                and not self.red
                and any(analysis.counts(channels).values())
                and _ask_yes("Update these too?")
            ):
                self.apt_changed = False
                self._window("all")
                self._user_channels()
                if self.apt_changed:
                    self._e2e(force=True)
        if self.approved:
            if self.red or not self.verified:
                self.run.item(
                    "firmware-available",
                    pending=False,
                    message="approved firmware waits for a green E2E on this machine",
                )
            else:
                _say("firmware: the approved devices, in a sudo window of their own")
                firmware.apply(self.approved, self.run)
                if self.run.interrupted:
                    raise KeyboardInterrupt
