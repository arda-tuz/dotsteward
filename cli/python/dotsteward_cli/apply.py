"""``dotsteward maintain begin`` and ``dotsteward apply``: a maintain transaction (docs/apply.md).

``maintain begin`` opens it: the guards of the checkout, a fast-forward when the checkout is only
behind the remote, the read-only preflight of the profile, ``txn prepare`` in the maintain scope
and the settings status, and the questions to put to the user before anything is written.

``apply`` finishes it in one command and a fixed order: everything is staged, the gate proves the
tree in the maintain scope, the commit carries the trace line of this machine; activated, the
system-level components an adopt-mode profile needs come in, ``rebuild --switch`` activates the
committed tree and E2E checks it against the base; published, ``txn publish`` pushes it, which
after an activation needs that E2E. The checkout is the transaction: apply commits there and never
cleans, stashes or amends; the one reset takes back the commit it just made when a commit hook
changed its tree away from the proven one, and keeps the changes staged. Like ``upgrade`` there is
no journal and no resume: every run works out again what is left. The gate answers from its memo
for a tree it proved, a tree that is active is not rebuilt, a passed E2E of the active tree with
the repository checks is not run again and a published commit is not pushed again, so the same
command finishes what a red step, a missing network or a person's sudo step left.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import config, context, firmware, locks, machine, report, runner
from dotsteward_cli import publish as publishing
from dotsteward_cli.host import commit_identity, commit_message
from dotsteward_cli.upgrade import facts

EXIT_USAGE = 2
EXIT_INTERRUPTED = 130
# The private ref of the fetches of a maintain transaction: refs/dotsteward/apply/tip.
_SCOPE = "apply"
_SUBJECT = re.compile(r"^(" + "|".join(context.CONVENTIONAL_TYPES) + r")(\([a-z0-9._/-]+\))?!?: .+")
# The methods a rebuild of an adopt-mode profile never installs.
_SYSTEM_LEVEL = {"linux": "deb", "darwin": "app-archive"}
_SETTINGS_WAIT = {"local-changed", "local-deleted"}
_STEP_WORDS = {"pending": "waits for you", "partial": "skipped, no network", "failed": "failed"}
_COMMIT_SECONDS = 600

_APPLY_DESCRIPTION = (
    "Finishes a maintain transaction in one command: stages every change of the checkout, runs the gate "
    "in the maintain scope, commits with SUBJECT and the trace line of this machine, then with --activate "
    "installs the system-level components an adopt-mode profile needs, runs rebuild --switch and E2E "
    "against the base, and with --publish runs txn publish. [maintain] activate and publish of "
    "workstation.toml are the defaults (both false). Run the same command again after a fix or a sudo "
    "step: it does what is left. Exit status: 0 done, 1 a refusal or a red step, 2 usage error, 3 a sudo "
    "step waits (review.json), 6 no network: the push waits, 130 interrupted."
)
_BEGIN_DESCRIPTION = (
    "Opens a maintain transaction: checks that this is the instance checkout on its branch, fast-forwards "
    "it when it is only behind the remote, runs the read-only preflight of the profile, records the base "
    "with txn prepare in the maintain scope and reads the settings status. Exit status: 0 open, 1 refused, "
    "2 usage error, 3 open with questions for the user, or the adaptive route (nothing opened), 6 no network "
    "(nothing opened)."
)


def _say(prefix: str, text: str) -> None:
    print(f"[{prefix}] {text}", flush=True)


def _error(text: str) -> None:
    print(f"[dotsteward] ERROR: {text}", file=sys.stderr, flush=True)


class _Checkout(runner.Runner):
    """What begin and apply both ask of the checkout and the remote."""

    def __init__(self, instance: config.Instance, state_root: str, profile: str | None) -> None:
        super().__init__(instance, state_root, _SCOPE)
        effective = machine.effective(instance, self.env)
        self.name: str | None = effective["name"]
        self.profile = (
            profile or effective["profile"] or context.current_profile(state_root, instance.config["profiles"])
        )
        self.remote = str(instance.config["instance"]["remote"])
        self.tip = ""

    def _guard(self) -> str | None:
        """Why this is not the instance checkout on its branch, or None."""
        top = self._git("rev-parse", "--show-toplevel")
        if top.code != 0 or os.path.realpath(top.stdout.strip()) != os.path.realpath(self.root):
            return f"{self.root} is not the top of a git work tree"
        current = self._git("symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip()
        if current != self.branch:
            return f"the checkout is on {current or 'a detached HEAD'}, not on {self.branch}"
        origin = self._git("config", "--get", "remote.origin.url").stdout.strip()
        if origin != self.remote:
            return f"origin is {origin or 'missing'}, not {self.remote}: this is not the instance checkout"
        return None

    def _fetch(self) -> str | None:
        """The tip of the remote in self.tip, the last known one without a network. Why there is
        none, or None."""
        outcome, tip, detail = publishing.fetch_tip(self.root, self.branch, _SCOPE)
        if outcome == publishing.OK:
            self.tip = tip
            self._track(tip)
            return None
        if outcome == publishing.REFUSED:
            return f"the remote refused the fetch: {detail}"
        self.offline = True
        known = self._git("rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{self.branch}^{{commit}}")
        if known.code != 0:
            return f"no network, and origin/{self.branch} was never fetched"
        self.tip = known.stdout.strip()
        return None

    def _ahead(self) -> list[str]:
        return self._git("rev-list", "--reverse", f"{self.tip}..HEAD").stdout.split()

    def _behind(self) -> list[str]:
        return self._git("rev-list", f"HEAD..{self.tip}").stdout.split()

    def _nonconventional(self) -> list[tuple[str, str]]:
        """The commits after the tip whose subject txn publish refuses: (oid, subject)."""
        listing = self._git("log", "--reverse", "--format=%H%x00%s", f"{self.tip}..HEAD").stdout
        found = []
        for line in listing.splitlines():
            oid, _, subject = line.partition("\0")
            if oid and not _SUBJECT.fullmatch(subject):
                found.append((oid, subject))
        return found

    def _fold_command(self) -> str:
        """The way out for such commits: their changes stay, as changes of the transaction."""
        return f"git -C {self.root} reset --soft {self.tip}"

    def _changes(self) -> list[str]:
        return [
            line for line in self._git("status", "--porcelain", "--untracked-files=normal").stdout.splitlines() if line
        ]


# --- maintain begin ---------------------------------------------------------------------------


class Begin(_Checkout):
    """One run of ``maintain begin``, under the instance lock."""

    def __init__(self, instance: config.Instance, state_root: str, profile: str | None) -> None:
        super().__init__(instance, state_root, profile)
        self.ask: list[dict[str, Any]] = []
        self.warnings: list[str] = []
        self.preflight: dict[str, Any] | None = None
        self.settings: list[str] = []
        self.ahead: list[str] = []
        self.dirty: list[str] = []
        self.open = False
        self.refused: str | None = None

    def execute(self) -> int:
        self.refused = self._guard() or self._fetch()
        if self.refused is None:
            self.refused = self._follow()
        if self.refused is not None:
            _error(self.refused)
            return report.FAILED
        self.ahead = self._ahead()
        self.dirty = self._changes()
        if self.ahead:
            self.ask.append(
                {
                    "code": "unpublished-commits",
                    "commits": self.ahead,
                    "message": (
                        "these commits are not on the remote: if they belong to this transaction, "
                        "dotsteward apply finishes them with it; else remove them first"
                    ),
                }
            )
        bad = self._nonconventional()
        if bad:
            self.ask.append(
                {
                    "code": "nonconventional-commits",
                    "commits": [oid for oid, _ in bad],
                    "subjects": [subject for _, subject in bad],
                    "run": self._fold_command(),
                    "message": (
                        "txn publish refuses these subjects, so apply refuses them: run the command to keep their "
                        "changes as changes of this transaction, then dotsteward apply -m with a conventional subject"
                    ),
                }
            )
        if self.dirty:
            self.ask.append(
                {
                    "code": "checkout-dirty",
                    "changes": self.dirty,
                    "message": "the checkout has changes: do they belong to this transaction? apply commits them all",
                }
            )
        route = self._preflight()
        if route is None:
            return report.FAILED
        if route == "adaptive":
            self.ask.append(
                {
                    "code": "adaptive-route",
                    "message": (
                        "this machine is not on the fast path of the instance: write no tracked file, report the "
                        "reasons of the preflight and ask how to go on"
                    ),
                }
            )
        elif not self.offline and not self.ahead:
            if not self._prepare():
                return report.FAILED
            self.open = True
        elif not self.offline:
            # The base is the tip; the commits after it are part of the transaction.
            self.open = True
        self._settings()
        if self.offline:
            return report.PARTIAL
        return report.PENDING if self.ask else report.OK

    def _follow(self) -> str | None:
        """A checkout that is only behind fast-forwards; a diverged one is refused."""
        if self.offline:
            return None
        behind, ahead = self._behind(), self._ahead()
        if behind and ahead:
            return (
                f"the checkout and the remote diverged ({len(ahead)} local, {len(behind)} remote commits): "
                f"run git -C {self.root} pull --rebase, then dotsteward maintain begin"
            )
        if behind:
            done = self._git("merge", "--quiet", "--ff-only", self.tip)
            if done.code != 0:
                return f"cannot fast-forward to {self.tip[:12]}: {done.stderr.strip()}"
            _say("maintain", f"fast-forwarded to {self.tip[:12]}")
        return None

    def _preflight(self) -> str | None:
        assert self.profile is not None
        done = self._ds_output("preflight", "--read-only", "--json", "--profile", self.profile)
        try:
            document = json.loads(done.stdout)
        except ValueError:
            document = None
        if done.returncode not in {0, 3} or not isinstance(document, dict):
            _error(f"the preflight failed (exit {done.returncode})")
            return None
        self.preflight = document
        return "adaptive" if done.returncode == 3 else "fast"

    def _prepare(self) -> bool:
        done = self._ds_output("txn", "prepare", "--official-sources-only", "--scope", "maintain")
        if done.returncode != 0:
            return False
        lines = [line for line in done.stdout.splitlines() if line.startswith("{")]
        try:
            answer = json.loads(lines[-1]) if lines else {}
        except ValueError:
            answer = {}
        self.warnings = [str(warning) for warning in answer.get("warnings") or ()]
        return True

    def _settings(self) -> None:
        done = self._ds_output("settings", "status", "--json")
        try:
            document = json.loads(done.stdout)
        except ValueError:
            document = None
        if not isinstance(document, dict):
            self.warnings.append(f"the settings status could not be read (exit {done.returncode})")
            return
        self.settings = [
            str(entry.get("id"))
            for entry in document.get("entries") or ()
            if isinstance(entry, dict) and (entry.get("state") in _SETTINGS_WAIT or entry.get("needs_decision"))
        ]
        if self.settings:
            self.ask.append(
                {
                    "code": "settings-local",
                    "entries": self.settings,
                    "message": "these settings changed here and are not in the repository: write them now?",
                }
            )

    def document(self) -> dict[str, Any]:
        activate, publish = _defaults(self.instance)
        flags = "".join([" --activate" if activate else "", " --publish" if publish else ""])
        return {
            "schema_version": 1,
            "open": self.open,
            "offline": self.offline,
            "base_oid": self.tip or None,
            "head_oid": self._head() or None,
            "instance": {"path": str(self.root), "branch": self.branch, "remote": self.remote},
            "machine": self.name,
            "profile": self.profile,
            "activate": activate,
            "publish": publish,
            "dirty": self.dirty,
            "unpublished_commits": self.ahead,
            "preflight": self.preflight,
            "settings_pending": self.settings,
            "warnings": self.warnings,
            "ask": self.ask,
            "next": f'edit the instance, then: dotsteward apply -m "<type>: <summary>"{flags}',
        }

    def say(self) -> None:
        if self.open:
            _say("maintain", f"the transaction is open on {self.tip}")
        elif self.offline:
            _say("maintain", f"no network: nothing was opened; the last known tip is {self.tip}")
        else:
            _say("maintain", "nothing was opened")
        for warning in self.warnings:
            _say("maintain", f"warning: {warning}")
        for question in self.ask:
            _say("maintain", f"{question['code']}: {question['message']}")
        if self.open:
            _say("maintain", self.document()["next"])


# --- apply ------------------------------------------------------------------------------------


class Apply(_Checkout):
    """One run of ``apply``, under the instance lock."""

    def __init__(
        self,
        instance: config.Instance,
        state_root: str,
        profile: str | None,
        subject: str | None,
        activate: bool,
        publish: bool,
        terminal: bool,
    ) -> None:
        super().__init__(instance, state_root, profile)
        self.subject = subject
        self.activate = activate
        self.publish = publish
        self.terminal = terminal
        self.run = report.RunReport("apply", state_root)
        self.base = ""
        self.commit: str | None = None
        self.published = False
        self.interrupted = False
        self.paths: report.ReportPaths | None = None
        self.run.data.update(machine=self.name, profile=self.profile, activate=activate, publish=publish)

    def _step(self, name: str, code: int, started: float, **details: Any) -> None:
        self.run.step(name, code, seconds=round(time.monotonic() - started, 1), **details)

    def _again(self, subject: str | None = None) -> str:
        """The command that goes on from here."""
        words = ["dotsteward apply"]
        if subject:
            words.append(f'-m "{subject}"')
        words += ["--activate" if self.activate else "--no-activate", "--publish" if self.publish else "--no-publish"]
        return " ".join(words)

    def execute(self) -> int:
        def interrupted(signum: int, frame: object) -> None:
            raise KeyboardInterrupt

        for number in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, interrupted)
        try:
            committed = self._start() and self._stage() and self._gate() and self._commit()
            if committed and (not self.activate or (self._install() and self._rebuild() and self._e2e())):
                self._publish()
        except KeyboardInterrupt:
            self.interrupted = True
            self.run.mark_interrupted(self.run.interrupted or ["SIGINT"])
            self.run.step("interrupted", report.FAILED, detail="the same command goes on from here")
        return self._end()

    def _refuse(self, message: str) -> bool:
        _error(message)
        self.run.step("guard", report.FAILED, detail=message)
        return False

    def _start(self) -> bool:
        why = self._guard() or self._fetch()
        if why is not None:
            return self._refuse(why)
        if not publishing.is_ancestor(self.root, self.tip, "HEAD"):
            if publishing.is_ancestor(self.root, "HEAD", self.tip):
                return self._refuse(
                    f"the remote moved to {self.tip[:12]} since the transaction began: run dotsteward maintain begin, "
                    "which fast-forwards the checkout, then the same dotsteward apply"
                )
            return self._refuse(
                f"the checkout and the remote diverged: run git -C {self.root} pull --rebase, then dotsteward apply"
            )
        bad = self._nonconventional()
        if bad:
            said = ", ".join(f"{oid[:12]} {subject!r}" for oid, subject in bad)
            self.run.item(
                "nonconventional-commits",
                commits=[oid for oid, _ in bad],
                run=self._fold_command(),
                message="txn publish refuses these subjects: keep their changes with the command, then apply -m",
            )
            return self._refuse(
                f"unpublished commits without a conventional subject, which txn publish refuses: {said}; keep their "
                f"changes as changes of this transaction with {self._fold_command()}, then run dotsteward apply "
                '-m "<type>: <summary>"'
            )
        self.base = self.tip
        self.run.data.update(base=self.base, offline=self.offline)
        return True

    def _stage(self) -> bool:
        started = time.monotonic()
        added = self._git("add", "-A")
        if added.code != 0:
            self._step("stage", report.FAILED, started, detail=added.stderr.strip())
            return False
        links = self._new_gitlinks()
        if links:
            # Out of the index again: the index holds what it held before plus the rest.
            self._git("reset", "--quiet", "--", *links)
            self._step("stage", report.FAILED, started, detail="a git repository inside the checkout")
            self.run.item(
                "nested-repository",
                paths=links,
                message=(
                    "a git repository inside the checkout would be published as an empty gitlink: vendor its files "
                    "(remove its .git) or remove it, then the same apply"
                ),
            )
            return self._refuse(
                f"git repositories inside the checkout, which would be published as gitlinks: {', '.join(links)}; "
                "remove their .git to vendor the files, or remove them"
            )
        staged = self._staged()
        if not staged and self._head() == self.base:
            _say("apply", "nothing to apply: the checkout is the published tip and has no change")
            self._step("stage", report.OK, started, detail="nothing to apply")
            return False
        if staged and not self.subject:
            # The guard of main saw no change: one came in the meantime.
            return self._refuse("a change waits for its commit: give its subject with -m")
        self._step("stage", report.OK, started, detail=f"{len(staged)} paths" if staged else "nothing new")
        return True

    def _new_gitlinks(self) -> list[str]:
        """The staged gitlinks that are not submodules of .gitmodules: nested repositories."""
        raw = self._git("diff", "--cached", "--raw", "--no-renames", "-z").stdout.split("\0")
        submodules = {
            line.partition(" ")[2]
            for line in self._git("config", "--file", ".gitmodules", "--get-regexp", r"\.path$").stdout.splitlines()
        }
        links = []
        for header, path in zip(raw[0::2], raw[1::2], strict=False):
            fields = header.split()
            if len(fields) >= 2 and fields[1] == "160000" and path not in submodules:
                links.append(path)
        return links

    def _staged(self) -> list[str]:
        return self._git("diff", "--cached", "--name-only", "-z").stdout.split("\0")[:-1]

    def _gate(self) -> bool:
        started = time.monotonic()
        wall = time.time()
        _say("apply", "the gate proves the tree")
        status = self._ds_quiet("gate", "--scope", "maintain", "--expected-base", self.base)
        log = str(Path(self.state_root) / "update" / "validate.log")
        if status == 0:
            self._step("gate", report.OK, started)
            return True
        environment = self._gate_environment(wall)
        if environment is not None:
            network = environment.startswith("the network")
            self._step("gate", report.PARTIAL if network else report.FAILED, started, detail=environment)
            self.run.item(
                "gate-failed",
                log=log,
                environment=environment,
                run=self._again(self.subject),
                message=f"the gate could not judge the tree: {environment}; nothing was committed",
            )
            return False
        self._step("gate", status, started)
        self.run.item(
            "gate-failed",
            log=log,
            run=self._again(self.subject),
            message="the gate refused the tree: nothing was committed; fix it and run the same command again",
        )
        return False

    def _validated_tree(self) -> str:
        path = Path(self.state_root) / "update" / "validation.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return ""
        if not isinstance(record, dict) or record.get("result") != "passed" or record.get("scope") != "maintain":
            return ""
        return str(record.get("tree_oid") or "")

    def _tree_changed(self, started: float, run: str) -> bool:
        self._step("commit", report.FAILED, started, detail="the tree is not the tree the gate proved")
        self.run.item(
            "tree-changed",
            run=run,
            message=(
                "the tree changed after the gate (a commit hook?): nothing was committed and the changes stay "
                "staged; the same command proves the new tree"
            ),
        )
        return False

    def _commit(self) -> bool:
        started = time.monotonic()
        proven = self._validated_tree()
        if self._staged():
            assert self.subject is not None
            # The index first: only the proven tree may become a commit.
            if self._git("write-tree").stdout.strip() != proven:
                return self._tree_changed(started, self._again(self.subject))
            before = self._head()
            committed = publishing.git(
                self.root,
                *commit_identity(self.root, "HEAD"),
                "commit",
                "--quiet",
                "-F",
                "-",
                env={"TZ": "UTC"},
                stdin=commit_message(self.subject, self.name),
                seconds=_COMMIT_SECONDS,
            )
            if committed.code != 0:
                said = committed.stderr.strip()[-400:]
                self._step("commit", report.FAILED, started, detail=said)
                self.run.item("commit-refused", message=f"git or a hook refused the commit: {said}")
                return False
            if self._tree_of(self.root) != proven:
                # A hook changed the tree during the commit: the commit this run made goes again, its
                # changes stay staged, so no unproven commit is left behind.
                if self._git("rev-parse", "HEAD^").stdout.strip() == before:
                    self._git("reset", "--quiet", "--soft", before)
                return self._tree_changed(started, self._again(self.subject))
            detail = None
        else:
            if self._tree_of(self.root) != proven:
                return self._tree_changed(started, self._again())
            detail = "nothing new to commit"
        self.commit = self._head()
        self.run.data.update(commit=self.commit)
        self._step("commit", report.OK, started, **({"detail": detail} if detail else {}))
        _say("apply", f"committed {self.commit[:12]}" if detail is None else f"{detail}: {self.commit[:12]}")
        return True

    # --- activation ---------------------------------------------------------------------------

    def _mirror_at(self, commit: str) -> dict[str, dict[str, Any]]:
        """The components of the manifest mirror of this machine at COMMIT, by name."""
        path = f".dotsteward/manifest.{machine.nix_system(self.instance, self.env)}.json"
        shown = self._git("show", f"{commit}:{path}")
        try:
            document = json.loads(shown.stdout) if shown.code == 0 else {}
        except ValueError:
            document = {}
        components = document.get("components") if isinstance(document, dict) else None
        return {
            str(component["name"]): component
            for component in components or ()
            if isinstance(component, dict) and isinstance(component.get("name"), str)
        }

    def _system_components(self) -> list[str]:
        """The system-level components that this transaction adds or changes and that the rebuild of
        an adopt-mode profile leaves out."""
        method = _SYSTEM_LEVEL.get(config.runtime_platform(self.env))
        before = self._mirror_at(self.base)
        names = []
        for component in facts.active_components(self.instance, self.profile, self.env):
            name = str(component.get("name"))
            modes = component.get("modes") or {}
            if component.get("method") != method or modes.get(self.profile) != "adopt":
                continue
            if before.get(name) != component:
                names.append(name)
        return names

    def _in_place(self, name: str) -> bool:
        """``install --check-only`` finds the component NAME in place; what it says is not shown,
        since a missing component is the expected answer here."""
        assert self.profile is not None
        argv = [*self._cli(), "install", "--profile", self.profile, "--component", name, "--check-only"]
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
        if done.returncode in runner.SIGNALLED:
            raise KeyboardInterrupt
        return done.returncode == 0

    def _install(self) -> bool:
        assert self.profile is not None
        names = self._system_components()
        if not names:
            return True
        started = time.monotonic()
        missing = [name for name in names if not self._in_place(name)]
        if not missing:
            self._step("install", report.OK, started, detail="in place", components=names)
            return True
        selection = [word for name in missing for word in ("--component", name)]
        if not self.terminal:
            command = " ".join(
                ["dotsteward", "--instance", str(self.root), "install", "--profile", self.profile, *selection]
            )
            self._step("install", report.PENDING, started, components=missing)
            self.run.item(
                "install-required",
                components=missing,
                run=command,
                message=(
                    "an adopt-mode rebuild never installs a system-level component and this one needs sudo: run "
                    f"the command in a terminal, then {self._again()}"
                ),
            )
            return False
        _say("apply", f"system-level components first: {', '.join(missing)}")
        status = self._ds("install", "--profile", self.profile, *selection)
        self._step("install", status, started, components=missing)
        if status != 0:
            self.run.item(
                "install-failed", components=missing, message="the install of the system-level components failed"
            )
            return False
        return True

    def _rebuild(self) -> bool:
        assert self.profile is not None
        started = time.monotonic()
        if self._is_active(self.root):
            self._step("rebuild", report.OK, started, detail="skipped: this tree is active")
            return True
        _say("apply", f"rebuild of profile {self.profile}")
        status = self._ds("rebuild", "--profile", self.profile, "--switch")
        self._step("rebuild", status, started)
        if status != 0:
            self.run.item(
                "rebuild-failed",
                run=self._again("fix: <what was fixed>"),
                message=f"the rebuild failed ({status}): the commit stays here; fix it with a new commit",
            )
            return False
        return True

    def _e2e_green(self) -> bool:
        """A passed E2E with the repository checks of the active tree, generation and profile."""
        try:
            record = json.loads((Path(self.state_root) / "update" / "e2e.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        active = self._activation()
        return (
            isinstance(record, dict)
            and record.get("result") == "passed"
            and record.get("repo_checks") is True
            and record.get("tree_oid") == self._tree_of(self.root)
            and record.get("generation") == active.get("generation")
            and record.get("profile") == self.profile
        )

    def _e2e(self) -> bool:
        assert self.profile is not None
        started = time.monotonic()
        if self._e2e_green():
            self._step("e2e", report.OK, started, detail="skipped: passed for this tree")
            return True
        arguments = ["e2e", "--profile", self.profile, "--keep-going", "--json"]
        arguments += ["--skip-repo-checks"] if self.offline else ["--expected-remote-base", self.base]
        _say("apply", f"E2E of profile {self.profile}")
        done = self._ds_output(*arguments)
        if done.returncode in runner.SIGNALLED:
            raise KeyboardInterrupt
        if done.returncode == 0:
            self._step(
                "e2e", report.OK, started, **({"detail": "without the repository checks"} if self.offline else {})
            )
            return True
        try:
            findings = json.loads(done.stdout).get("findings") or []
        except (ValueError, AttributeError):
            findings = []
        red = sorted({str(finding.get("step")) for finding in findings if isinstance(finding, dict)})
        if not red or done.returncode == runner.KILLED or done.returncode < 0:
            self._step("e2e", report.FAILED, started, detail=f"no result (exit {done.returncode})")
            self.run.item(
                "e2e-no-result",
                run=self._again(),
                message="E2E ended without a result: nothing was published; run the same command again",
            )
            return False
        self._step("e2e", report.FAILED, started, findings=red)
        self.run.item(
            "e2e-red",
            findings=red,
            run=self._again("fix: <what was fixed>"),
            message=(
                "E2E is red: nothing was published. Fix it with a new commit and the same command; when the cause "
                "is in the framework, fix it through dotsteward-contribute, whose contribute upgrade --carry "
                "keeps these commits, then run dotsteward apply again"
            ),
        )
        return False

    # --- publish ------------------------------------------------------------------------------

    def _publish(self) -> None:
        if not self.publish:
            return
        started = time.monotonic()
        if self.offline:
            self._step("publish", report.PARTIAL, started, detail="offline: the same command publishes later")
            return
        if self.commit == self.base:
            self._step("publish", report.OK, started, detail="already published")
            self.published = True
            return
        status = self._ds_quiet("txn", "publish", "--scope", "maintain", "--expected-base", self.base)
        if status == 0:
            self._step("publish", report.OK, started)
            self.published = True
            assert self.commit is not None
            self._track(self.commit)
            return
        outcome, tip, detail = publishing.fetch_tip(self.root, self.branch, _SCOPE)
        if outcome == publishing.NETWORK:
            self.offline = True
            self._step("publish", report.PARTIAL, started, detail="offline: the same command publishes later")
        elif outcome == publishing.OK and tip != self.base:
            self._step("publish", report.PENDING, started, detail="the remote moved")
            message = (
                "the remote moved (another machine, or a skill capture of this one): the commits stay here; the "
                "command takes the remote in, then the same apply proves the combined tree and publishes"
            )
            if self._changes():
                message = (
                    "the checkout has uncommitted changes, which a pull --rebase refuses: make them part of this "
                    "transaction with apply -m, or remove them, first; " + message
                )
            self.run.item(
                "publish-race",
                run=f"git -C {self.root} pull --rebase origin {self.branch} && {self._again()}",
                message=message,
            )
        else:
            self._step("publish", status, started)
            self.run.item(
                "publish-refused",
                message=f"txn publish or the remote refused the commits: {detail or 'see above'}",
            )

    # --- the end ------------------------------------------------------------------------------

    def _end(self) -> int:
        self.run.data.update(published=self.published)
        self.paths = self.run.write()
        for step in self.run.steps:
            if step["status"] != "ok":
                detail = step.get("detail") or (f"exit status {step['exit_status']}" if "exit_status" in step else "")
                word = _STEP_WORDS.get(step["status"], step["status"])
                _say("apply", f"{step['name']}: {word}" + (f" ({detail})" if detail else ""))
        if self.published:
            _say("apply", f"published {self.commit}")
        elif self.commit is not None and self.commit != self.base and self.run.exit_code == report.OK:
            missing = [] if self.activate else ["--activate"]
            missing += [] if self.publish else ["--publish"]
            _say("apply", f"the commit {self.commit[:12]} stays here: dotsteward apply {' '.join(missing)} goes on")
        _say("apply", f"{self.run.status}: report {self.paths.report}")
        for item in self.run.items:
            said = [str(item[key]) for key in ("message", "run") if item.get(key)]
            if item.get("findings"):
                said.append("checks: " + ", ".join(str(check) for check in item["findings"]))
            if item.get("log"):
                said.append(f"log: {item['log']}")
            _say("apply", f"{item['code']}: " + " -> ".join(said))
        if self.paths.review is not None:
            _say("apply", f"see {self.paths.review}")
        return EXIT_INTERRUPTED if self.interrupted else self.run.exit_code

    def document(self) -> dict[str, Any]:
        """The report as ``--json`` prints it."""
        assert self.paths is not None
        document: dict[str, Any] = json.loads(self.paths.report.read_text(encoding="utf-8"))
        document["report"] = str(self.paths.report)
        document["review"] = str(self.paths.review) if self.paths.review else None
        return document


# --- the command lines ------------------------------------------------------------------------


def _defaults(instance: config.Instance) -> tuple[bool, bool]:
    table = instance.config.get("maintain") or {}
    return bool(table.get("activate", False)), bool(table.get("publish", False))


def _apply_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward apply", description=_APPLY_DESCRIPTION)
    parser.add_argument("-m", "--message", dest="subject", metavar="SUBJECT", help="the conventional commit subject")
    activate = parser.add_mutually_exclusive_group()
    activate.add_argument("--activate", dest="activate", action="store_true", default=None, help="activate here")
    activate.add_argument("--no-activate", dest="activate", action="store_false", help="do not activate")
    publish = parser.add_mutually_exclusive_group()
    publish.add_argument("--publish", dest="publish", action="store_true", default=None, help="publish the commits")
    publish.add_argument("--no-publish", dest="publish", action="store_false", help="keep the commits here")
    parser.add_argument("--profile", help="the profile to activate (default: this machine's)")
    parser.add_argument("--json", action="store_true", help="print the report on standard output")
    return parser


def _begin_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward maintain", description=_BEGIN_DESCRIPTION)
    commands = parser.add_subparsers(dest="command", required=True, metavar="begin")
    begin = commands.add_parser("begin", description=_BEGIN_DESCRIPTION, help="open a maintain transaction")
    begin.add_argument("--profile", help="the profile of the preflight (default: this machine's)")
    begin.add_argument("--json", action="store_true", help="print one JSON document on standard output")
    return parser


def _load() -> tuple[config.Instance, str] | None:
    try:
        return config.load_instance(), config.required_state_root()
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return None


def _to_stderr(json_out: bool) -> int | None:
    """With --json everything else goes to standard error, of this process and its children."""
    if not json_out:
        return None
    document_out = os.dup(1)
    os.dup2(2, 1)
    return document_out


def _print_document(document_out: int | None, document: dict[str, Any]) -> None:
    if document_out is None:
        return
    with os.fdopen(document_out, "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main_apply(argv: Sequence[str] | None = None) -> int:
    options = _apply_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    if options.subject is not None and not _SUBJECT.match(options.subject):
        _error(f"the subject is not a conventional commit ({', '.join(context.CONVENTIONAL_TYPES)}): {options.subject}")
        return EXIT_USAGE
    terminal = firmware.on_terminal()
    document_out = _to_stderr(options.json)
    loaded = _load()
    if loaded is None:
        return report.FAILED
    instance, state_root = loaded
    activate, publish = _defaults(instance)
    activate = activate if options.activate is None else options.activate
    publish = publish if options.publish is None else options.publish
    changed = publishing.git(instance.root, "status", "--porcelain", "--untracked-files=normal").stdout.strip()
    if changed and not options.subject:
        _error('the checkout has changes: give the subject of their commit with -m "<type>: <summary>"')
        return EXIT_USAGE
    try:
        with locks.instance_lock("apply", state_root=state_root):
            run = Apply(instance, state_root, options.profile, options.subject, activate, publish, terminal)
            code = run.execute()
    except locks.LockBusy as busy:
        _error(str(busy))
        return report.FAILED
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    _print_document(document_out, run.document())
    return code


def main_maintain(argv: Sequence[str] | None = None) -> int:
    options = _begin_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    document_out = _to_stderr(options.json)
    loaded = _load()
    if loaded is None:
        return report.FAILED
    instance, state_root = loaded
    try:
        with locks.instance_lock("maintain", state_root=state_root):
            run = Begin(instance, state_root, options.profile)
            code = run.execute()
    except locks.LockBusy as busy:
        _error(str(busy))
        return report.FAILED
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    if run.refused is None:
        if document_out is None:
            run.say()
        else:
            _print_document(document_out, run.document())
    return code


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments[:1] == ["maintain"]:
        return main_maintain(arguments[1:])
    if arguments[:1] == ["apply"]:
        return main_apply(arguments[1:])
    _error("usage: python -m dotsteward_cli.apply apply|maintain ARG...")
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
