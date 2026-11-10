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
import contextlib
import fnmatch
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import apt_plan, atomic, config, firmware, incoming, machine, procs, report, runner, versions
from dotsteward_cli import publish as publishing
from dotsteward_cli.host import commit_identity, commit_message
from dotsteward_cli.skills import commands as skills_commands
from dotsteward_cli.skills import state as skill_state
from dotsteward_cli.upgrade import analysis, facts, holds, plugins

WAITING_REF = "refs/dotsteward/upgrade/waiting"
_WORK = "work"
# What the waiting commit moved, next to it: {schema_version, commit, moved}.
_WAITING_FILE = "waiting.json"
# The most gates a red gate may cost to find what it is about.
_BISECT_GATES = 12
# What a user service in one of these states runs.
_RUNNING_STATES = {"active", "activating", "reloading", "deactivating"}
# Session units the way back never stops or restarts, even when a generation names them: a restart
# of one of them ends the desktop session of the owner.
_SESSION_UNITS = (
    "dbus*",
    "dbus-broker*",
    "exampledesk-*",
    "org.exampledesk.*",
    "*session*",
    "pipewire*",
    "wireplumber*",
    "pulseaudio*",
    "xdg-*",
    "gvfs*",
    "at-spi*",
    "plasma*",
    "kde*",
    "org.kde.*",
    "systemd-*",
    "snap.*",
    "app-*",
    "gpg-agent*",
    "ssh-agent*",
    "graphical-*",
    "xorg*",
    "wayland*",
    "mutter*",
    "evolution-*",
    "tracker-*",
)
_PUBLISH_SCOPE = "upgrade"
_WEEK_SECONDS = 7 * 24 * 60 * 60
_DAY_SECONDS = 24 * 60 * 60
_STALE_PRODUCER_SECONDS = 14 * 24 * 60 * 60
_FLAKE_INPUTS = "flake_inputs.*"
_BRIDGE = "/usr/local/lib/dotsteward/apt-bridge.sh"
_BRIDGE_CONF = "/etc/dotsteward/apt-bridge.d"
_BRIDGE_REPO = "/var/lib/dotsteward/apt-bridge"
_APT_LOCK_SECONDS = 300
_VERSION_SECONDS = 20
_INTERRUPTED = 130
# txn publish: the remote moved since the base, and no network.
_TXN_RACE = 3
_TXN_OFFLINE = 6
_SKILL_ITEMS = {
    "ask": ("origin-unknown", "where this skill comes from is not known: say what becomes of it"),
    "conflict": ("skill-conflict", "this skill changed here and on the remote"),
    "blocked": ("capture-blocked", "this skill was not published"),
}
_NOT_COMPONENTS = {"core", "setup"}
_SIGNALLED = runner.SIGNALLED
_APT_BUCKETS = ("install", "upgrade", "remove", "downgrade")
_STEP_WORDS = {"pending": "waits for you", "partial": "skipped, no network", "failed": "failed"}
_KILLED = runner.KILLED
_NO_RESULT = "unknown"
RETRY_HELD = "dotsteward upgrade --retry-held"
_WRITER_ITEMS = {
    "skill-transform": "have a newer upstream and a local transform; dotsteward-update moves them",
}


def _say(text: str) -> None:
    print(f"[upgrade] {text}", flush=True)


def _installed_version(package: str) -> str | None:
    """The version dpkg has installed of PACKAGE, None when it has none."""
    try:
        done = subprocess.run(
            ["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${Version}", package],
            capture_output=True,
            text=True,
            timeout=_VERSION_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    status, _, version = done.stdout.partition("\t")
    if done.returncode != 0 or not status.startswith("ii"):
        return None
    return version.strip() or None


def _session_unit(name: str) -> bool:
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in _SESSION_UNITS)


def _ask_yes(question: str) -> bool:
    print(f"{question} [y/N] ", end="", flush=True)
    return sys.stdin.readline().strip().lower() in {"y", "yes", "e", "evet"}


def _system_file_differs(path: str, text: str, mode: str, root: str) -> bool:
    """A system file is missing, or its bytes, its mode or its owner (the owner of the system
    root, root:root of /) are not the component's."""
    try:
        with open(path, "rb") as handle:
            same = handle.read() == text.encode("utf-8")
        actual = os.stat(path)
        owner = os.stat(root or "/")
    except OSError:
        return True
    return (
        not same
        or stat.S_IMODE(actual.st_mode) != int(mode, 8)
        or (actual.st_uid, actual.st_gid) != (owner.st_uid, owner.st_gid)
    )


class Upgrade(runner.Runner):
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
        super().__init__(instance, state_root, _PUBLISH_SCOPE)
        self.mode = mode
        self.accept = tuple(accept)
        self.terminal = terminal
        self.arguments = list(arguments)
        self.again = again
        self.run = report.RunReport("upgrade", state_root)
        self.upgrade_dir = Path(state_root) / "upgrade"
        self.linux = config.runtime_platform(self.env) == "linux"
        self.name: str | None = None
        self.dirty = False
        self.tip = ""
        self.apt_changed = False
        self.apt_answer: dict[str, Any] | None = None
        self.red = False
        self.verified = False
        # The tree that green E2E checked: what is published must be that tree and no other.
        self.verified_tree: str | None = None
        self.interrupted = False
        self.work: Path | None = None
        self.waiting: str | None = None
        self.moved: list[dict[str, Any]] = []
        self.latest: Path | None = None
        self.skips: Sequence[str] = ()
        self.approved: tuple[firmware.Device, ...] = ()
        self.paths: report.ReportPaths | None = None
        self.e2e_status = 0
        self.moved = self._waiting_moves()
        self.run.data.update(mode=mode)

    # --- helpers ---------------------------------------------------------------------------

    def _target(self) -> Path:
        """Where the tree of this run is: the clone while it has a commit, else the checkout."""
        return self.work or self.root

    def _work_git(self, *arguments: str, stdin: str | None = None) -> publishing.GitResult:
        assert self.work is not None
        return publishing.git(self.work, *arguments, stdin=stdin)

    def _verify(self, green: bool) -> None:
        """E2E is green for the tree of this run, or nothing is."""
        self.verified = green
        self.verified_tree = self._tree_of(self._target()) if green else None

    def _verified_work(self) -> bool:
        """The waiting commit of the clone is the tree that E2E checked."""
        return self.verified and self.work is not None and self.verified_tree == self._tree_of(self.work)

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
        waiting = self.waiting or self._waiting_ref()
        self.run.data.update(own_commits=[waiting] if waiting else [], moved=self.moved if waiting else [])
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
        self._copy_config()
        checked = self._work_git("checkout", "--quiet", "-B", self.branch, commit)
        if checked.code != 0:
            self.run.step("clone", report.FAILED, detail=checked.stderr.strip())
            self._remove_work()
            return False
        return True

    def _copy_config(self) -> None:
        """The local settings and the hooks of the checkout, in the clone."""
        assert self.work is not None
        self._clone_config(self.work)

    def _remove_work(self) -> None:
        shutil.rmtree(self.upgrade_dir / _WORK, ignore_errors=True)
        self.work = None

    def _leave_work(self) -> None:
        """The clone goes. Nothing the agents read names it: the hooks of skill tracking take their
        context from `skills hooks install`, which a rebuild does not run."""
        self._remove_work()
        self.framework_moved = False

    def _waiting_ref(self) -> str | None:
        return self._git("rev-parse", "--verify", "--quiet", WAITING_REF).stdout.strip() or None

    def _waiting_moves(self) -> list[dict[str, Any]]:
        """What the waiting commit moved: its own file, else the last report (a commit of 1.4.0)."""
        commit = self._waiting_ref()
        if commit is None:
            return []
        try:
            document = json.loads((self.upgrade_dir / _WAITING_FILE).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            document = None
        if isinstance(document, dict) and document.get("commit") == commit and isinstance(document.get("moved"), list):
            return list(document["moved"])
        last = report.load_last(self.state_root, "upgrade") or {}
        data = last.get("data") if isinstance(last.get("data"), dict) else {}
        moved = data.get("moved") if isinstance(data, dict) else None
        return list(moved) if isinstance(moved, list) else []

    def _keep_waiting(self, moved: Sequence[dict[str, Any]]) -> None:
        """The commit of the clone, in the objects of the checkout under a ref of its own, and what it
        moved next to it: a run that is refused before it looks must not lose that."""
        assert self.work is not None
        self._git("fetch", "--quiet", "--no-tags", "--refmap=", str(self.work), f"+HEAD:{WAITING_REF}")
        self.waiting = self._work_git("rev-parse", "HEAD").stdout.strip()
        self.moved = list(moved)
        atomic.make_private_dirs(self.upgrade_dir)
        document = {"schema_version": 1, "commit": self.waiting, "moved": self.moved}
        atomic.atomic_write_json(self.upgrade_dir / _WAITING_FILE, document, mode=0o600)

    def _drop_waiting(self, *, forget_binaries: bool = True) -> None:
        """The waiting commit goes, and what it moved; the saved binaries of its move too, unless the
        way back still puts them in place."""
        self._git("update-ref", "-d", WAITING_REF)
        (self.upgrade_dir / _WAITING_FILE).unlink(missing_ok=True)
        self.waiting = None
        self.moved = []
        if forget_binaries:
            self._forget_binaries()

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
        self._track(tip)
        self.run.step("fetch", report.OK)
        head = self._head()
        ahead = self._git("rev-list", f"{tip}..{head}").stdout.split()
        behind = self._git("rev-list", f"{head}..{tip}").stdout.split()
        if ahead:
            return self._refuse(
                f"this checkout has local commits that are not published: {ahead[0][:12]}; publish them first"
            )
        if waiting == tip:
            # The push of an earlier run landed, and its answer did not.
            self._drop_waiting()
            _say("the waiting commit is already published: the checkout follows it")
        elif waiting and self._git("rev-parse", f"{waiting}^").stdout.strip() == tip:
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
        """The question about changes from other machines (Y3), before sudo and the long builds. The
        checkout is at the tip by now; without a terminal every item is an entry of this run, which
        goes on and ends in 3. An answer Never publishes the host file, so the tip moves with it."""
        if self.name is None:
            return
        head = self._head()
        try:
            left = incoming.ask(self.instance, self.run, terminal=self.terminal, env=self.env)
        except (incoming.Refusal, config.DotstewardError, OSError) as failure:
            self.run.step("incoming", report.FAILED, detail=str(failure))
            return
        self.run.step("incoming", report.OK, waiting=len(left))
        self.instance = config.load_instance()
        self._effective()
        if self.tip and self._head() != head:
            self.tip = self._head()

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
        if not self._system_files():
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

    def _system_files(self) -> bool:
        """The files of the active system components that are missing or differ, on every
        profile, as `dotsteward install` writes them: next to the target under a temporary name,
        synced, then renamed over it, so apt never reads half a file. The component is their one
        writer. False: the window ended early."""
        root = self.env.get("DOTSTEWARD_SYSTEM_ROOT") or ""
        active = self._active()
        for component in active:
            if component.get("method") != "system":
                continue
            step = f"system:{component.get('name')}"
            files = (component.get("install") or {}).get("files") or []
            wanted = [
                entry
                for entry in files
                if _system_file_differs(root + entry["path"], entry["text"], entry["mode"], root)
            ]
            if not wanted:
                self.run.step(step, report.OK)
                continue
            with tempfile.TemporaryDirectory(prefix="dotsteward-system-") as directory:
                for index, entry in enumerate(wanted):
                    staged = Path(directory) / str(index)
                    staged.write_text(entry["text"], encoding="utf-8")
                    staged.chmod(0o644)
                    target = root + entry["path"]
                    head, _, tail = target.rpartition("/")
                    temporary = f"{head}/.dotsteward-{tail}.tmp"
                    for command in (
                        ("install", "-D", "-o", "root", "-g", "root", "-m", entry["mode"], str(staged), temporary),
                        ("sync", "--", temporary),
                        ("mv", "-f", "--", temporary, target),
                    ):
                        if not self._privileged(step, *command):
                            return False
                        if self.run.steps[-1]["status"] != report.status_name(report.OK):
                            self._privileged(step + ":cleanup", "rm", "-f", "--", temporary)
                            break
        if facts.gated(self.instance, self.name) and not any(c.get("name") == "apt-policy" for c in active):
            _say("apt-policy is not active here: unattended-upgrades may remove kernels by itself")
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

    def _start_week(self, *, paused: float = _WEEK_SECONDS) -> None:
        """The flake inputs wait PAUSED seconds from now (a week after a published move)."""
        atomic.make_private_dirs(self.upgrade_dir)
        moved_at = time.time() - _WEEK_SECONDS + paused
        atomic.atomic_write_json(self.upgrade_dir / "nix-week.json", {"moved_at": moved_at}, mode=0o600)

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

    def _apply(self, latest: Path, skips: Sequence[str], *, record: bool = True) -> dict[str, Any] | None:
        """One run of the writer in the clone. None: nothing can come of it. A group that failed is put
        back by the writer, so what the others moved still goes on. RECORD false: a run of the
        bisection of a red gate, which the report does not count as the move."""
        arguments = ["pins", "apply", "--latest", str(latest), "--json"]
        for pattern in skips:
            arguments += ["--skip", pattern]
        done = self._ds_output(*arguments)
        if done.returncode in _SIGNALLED:
            raise KeyboardInterrupt
        try:
            answer: dict[str, Any] = json.loads(done.stdout)
        except ValueError:
            if record:
                self.run.step("pins-apply", done.returncode or report.FAILED, detail="the writer gave no answer")
            return None
        if not record:
            return answer
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
        newer. The pins of each component the red checks name, by the pin of its binary or by its name
        in the pin id, all of them when they name none."""
        components = {check.split(":", 1)[0] for check in red} - _NOT_COMPONENTS
        owners = facts.pin_owners(self._active())

        def owner(row: Mapping[str, Any]) -> str | None:
            identifier = str(row.get("id"))
            if owners.get(identifier) in components:
                return owners[identifier]
            return next((part for part in identifier.split(".") if part in components), None)

        guilty = [row for row in rows if owner(row) is not None]
        for row in guilty or rows:
            identifier = str(row.get("id"))
            component = owner(row) or owners.get(identifier) or next(iter(sorted(components)), identifier)
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
        if not self._open_work(self.tip) or not self._prepare():
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
        skips = [*skips, *self._waiting_floors(latest)]
        # Kept for a lost race: the writer runs again on the new tip with the same rows.
        self.latest, self.skips = latest, skips
        self._write(latest, skips)

    def _waiting_floors(self, latest: Path) -> list[str]:
        """The floor pins of the deb packages that would move above what dpkg has: a floor moves only
        to a version every package of its component has installed, whatever a sudo window did (dpkg's
        lock busy, the bridge paused, the vendor repository behind), since a floor above the installed
        version turns the E2E of the package red and sends the run back."""
        if not self.linux:
            return []
        try:
            document = json.loads(latest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            document = {}
        rows = {
            str(row.get("id")): str(row.get("latest"))
            for row in (document.get("items") or () if isinstance(document, dict) else ())
            if isinstance(row, dict) and row.get("status") == "update" and row.get("latest")
        }
        waiting: list[dict[str, Any]] = []
        for component in self._active():
            install = component.get("install") or {}
            pin = install.get("pin")
            if component.get("method") != "deb" or not isinstance(pin, str) or pin not in rows:
                continue
            installed = {str(name): _installed_version(str(name)) for name in install.get("packageNames") or ()}
            wanted = rows[pin]
            if installed and all(version and versions.at_least(version, wanted) for version in installed.values()):
                continue
            waiting.append({"id": pin, "wanted": wanted, "installed": installed})
        if waiting:
            said = "; ".join(
                f"{floor['id']} {floor['wanted']} ("
                + ", ".join(f"{name} {version or 'not installed'}" for name, version in floor["installed"].items())
                + ")"
                for floor in waiting
            )
            self.run.item(
                "deb-floors-wait",
                pending=False,
                floors=waiting,
                ids=[floor["id"] for floor in waiting],
                run=self._command_again(),
                message=f"floors wait until dpkg has their version: {said}; a run on a terminal installs it",
            )
        return [floor["id"] for floor in waiting]

    def _prepare(self) -> bool:
        prepared = self._ds_output("txn", "prepare", "--official-sources-only", "--scope", "update")
        if prepared.returncode != 0:
            self.run.step("txn-prepare", prepared.returncode)
            self._remove_work()
            return False
        return True

    def _write(self, latest: Path, skips: Sequence[str]) -> None:
        """The writer in the clone, the gate and the local commit."""
        answer = self._apply(latest, skips)
        if answer is None:
            self._remove_work()
            return
        moved = list(answer.get("moved") or ())
        if answer.get("framework_moved"):
            # The new framework writes the rest, with its own manifest and its own engine.
            self.framework_moved = True
            answer = self._apply(latest, skips)
            if answer is None:
                self._remove_work()
                return
            moved += answer.get("moved") or ()
        if not self._work_git("status", "--porcelain").stdout.strip():
            self.framework_moved = False
            self._remove_work()
            return
        names = ", ".join(str(row.get("id")) for row in moved) or "derived values only"
        _say(f"pins moved: {names}; the gate decides")
        started = time.time()
        status = self._ds_quiet("gate", "--scope", "update")
        environment = self._gate_environment(started) if status != 0 else None
        if status == 0:
            self.run.step("gate", status)
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
        if status != 0:
            moved = self._red_gate(latest, skips, moved, status)
            if not moved:
                self.framework_moved = False
                self._remove_work()
                return
        self._work_git("add", "-A")
        subject = self.instance.config["commit"]["update_subject"]
        identity = commit_identity(self.root, self.tip)
        # The trace line says which machine made the commit.
        committed = self._work_git(*identity, "commit", "--quiet", "-F", "-", stdin=commit_message(subject, self.name))
        if committed.code != 0:
            self.run.step("commit", report.FAILED, detail=committed.stderr.strip())
            self.framework_moved = False
            self._remove_work()
            return
        self._keep_waiting(moved)
        # Known at once: the next run must find this commit, however this one ends.
        self.run.data.update(own_commits=[self.waiting], moved=self.moved)
        self.run.write()
        assert self.waiting is not None
        _say(f"committed {self.waiting[:12]} next to the checkout; it goes out after a green E2E")
        self.run.step("commit", report.OK, commit=self.waiting)

    def _gate_with(
        self, latest: Path, skips: Sequence[str], moved: Sequence[Mapping[str, Any]], rows: Sequence[Mapping[str, Any]]
    ) -> int | None:
        """The gate of the tip with only ROWS of MOVED moved: its status, None when the writer did not
        move exactly those or the gate could not judge the tree. Each try is a new clone of the tip
        (the writer starts from what the first one started from) and a gate against the tip, so a
        publish of another machine meanwhile changes nothing: the publish runs again on its tip."""
        if not self._open_work(self.tip):
            return None
        wanted = {str(row.get("id")) for row in rows}
        others = [str(row.get("id")) for row in moved if str(row.get("id")) not in wanted]
        if wanted:
            answer = self._apply(latest, [*skips, *others], record=False)
            if answer is None or {str(row.get("id")) for row in answer.get("moved") or ()} != wanted:
                return None
        started = time.time()
        status = self._ds_quiet("gate", "--scope", "update", "--expected-base", self.tip)
        if status != 0 and self._gate_environment(started) is not None:
            return None
        return status

    def _red_gate(
        self, latest: Path, skips: Sequence[str], moved: list[dict[str, Any]], status: int
    ) -> list[dict[str, Any]]:
        """The gate refused the moved pins. Held is only what the red can be put on, never an innocent
        group. First the gate of the tip itself: red, the base is red and nothing is held. Then the
        groups of the writer the red needs (delta debugging on complements): the gate of all moves but
        a part; a part without which it is green narrows the search, in halves and then finer. One
        group left: it is held, and the others, which the gate just passed, go on in this run (the
        return value). Several left: the whole set is gated once more; green, everything goes on (the
        red was not there again); red, the others go on and the several wait, or, when every group is
        among them, every moved pin is held: the red cannot be attributed. A gate that cannot judge
        its tree ends the search with nothing held."""
        reason = f"the gate said no ({status})"
        log = str(Path(self.state_root) / "update" / "validate.log")
        groups = list(dict.fromkeys(str(row.get("group")) for row in moved))
        tried: dict[frozenset[str], int | None] = {}
        budget = [_BISECT_GATES]
        # What the clone holds now: the moves without these groups, after their gate.
        last: list[frozenset[str] | None] = [None]

        def rows_without(names: Sequence[str]) -> list[dict[str, Any]]:
            return [row for row in moved if str(row.get("group")) not in names]

        def gate_without(names: Sequence[str], *, again: bool = False) -> int | None:
            key = frozenset(names)
            if key in tried and not again:
                return tried[key]
            if budget[0] <= 0:
                return None
            budget[0] -= 1
            tried[key] = self._gate_with(latest, skips, moved, rows_without(names))
            last[0] = key
            return tried[key]

        def clone_without(names: Sequence[str]) -> bool:
            """The clone holds the moves without NAMES, which the gate passed."""
            return last[0] == frozenset(names) or gate_without(names, again=True) == 0

        def item(
            held: Sequence[Mapping[str, Any]],
            attribution: str | None,
            message: str,
            *,
            pending: bool = True,
            **fields: Any,
        ) -> None:
            self.run.item(
                "gate-failed",
                pending=pending,
                log=log,
                moved=[row.get("id") for row in moved],
                held=[row.get("id") for row in held],
                attribution=attribution,
                message=message,
                **fields,
            )

        def hold(rows: Sequence[dict[str, Any]], why: str) -> None:
            self._hold_moved(rows, [], why)
            # A publish that runs again leaves them too.
            self.skips = [*self.skips, *(str(row.get("id")) for row in rows)]

        def could_not_judge() -> list[dict[str, Any]]:
            self.run.step("gate", report.PARTIAL if self.offline else status, detail="could not judge a part")
            item(
                [],
                None,
                "the gate refused the new pins and could not judge a part of them: nothing was "
                "committed and nothing is held, the next run tries again",
                run=self._command_again(),
            )
            return []

        if self.framework_moved:
            self.run.step("gate", status)
            hold(moved, f"{reason}; not tried: the framework moved")
            item(
                moved,
                None,
                "the gate refused the new pins and the framework moved, so no group was tried "
                "alone: every moved pin is held, nothing was committed",
            )
            return []
        _say(f"the gate said no: looking for what it is about, among {len(groups)} group(s)")
        base = gate_without(groups)
        if base is None:
            return could_not_judge()
        if base != 0:
            self.run.step("gate", status, detail="the base is red")
            item(
                [],
                None,
                "the gate refuses the tip itself, without any new pin: the base is red, so nothing "
                "is held and nothing was committed; see the log",
                base_red=True,
                run=self._command_again(),
            )
            return []
        suspects = groups
        parts = 2
        while len(suspects) > 1:
            size = -(-len(suspects) // parts)
            chunks = [suspects[index : index + size] for index in range(0, len(suspects), size)]
            found = None
            for chunk in chunks:
                result = gate_without(chunk)
                if result is None:
                    return could_not_judge()
                if result == 0:
                    found = chunk
                    break
            if found is not None:
                suspects, parts = found, 2
            elif parts >= len(suspects):
                break
            else:
                parts = min(len(suspects), parts * 2)
        rest = rows_without(suspects)
        if len(suspects) == 1:
            culprit = suspects[0]
            guilty = [row for row in moved if str(row.get("group")) == culprit]
            hold(guilty, f"{reason}, about group {culprit}")
            if not rest:
                self.run.step("gate", status, detail=f"refused group {culprit}")
                item(guilty, culprit, f"the gate refused group {culprit}: its pins are held; nothing else moved")
                return []
            # The clone must hold what the gate passed: the tree of the moves without the group.
            if not clone_without([culprit]):
                return could_not_judge()
            self.run.step("gate", report.OK, detail=f"without group {culprit}, which it refused")
            item(
                guilty,
                culprit,
                f"the gate refused group {culprit}: its pins are held; the other pins passed the gate and go on",
                pending=False,
            )
            return rest
        whole = gate_without([], again=True)
        if whole is None:
            return could_not_judge()
        if whole == 0:
            self.run.step("gate", report.OK, detail="green when gated again")
            item(
                [],
                None,
                "the gate refused the new pins once and passed them when gated again: everything goes on",
                pending=False,
            )
            return list(moved)
        if len(suspects) < len(groups):
            if not clone_without(suspects):
                return could_not_judge()
            self.run.step("gate", report.OK, detail=f"without groups {', '.join(suspects)}")
            item(
                [],
                None,
                f"the gate refused groups {', '.join(suspects)} together and none of them alone: "
                "none is held, the other pins go on, the next run tries them again",
                pending=False,
            )
            return rest
        self.run.step("gate", status)
        hold(moved, reason)
        item(
            moved,
            None,
            "the gate refused the new pins and the red could not be attributed to one group of "
            "them: every moved pin is held, nothing was committed",
        )
        return []

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

    def _generation_units(self) -> dict[str, bytes]:
        """The user service units of the active generation, by name, with the bytes of each: what
        Home Manager manages (home-files/.config/systemd/user), nothing else."""
        generation = self._activation().get("generation")
        if not isinstance(generation, str) or not generation:
            return {}
        directory = Path(generation) / "home-files" / ".config" / "systemd" / "user"
        units: dict[str, bytes] = {}
        try:
            entries = sorted(directory.iterdir())
        except OSError:
            return {}
        for entry in entries:
            if entry.name.endswith(".service"):
                with contextlib.suppress(OSError):
                    units[entry.name] = entry.read_bytes()
        return units

    def _unit_states(self, names: Sequence[str]) -> dict[str, str] | None:
        """The invocation of each of NAMES that is active; None when the user manager does not
        answer (no systemd, no session)."""
        if not names:
            return {}
        if not self.linux or shutil.which("systemctl") is None:
            return None
        shown = self._systemctl("show", "--property=Id,ActiveState,InvocationID", "--", *names)
        if shown is None:
            return None
        found: dict[str, str] = {}
        for block in shown.split("\n\n"):
            fields = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
            if fields.get("Id") and fields.get("ActiveState") in _RUNNING_STATES:
                found[fields["Id"]] = fields.get("InvocationID", "")
        return found

    def _systemctl(self, operation: str, *arguments: str) -> str | None:
        try:
            done = subprocess.run(
                ["systemctl", "--user", operation, "--no-pager", *arguments],
                capture_output=True,
                text=True,
                timeout=_VERSION_SECONDS,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout if done.returncode == 0 else None

    def _take_back_services(self, moved: Mapping[str, bytes], running: Mapping[str, str] | None) -> None:
        """What the moved generation brought goes with it, and nothing else. MOVED: the units of the
        moved generation; RUNNING: the invocations of its active units before the rebuild back. A
        unit only the moved generation has is stopped while it runs; a unit whose file it changed is
        restarted while it runs, unless the rebuild back restarted it already. A unit no generation
        has is the owner's and never touched, nor is a session unit (_SESSION_UNITS), whatever a
        generation says."""
        if running is None:
            return
        back = self._generation_units()
        added = sorted(name for name in moved if name not in back and not _session_unit(name))
        changed = sorted(
            name for name in moved if name in back and back[name] != moved[name] and not _session_unit(name)
        )
        states = self._unit_states([*added, *changed])
        if states is None:
            return
        stop = [name for name in added if name in states]
        restart = [name for name in changed if name in running and states.get(name) == running[name]]
        if stop:
            _say(f"stopping what the moved generation added: {', '.join(stop)}")
            self._systemctl("stop", "--", *stop)
        if restart:
            _say(f"restarting what the moved generation changed: {', '.join(restart)}")
            self._systemctl("restart", "--", *restart)
        if stop or restart:
            self.run.step("go-back-services", report.OK, stopped=stop, restarted=restart)

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
            self._verify(False)
            self.run.step("rebuild", report.PARTIAL, detail="offline: the commit waits for the next run")
            return
        _say(f"rebuild of profile {self.profile}")
        if self.work is not None:
            self._save_binaries()
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        if self.work is not None and (status == _KILLED or status < 0):
            # Out of memory, or stopped from outside: it says nothing about the pins, and this tree is
            # not built.
            self._verify(False)
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
                self._verify(False)
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

    def _answers_digest(self) -> str:
        """What the answers about other machines left here: the same tree can hold another machine."""
        digest = hashlib.sha256()
        for name in ("skills/base.json", incoming.KNOWN_FILE, incoming.NEVER_FILE):
            with contextlib.suppress(OSError):
                digest.update((Path(self.state_root) / name).read_bytes())
        return digest.hexdigest()

    def _e2e_key(self, repo_checks: bool) -> str:
        """What the result depends on: the generation, the tree, the profile and what the tracked
        channels have installed. Nothing untracked is in it."""
        payload = {
            "generation": self._activation().get("generation"),
            "tree": self._tree_of(self._target()),
            "profile": self.profile,
            "repo_checks": repo_checks,
            "packages": self._versions_of_tracked(),
            "answers": self._answers_digest(),
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
            self._verify(True)
            return None
        self._verify(False)
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
            self._verify(False)
            self.run.step("e2e", report.PARTIAL, detail="the commit that waits is not active yet")
            return
        if self.work is None and self.dirty and self._behind():
            # The generation is of what was published, the lock of the checkout is older: its E2E would
            # say red about a lock nobody runs.
            self._verify(False)
            self.run.step("e2e", report.PENDING, detail="the checkout has changes and is behind what is published")
            self.run.item(
                "checkout-behind",
                run=self._stash_and_follow(),
                message=(
                    "the checkout has uncommitted changes and is behind what was published: E2E waits until "
                    "it follows, since it would check a lock the active generation does not have"
                ),
            )
            return
        if not force and not self.apt_changed and self._e2e_green_for(self._e2e_key(self._repo_checks())):
            self._verify(True)
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
        self._verify(False)
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
        self._drop_waiting(forget_binaries=False)
        self._remove_work()
        self.framework_moved = False
        if (self.dirty or self._head() != base) and not self._open_work(base):
            self._still_red(red or ["rebuild"])
            return
        assert self.profile is not None
        # The rebuild first: an installer keeps a binary newer than its pin, so the copy goes last.
        # The units of the active generation, the moved one when its rebuild activated it, and how
        # they run, before the rebuild back activates the other one.
        units = self._generation_units()
        running = self._unit_states(sorted(name for name in units if not _session_unit(name)))
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self._restore_binaries(saved)
        if status == 0:
            self._take_back_services(units, running)
        self.run.step("go-back", status, detail=reason)
        again = self._run_e2e() if status == 0 else ["rebuild"]
        self.red = True
        self._verify(False)
        if again is None:
            self._hold_moved(moved, red, reason)
            self.run.step("e2e", report.PENDING, detail=f"went back: {reason}")
        else:
            self._still_red(again)
            if any(str(row.get("id")).startswith(_FLAKE_INPUTS[:-1]) for row in moved):
                # Nothing is held, so the next run would move them again, with a heavy rebuild and
                # a rebuild back: they wait a day.
                self._start_week(paused=_DAY_SECONDS)
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
        if not self._verified_work():
            self.run.step("publish", report.PENDING, detail="no green E2E of this tree")
            self.run.item(
                "publish-waits",
                run=self._command_again(),
                message="the commit goes out after a green E2E, which this run could not do",
            )
            return
        if not self._validated():
            self.run.step("publish", report.FAILED, detail="the gate does not accept this tree any more")
            self._drop_waiting()
            self._back_to_checkout()
            return
        for attempt in range(1, publishing.ATTEMPTS + 1):
            if not self._verified_work():
                # The tree of a replay that was not built, or not checked by E2E, goes nowhere.
                self.run.step("publish", report.PENDING, detail="no green E2E of this tree")
                self.run.item(
                    "publish-waits",
                    run=self._command_again(),
                    message="the commit on the new tip goes out after its rebuild and a green E2E, which this run "
                    "could not do",
                )
                return
            status = self._ds_quiet("txn", "publish", "--scope", "update", "--expected-base", self.tip)
            if status == 0:
                self.run.step("publish", report.OK)
                if any(str(row.get("id")).startswith(_FLAKE_INPUTS[:-1]) for row in self.moved):
                    # The week starts with what went out: a red gate or E2E moved nothing.
                    self._start_week()
                # `txn publish` named the machine in it: what the remote has is what the clone has now.
                self._keep_waiting(self.moved)
                commit = str(self.waiting)
                self._drop_waiting()
                self._follow(commit)
                return
            if status == _TXN_OFFLINE:
                self.offline = True
                self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
                return
            if status != _TXN_RACE:
                self.run.step("publish", status)
                self.run.item(
                    "publish-refused",
                    moved=[row.get("id") for row in self.moved],
                    message="the remote or a hook refused the commit (see above); the next run tries again",
                )
                break
            if attempt == publishing.ATTEMPTS or self.latest is None:
                # A commit of an earlier run has no rows of this one to write again from.
                kept = "other machines kept publishing" if self.latest is not None else "the remote moved"
                self.run.step("publish", report.PENDING, detail=kept)
                self.run.item(
                    "publish-race",
                    run=self._command_again(),
                    message=f"{kept} while this machine proved the new pins: the next run makes the commit again",
                )
                break
            _say("another machine published first: the writer runs again on its tip")
            publishing.backoff(attempt)
            if not self._write_again():
                return
        self._drop_waiting()
        self._back_to_checkout()

    def _write_again(self) -> bool:
        """The lost race of the producer: no text is merged; the writer runs again on the new tip with
        the rows this run researched, then the gate, the rebuild and E2E, as the first time. False:
        nothing to publish (recorded)."""
        # What E2E checked is the tree of the lost push; the new one starts unproven.
        self._verify(False)
        outcome, tip, detail = publishing.fetch_tip(self.root, self.branch, _PUBLISH_SCOPE)
        if outcome == publishing.REFUSED:
            self.run.step("publish", report.FAILED, detail="the remote refused the fetch of the new tip")
            self.run.item(
                "publish-refused",
                moved=[row.get("id") for row in self.moved],
                message=f"the remote refused the fetch of the new tip: {detail}; the next run tries again",
            )
            self._drop_waiting()
            self._back_to_checkout()
            return False
        if outcome != publishing.OK:
            self.offline = True
            self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
            return False
        self.tip = tip
        self._track(tip)
        # The saved binaries stay: they are what the machine had before this run.
        self._drop_waiting(forget_binaries=False)
        self.run.step("replay", report.OK, detail=f"the writer again on {tip[:12]}")
        assert self.latest is not None  # see _publish
        # The new clone starts with the CLI of this run, as the first one did.
        self.framework_moved = False
        if self._open_work(tip) and self._prepare():
            self._write(self.latest, self.skips)
        if self.waiting is None:
            # Nothing is left to move on the new tip.
            self._back_to_checkout()
            return False
        self._rebuild()
        self._e2e()
        # Not built or not green: the loop says so and publishes nothing.
        return self.waiting is not None and not self.red

    def _behind(self) -> bool:
        """The checkout is behind what the remote has, or had at the last fetch."""
        tip = self.tip or self._git("rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{self.branch}").stdout
        tip = tip.strip()
        return bool(tip) and bool(self._git("rev-list", f"HEAD..{tip}").stdout.strip())

    def _stash_and_follow(self) -> str:
        root = self.root
        return f"git -C {root} stash && git -C {root} pull --ff-only && git -C {root} stash pop"

    def _why_behind(self, commit: str) -> tuple[str, str] | None:
        """Why the checkout cannot fast-forward to COMMIT: the command and the words, or None."""
        root = self.root
        current = self._git("symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip()
        if current != self.branch:
            return (
                f"git -C {root} switch {self.branch} && git -C {root} pull --ff-only",
                f"the checkout is on {current or 'a detached HEAD'}, not on {self.branch}: nothing moved it, and "
                f"{self.branch} stays behind what was published",
            )
        if not self._checkout_clean():
            return (
                self._stash_and_follow(),
                "the checkout has uncommitted changes, so it stays behind what was published; nothing in it changed",
            )
        if self._git("merge-base", "--is-ancestor", "HEAD", commit).code != 0:
            return (
                f"git -C {root} pull --rebase",
                "the checkout has commits of its own, so it stays behind what was published; they are not published",
            )
        return None

    def _follow(self, commit: str) -> None:
        """The commit is on the remote: the checkout fast-forwards when it can, and takes the records
        of the machine back from the clone. It is the only time a run moves it this late."""
        self._remove_work()
        self._track(commit)
        if self._head() != commit:
            why = self._why_behind(commit)
            if why is None and self._git("merge", "--quiet", "--ff-only", commit).code != 0:
                why = (
                    f"git -C {self.root} pull --ff-only",
                    "the checkout could not fast-forward to what was published",
                )
            if why is not None:
                self.framework_moved = False
                self.run.item("checkout-behind", pending=False, run=why[0], message=why[1])
                return
        if self.profile is not None and not self._is_active(self.root):
            self.dirty = False
            self._checkout_rebuild()

    def _checkout_rebuild(self) -> None:
        """The last rebuild, from the checkout. Red, it leaves the records naming the clone: no firmware
        on top of that."""
        assert self.profile is not None
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self.run.step("checkout-rebuild", status)
        if status != 0:
            self._verify(False)

    def _back_to_checkout(self) -> None:
        """A commit that goes nowhere leaves the generation of the checkout active."""
        self._remove_work()
        self.framework_moved = False
        if self.profile is not None and not self.dirty and not self._is_active(self.root):
            self._checkout_rebuild()

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
