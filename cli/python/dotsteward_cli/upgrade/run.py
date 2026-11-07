"""A run of ``dotsteward upgrade``: convergent phases, see docs/upgrade.md.

Every run works out again what is needed and does what it can; the same command finishes what a
run left. There is no journal and no resume: the state is in dpkg, in git, in the records of
``rebuild`` and ``e2e``, in the last run report (the commits waiting for the remote) and a few files
under ``<state>/upgrade``. The engines do the work and this file only puts them in order:

    0  name, host publish, reconcile, capture, fetch, fast-forward, the questions
    1  one sudo window before all Nix work: recovery, pin, bridge, apt-get update, the apt plan
    2  writer, gate, local commit; self triggers; plugin scan; rebuild; channels of the user
    3  E2E with a key, machine checks, the red path
    4  publish, analysis and the offer, firmware in a window of its own, the report

Never here: an OS release upgrade, autoremove, a reboot.
"""

from __future__ import annotations

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

from dotsteward_cli import apt_plan, atomic, config, firmware, machine, procs, report, versions
from dotsteward_cli import publish as publishing
from dotsteward_cli.host import commit_identity
from dotsteward_cli.skills import commands as skills_commands
from dotsteward_cli.skills import state as skill_state
from dotsteward_cli.upgrade import analysis, facts, holds, plugins

_WEEK_SECONDS = 7 * 24 * 60 * 60
_STALE_PRODUCER_SECONDS = 14 * 24 * 60 * 60
_FLAKE_INPUTS = "flake_inputs.*"
_BRIDGE = "/usr/local/lib/dotsteward/apt-bridge.sh"
_BRIDGE_CONF = "/etc/dotsteward/apt-bridge.d"
_BRIDGE_REPO = "/var/lib/dotsteward/apt-bridge"
_APT_LOCK_SECONDS = 300
_VERSION_SECONDS = 20
_SKILL_ITEMS = {"ask": "origin-unknown", "conflict": "skill-conflict", "blocked": "capture-blocked"}
_NOT_COMPONENTS = {"core", "setup"}
# 128 + SIGINT, SIGTERM, SIGHUP.
_SIGNALLED = {130, 143, 129}
_KERNEL_IMAGE = re.compile(r"linux-image-[0-9].*")
_NVIDIA_DRIVER = re.compile(r"nvidia-driver-[0-9]+(-open)?(:.*)?")
_APT_BUCKETS = ("install", "upgrade", "remove", "downgrade")


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
        self.cli = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(self.root)]
        self.linux = config.runtime_platform(self.env) == "linux"
        self.name: str | None = None
        self.profile: str | None = None
        self.offline = False
        self.dirty = False
        self.tip = ""
        self.apt_changed = False
        self.red = False
        self.approved: tuple[firmware.Device, ...] = ()
        self.paths: report.ReportPaths | None = None
        last = report.load_last(state_root, "upgrade") or {}
        data = last.get("data") if isinstance(last.get("data"), dict) else {}
        self.own_commits: list[str] = list(data.get("own_commits") or []) if isinstance(data, dict) else []
        self.moved: list[dict[str, Any]] = list(data.get("moved") or []) if isinstance(data, dict) else []
        self.run.data.update(mode=mode)

    # --- helpers ---------------------------------------------------------------------------

    def _ds(self, *arguments: str) -> int:
        """A command of this CLI on this terminal. A signal that ended it ends the run as well: an
        interrupted rebuild is no red one."""
        status = procs.run_attached([*self.cli, *arguments])
        if status in _SIGNALLED:
            raise KeyboardInterrupt
        return status

    def _ds_output(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        """A command of this CLI, its standard output kept: JSON, or noise for this report."""
        return subprocess.run(
            [*self.cli, *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True, check=False
        )

    def _ds_quiet(self, *arguments: str) -> int:
        """A command of this CLI that prints a lot on a good day: its own lines pass as they come, the
        rest is shown only when it fails."""
        with subprocess.Popen(
            [*self.cli, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ) as child:
            assert child.stdout is not None
            others = []
            for line in child.stdout:
                if line.startswith("[dotsteward]"):
                    print(line, end="", flush=True)
                else:
                    others.append(line)
        if child.returncode != 0:
            print("".join(others), end="", flush=True)
        return child.returncode

    def _git(self, *arguments: str) -> publishing.GitResult:
        return publishing.git(self.root, *arguments)

    def _head(self) -> str:
        return self._git("rev-parse", "HEAD").stdout.strip()

    def _tree(self) -> str:
        return self._git("rev-parse", "HEAD^{tree}").stdout.strip()

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
            self.run.mark_interrupted(self.run.interrupted or ["SIGINT"])
            self.run.step("interrupted", report.FAILED, detail="the next run finishes what this one left")
        return self._end()

    def _end(self) -> int:
        self.run.data.update(own_commits=self.own_commits, moved=self.moved if self.own_commits else [])
        self.paths = self.run.write()
        for step in self.run.steps:
            if step["status"] != "ok":
                detail = step.get("detail") or (f"exit status {step['exit_status']}" if "exit_status" in step else "")
                _say(f"{step['name']}: {step['status']}" + (f" ({detail})" if detail else ""))
        _say(f"{self.run.status}: report {self.paths.report}")
        for item in self.run.items:
            said = [str(item[key]) for key in ("message", "run", "accept") if item.get(key)]
            if said:
                _say(f"{item['code']}: " + " -> ".join(said))
        if self.paths.review is not None:
            _say(f"see {self.paths.review}")
        return self.run.exit_code

    def document(self) -> dict[str, Any]:
        """The report as ``--json`` prints it."""
        assert self.paths is not None
        document: dict[str, Any] = json.loads(self.paths.report.read_text(encoding="utf-8"))
        document["report"] = str(self.paths.report)
        document["review"] = str(self.paths.review) if self.paths.review else None
        return document

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
                message="this machine has no name yet: run the command on a terminal",
            )

    def _skills(self) -> None:
        """What this machine made goes out first: a push of it must not look like a remote ahead of here."""
        if not skills_commands.tracking_on(self.instance):
            return
        self.run.step("skills-reconcile", self._ds_output("skills", "reconcile", "--full", "--json").returncode)
        self.run.step("skills-capture", self._ds_output("skills", "capture", "--now", "--json").returncode)
        pending = skill_state.load_pending(self.state_root).get("items") or {}
        for key, item in sorted(pending.items()):
            code = _SKILL_ITEMS.get(str(item.get("state"))) if isinstance(item, dict) else None
            if code:
                self.run.item(code, name=key.partition(":")[2], reason=item.get("reason"))

    def _fetch(self) -> bool:
        """The remote, and this checkout on its tip. False: a refusal that ends the run."""
        branch = self.instance.config["instance"]["branch"]
        if self._git("rev-parse", "--is-inside-work-tree").code != 0:
            return self._refuse(f"{self.root} is not a git work tree")
        current = self._git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        if current != branch:
            return self._refuse(f"the checkout is on {current}, not on {branch}")
        remote = self._git("config", "--get", "remote.origin.url").stdout.strip()
        if remote != self.instance.config["instance"]["remote"]:
            return self._refuse(f"origin is {remote or 'missing'}, not {self.instance.config['instance']['remote']}")
        self.dirty = bool(self._git("status", "--porcelain").stdout.strip())
        if self.dirty:
            self.run.item(
                "checkout-dirty",
                root=str(self.root),
                message="the checkout has uncommitted changes: the repository steps wait for a clean one",
            )
        outcome, tip, detail = publishing.fetch_tip(self.root, branch, "upgrade")
        if outcome != publishing.OK:
            self.offline = True
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
        if ahead and not set(ahead) <= set(self.own_commits):
            return self._refuse(
                f"this checkout has local commits that are not published: {ahead[0][:12]}; publish them first, "
                "upgrade only goes on with its own"
            )
        if ahead and behind and not self.dirty:
            # Another machine came first: no merge of pins, the writer starts again on the new tip.
            self._git("reset", "--quiet", "--keep", tip)
            self.own_commits, self.moved, ahead = [], [], []
            _say("another machine published first: the waiting commit is made again on the new tip")
        if not ahead:
            self.own_commits, self.moved = [], []
        if behind and not ahead and not self.dirty:
            done = self._git("merge", "--quiet", "--ff-only", tip)
            if done.code != 0:
                return self._refuse(f"cannot fast-forward to {tip[:12]}: {done.stderr.strip()}")
            self.again()
            self.instance = config.load_instance()
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
        self.run.item(
            "sudo-required", run=self._command_again(), message="this step needs sudo: run the command in a terminal"
        )

    def _sudo_ready(self) -> bool:
        """Sudo still works, or a terminal opens it once more: a long step can outlast its timestamp."""
        prefix = self._sudo()
        if (
            prefix[:1] != ["sudo"]
            or subprocess.run([*prefix, "true"], capture_output=True, check=False).returncode == 0
        ):
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
            self._apt(mode)
            if mode == "all" and not self.offline:
                self._system_channels()
        finally:
            self._close_sudo()

    def _apt(self, mode: str) -> None:
        request = self._request(mode)
        state = self.state_root
        if self._engine("dpkg-recover", lambda: apt_plan.recover(request, state_root=state)) is None:
            return
        if self._engine("policy", lambda: apt_plan.policy(request, state_root=state)) is None:
            return
        if self.offline:
            self.run.step("apt-commit", report.PARTIAL, detail="offline")
            return
        root = Path(self.env.get("DOTSTEWARD_SYSTEM_ROOT") or "/")
        if (root / _BRIDGE.lstrip("/")).is_file() and not self._privileged(
            "apt-bridge", "bash", _BRIDGE, _BRIDGE_CONF, _BRIDGE_REPO
        ):
            return
        if not self._privileged(
            "apt-update", "apt-get", "-q", "-o", f"DPkg::Lock::Timeout={_APT_LOCK_SECONDS}", "update"
        ):
            return
        answer = self._engine("apt-commit", lambda: apt_plan.commit(request, state_root=state))
        if answer is None:
            return
        changes = answer.get("changes") or {}
        counted = [f"{len(changes[bucket])} {bucket}" for bucket in _APT_BUCKETS if changes.get(bucket)]
        _say(f"apt ({mode}): " + (", ".join(counted) or "nothing to do"))
        if answer.get("committed") and counted:
            self.apt_changed = True

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
            self.run.item("producer-stale", pending=False, producer=role, days=int(age // 86400))
        self.run.step("pins-apply", report.OK, detail=f"the producer is {role}")

    def _discard(self) -> None:
        """What the writer left in a checkout that was clean when it started."""
        self._git("reset", "--quiet", "--hard", "HEAD")
        self._git("clean", "--quiet", "-fd")

    def _apply(self, latest: Path, skips: Sequence[str]) -> dict[str, Any] | None:
        """One run of the writer. None: it failed, and its tree is gone."""
        arguments = ["pins", "apply", "--latest", str(latest), "--json"]
        for pattern in skips:
            arguments += ["--skip", pattern]
        done = self._ds_output(*arguments)
        try:
            answer: dict[str, Any] = json.loads(done.stdout)
        except ValueError:
            answer = {}
        outcome = report.outcome_of(done.returncode)
        self.run.step("pins-apply", done.returncode, moved=[row.get("id") for row in answer.get("moved") or ()])
        if outcome == report.FAILED:
            self._discard()
            return None
        return answer

    def _producer(self) -> None:
        role = facts.role(self.instance, self.name)
        self.run.data.update(producer=role)
        if role != "this-machine":
            self._not_the_producer(role)
            return
        if self.offline:
            self.run.step("pins-apply", report.PARTIAL, detail="offline")
            return
        if self.dirty:
            self.run.step("pins-apply", report.OK, detail="the checkout is not clean")
            return
        if self.own_commits:
            self.run.step("pins-apply", report.OK, detail="a commit of an earlier run goes out first")
            return
        prepared = self._ds_output("txn", "prepare", "--official-sources-only", "--scope", "update")
        if prepared.returncode != 0:
            self.run.step("txn-prepare", prepared.returncode)
            return
        atomic.make_private_dirs(self.upgrade_dir)
        latest = self.upgrade_dir / "latest.json"
        latest.unlink(missing_ok=True)
        done = self._ds_output("pins", "latest", "--out", str(latest))
        # 1: some upstream gave no answer. Its rows say so, and the writer holds only their groups back.
        if done.returncode not in {0, 1} or not latest.is_file():
            self.run.step("pins-latest", done.returncode or report.FAILED)
            return
        skips = holds.skip_patterns(self.state_root, latest)
        if not self._week_due():
            skips = [_FLAKE_INPUTS, *skips]
        answer = self._apply(latest, skips)
        if answer is None:
            return
        moved = list(answer.get("moved") or ())
        flake_moved = bool(answer.get("flake_inputs_moved"))
        if answer.get("framework_moved"):
            # The new framework writes the rest, with its own manifest and its own engine.
            self.cli = [str(self.root / ".dotsteward" / "cli.sh")]
            answer = self._apply(latest, skips)
            if answer is None:
                return
            moved += answer.get("moved") or ()
            flake_moved = flake_moved or bool(answer.get("flake_inputs_moved"))
        if flake_moved:
            self._start_week()
        if not self._git("status", "--porcelain").stdout.strip():
            return
        _say(f"pins moved: {', '.join(str(row.get('id')) for row in moved) or 'derived values only'}; the gate decides")
        if self._ds_quiet("gate", "--scope", "update") != 0:
            self.run.step("gate", report.FAILED)
            self.run.item(
                "gate-failed",
                log=str(Path(self.state_root) / "update" / "validate.log"),
                moved=[row.get("id") for row in moved],
                message="the gate refused the new pins: nothing was committed",
            )
            self._discard()
            return
        self.run.step("gate", report.OK)
        self._git("add", "-A")
        subject = self.instance.config["commit"]["update_subject"]
        identity = commit_identity(self.root, "HEAD")
        committed = self._git(*identity, "commit", "--quiet", "-m", subject)
        if committed.code != 0:
            self.run.step("commit", report.FAILED, detail=committed.stderr.strip())
            self._discard()
            return
        self.own_commits = [self._head()]
        self.moved = moved
        # Known at once: the next run must recognise this commit, however this one ends.
        self.run.data.update(own_commits=self.own_commits, moved=self.moved)
        self.run.write()
        _say(f"committed {self.own_commits[0][:12]} locally; it goes out after a green E2E")
        self.run.step("commit", report.OK, commit=self.own_commits[0])

    def _self_updates(self) -> None:
        """What updates itself is only asked to; a second way in is never added."""
        for entry in facts.self_updates(self._active(), self.instance):
            step = f"self:{entry.component}"
            if self.offline:
                self.run.step(step, report.PARTIAL, detail="offline")
            elif shutil.which(entry.command[0]) is None:
                self.run.step(step, report.OK, detail=f"{entry.command[0]} is not installed")
            else:
                self.run.step(step, procs.run_attached(list(entry.command)))

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
                message=f"the scan has a finding in {key}: look at it, or remove the plugin; nothing was rolled back",
            )
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
            if dest.is_file():
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
        if self.dirty:
            self.run.step("rebuild", report.OK, detail="the checkout is not clean")
            return
        active = self._activation()
        if active.get("tree_oid") == self._tree() and active.get("profile") == self.profile:
            self.run.step("rebuild", report.OK, detail="skipped: this tree is active")
            return
        _say(f"rebuild of profile {self.profile}")
        self._save_binaries()
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self.run.step("rebuild", status)
        if status != 0 and self.own_commits:
            self._go_back(f"rebuild failed with status {status}", [])

    def _user_channels(self) -> None:
        if self.offline:
            self.run.step("user-channels", report.PARTIAL, detail="offline")
            return
        commands = facts.tracked_commands(facts.mirror(self.instance, self.env), self._active())
        for channel, status in analysis.update_user_channels(commands, False, self.env).items():
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
            "tree": self._tree(),
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

    def _run_e2e(self) -> list[str] | None:
        """E2E as it stands: None when green, else the ids of what is red."""
        assert self.profile is not None
        repo_checks = not (self.offline or self.dirty)
        arguments = ["e2e", "--profile", self.profile, "--keep-going", "--json"]
        if not repo_checks:
            arguments.append("--skip-repo-checks")
        elif self.own_commits:
            arguments += ["--expected-remote-base", self.tip]
        done = self._ds_output(*arguments)
        if done.returncode == 0:
            atomic.make_private_dirs(self.upgrade_dir)
            key = self._e2e_key(repo_checks)
            atomic.atomic_write_json(self.upgrade_dir / "e2e-key.json", {"key": key}, mode=0o600)
            self._forget_binaries()
            return None
        try:
            findings = json.loads(done.stdout).get("findings") or []
        except (ValueError, AttributeError):
            findings = []
        return sorted({str(finding.get("step")) for finding in findings}) or ["unknown"]

    def _e2e(self, *, force: bool = False) -> None:
        if self.profile is None:
            return
        repo_checks = not (self.offline or self.dirty)
        if not force and not self.apt_changed and self._e2e_green_for(self._e2e_key(repo_checks)):
            self.run.step("e2e", report.OK, detail="skipped: nothing changed since the last green run")
            return
        _say(f"E2E of profile {self.profile}")
        red = self._run_e2e()
        if red is None:
            _say("E2E is green")
            self.run.step("e2e", report.OK)
        elif self.own_commits:
            self._go_back(f"E2E red: {', '.join(red)}", red)
        else:
            self._still_red(red)

    def _still_red(self, red: Sequence[str]) -> None:
        """Red, and nothing of this run to go back to: the package moved, or a setting did."""
        self.red = True
        self.run.step("e2e", report.FAILED, findings=list(red))
        hints = self._hold_packages(red)
        command = f"dotsteward e2e --profile {self.profile} --keep-going"
        self.run.item("e2e-red", findings=list(red), run=command, hint="; ".join(hints) or None)

    def _hold_packages(self, red: Sequence[str]) -> list[str]:
        names = {check.split(":", 1)[0] for check in red} - _NOT_COMPONENTS
        installed = self._versions_of_tracked()
        hints = []
        for component in self._active():
            if component["name"] not in names or component.get("method") != "deb":
                continue
            for package in sorted(set((component.get("install") or {}).get("packageNames") or ())):
                version = installed.get(package, "")
                holds.add(self.state_root, component["name"], f"apt:{package}", version, f"E2E red: {', '.join(red)}")
                hints.append(f"sudo apt-mark hold {package}")
        return hints

    def _go_back(self, reason: str, red: Sequence[str]) -> None:
        """A move of this run went red: the tree and the binaries from before, a local hold for what
        moved, nothing published. The next run leaves the held pins and moves the others."""
        saved = self._saved_binaries()
        components = {check.split(":", 1)[0] for check in red} - _NOT_COMPONENTS
        guilty = [row for row in self.moved if components & set(str(row.get("id")).split("."))]
        for row in guilty or self.moved:
            identifier = str(row.get("id"))
            segments = set(identifier.split("."))
            component = next(iter(sorted(components & segments)), next(iter(sorted(components)), identifier))
            holds.add(self.state_root, component, identifier, str(row.get("to")), reason)
            self.run.item(
                "red-held",
                id=identifier,
                version=row.get("to"),
                reason=reason,
                message=f"{identifier} {row.get('to')} stays back until upstream has something newer: {reason}",
            )
        self._git("reset", "--quiet", "--keep", f"{self.own_commits[0]}^")
        self.own_commits, self.moved = [], []
        assert self.profile is not None
        # The rebuild first: an installer keeps a binary newer than its pin, so the copy goes last.
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self._restore_binaries(saved)
        self.run.step("go-back", status, detail=reason)
        again = self._run_e2e() if status == 0 else ["rebuild"]
        if again is None:
            self.run.step("e2e", report.PENDING, detail=f"went back: {reason}")
            self.red = True
        else:
            self._still_red(again)

    def _host_checks(self) -> None:
        if not self.linux or shutil.which("dpkg-query") is None:
            return
        done = subprocess.run(
            ["dpkg-query", "-W", "-f=${db:Status-Status} ${Package} ${Version}\n"],
            capture_output=True,
            text=True,
            check=False,
        )
        newest = ""
        newest_version = ""
        nvidia = False
        # Only an installed image counts: `rc` leftovers of old kernels say nothing.
        for line in done.stdout.splitlines():
            fields = line.split()
            if len(fields) != 3 or fields[0] != "installed":
                continue
            nvidia = nvidia or bool(_NVIDIA_DRIVER.fullmatch(fields[1]))
            if not _KERNEL_IMAGE.fullmatch(fields[1]):
                continue
            if not newest_version or versions.compare(fields[2], newest_version) > 0:
                newest, newest_version = fields[1].removeprefix("linux-image-"), fields[2]
        running = subprocess.run(["uname", "-r"], capture_output=True, text=True, check=False).stdout.strip()
        root = Path(self.env.get("DOTSTEWARD_SYSTEM_ROOT") or "/")
        flagged = (root / "run" / "reboot-required").exists()
        if flagged or (newest and running and newest != running):
            detail = f"{newest} is installed, {running} runs" if newest != running else "the system asks for it"
            message = f"a reboot is due when it suits you: {detail}. This command never reboots."
            self.run.item("reboot-required", pending=False, running=running, newest=newest, message=message)
            if nvidia and newest:
                self._module_of(newest)
        self.run.step("host-checks", report.OK)

    def _module_of(self, release: str) -> None:
        """Whether the kernel a reboot would start has the module of the driver. Said once in a run."""
        abi, _, base = release.rpartition("-")
        told = {(item.get("code"), item.get("kernel")) for item in self.run.items}
        for found in apt_plan.module_check({"kernel": {"abi": abi, "base": base}, "nvidia": True}):
            if (found["code"], found.get("kernel")) in told:
                continue
            fields = {key: value for key, value in found.items() if key not in {"code", "pending"}}
            self.run.item(found["code"], pending=bool(found.get("pending")), **fields)

    # --- phase 4 ---------------------------------------------------------------------------

    def _publish(self) -> None:
        if not self.own_commits:
            return
        if self.offline:
            self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
            return
        if self.red or self.dirty:
            return
        branch = self.instance.config["instance"]["branch"]
        status = self._ds_quiet("txn", "publish", "--scope", "update", "--expected-base", self.tip)
        if status == 0:
            self.own_commits, self.moved = [], []
            self.run.step("publish", report.OK)
            return
        outcome, tip, _ = publishing.fetch_tip(self.root, branch, "upgrade")
        if outcome != publishing.OK:
            self.offline = True
            self.run.step("publish", report.PARTIAL, detail="offline: the commit waits for the next run")
        elif tip != self.tip:
            self.run.step("publish", report.PENDING, detail="the remote moved")
            self.run.item(
                "publish-race",
                run=self._command_again(),
                message="another machine came first: the next run starts over",
            )
        else:
            self.run.step("publish", status)

    def _analysis(self) -> Mapping[str, Any]:
        commands = facts.tracked_commands(facts.mirror(self.instance, self.env), self._active())
        channels = analysis.read_user_channels(commands, self.offline, self.env)
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
                and any(analysis.counts(channels).values())
                and _ask_yes("Update these too?")
            ):
                self.apt_changed = False
                self._window("all")
                self._user_channels()
                if self.apt_changed:
                    self._e2e(force=True)
        if self.approved:
            if self.red:
                self.run.item(
                    "firmware-available",
                    pending=False,
                    message="E2E is red: approved firmware waits for a green run",
                )
            else:
                _say("firmware: the approved devices, in a sudo window of their own")
                firmware.apply(self.approved, self.run)
