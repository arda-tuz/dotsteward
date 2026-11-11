"""``dotsteward maintain begin`` and ``dotsteward apply``: a maintain transaction (docs/apply.md).

``maintain begin`` opens it: the guards of the checkout, a fast-forward when the checkout is only
behind the remote, the read-only preflight of the profile, ``txn prepare`` in the maintain scope
and the settings status, and the questions to put to the user before anything is written.

``apply`` finishes it in one command and a fixed order: everything is staged, ``generate`` writes
the mirrors of the tree into the same commit, the gate proves the tree in the maintain scope, the
commit carries the trace line of this machine; activated, the system-level components an
adopt-mode profile needs come in, ``rebuild --switch`` activates the committed tree and E2E checks
it against the base; published, ``txn publish`` pushes it, which after an activation needs that
E2E. The checkout is the transaction: apply commits there and never cleans, stashes or amends;
one reset takes back the commit it just made when a commit hook changed its tree away from the
proven one, and keeps the changes staged. Like ``upgrade`` there is no journal and no resume: every
run works out again what is left. The gate answers from its memo for a tree it proved, a tree that
is active is not rebuilt, a passed E2E of the active tree with the repository checks is not run
again and a published commit is not pushed again, so the same command finishes what a red step, a
missing network or a person's sudo step left.

Another machine that published first (design: the push race) costs a replay, never a merge in the
checkout: the commits after the base are picked onto the new tip in a clone of their own under
``<state>/apply/replay``, a mirror both sides changed is taken from the tip and ``flake.lock`` too
(``nix flake lock`` adds what is missing), ``generate`` folds the mirrors into the top commit, and
only a finished replay moves the checkout, by ``git reset --keep``. Then the gate, the activation
and E2E run again against the new base, and the push again, at most three times in a run. A change
of the same lines on both sides stops it with the checkout as it was (``publish-conflict``).
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, context, doctor, firmware, locks, machine, report, runner, writers
from dotsteward_cli import publish as publishing
from dotsteward_cli.host import commit_identity, commit_message
from dotsteward_cli.upgrade import consumer, facts

EXIT_USAGE = 2
EXIT_INTERRUPTED = 130
# The private ref of the fetches of a maintain transaction: refs/dotsteward/apply/tip.
_SCOPE = "apply"
_SUBJECT = re.compile(r"^(" + "|".join(context.CONVENTIONAL_TYPES) + r")(\([a-z0-9._/-]+\))?!?: .+")
# The methods a rebuild of an adopt-mode profile never installs.
_SYSTEM_LEVEL = {"linux": ("deb", "system"), "darwin": ("app-archive",)}
_SETTINGS_WAIT = {"local-changed", "local-deleted"}
_STEP_WORDS = {"pending": "waits for you", "partial": "skipped, no network", "failed": "failed"}
_COMMIT_SECONDS = 600
# What a replay takes from the tip when both sides changed it: values of the tree, made again.
_DERIVED = (".dotsteward/",)
_FLAKE_LOCK = "flake.lock"
_REPLAYED_REF = "refs/dotsteward/apply/replayed"
_WRITER_PATH = re.compile(r"writer-class: (\S+): only ")
# txn publish: the remote moved since the base, and no network.
_TXN_RACE = 3
_TXN_OFFLINE = 6

_APPLY_DESCRIPTION = (
    "Finishes a maintain transaction in one command: stages every change of the checkout, regenerates the "
    "mirrors, runs the gate in the maintain scope, commits with SUBJECT and the trace line of this machine, "
    "then with --activate "
    "installs the system-level components an adopt-mode profile needs, runs rebuild --switch and E2E "
    "against the base, and with --publish runs txn publish and records the state of this machine on its state "
    "branch; when another machine published first, it moves "
    "the commits onto the new tip, proves and activates them again and pushes again, three times at most. "
    "[maintain] activate and publish of "
    "workstation.toml are the defaults (both false). Run the same command again after a fix or a sudo "
    "step: it does what is left. Exit status: 0 done, 1 a refusal or a red step, 2 usage error, 3 a sudo "
    "step or a person waits (review.json: a change of the same lines here and on the remote, or a remote "
    "that kept moving), 6 no network: the push waits, 130 interrupted."
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

    def _nonconventional(self, base: str) -> list[tuple[str, str]]:
        """The commits after BASE whose subject txn publish refuses: (oid, subject)."""
        listing = self._git("log", "--reverse", "--format=%H%x00%s", f"{base}..HEAD").stdout
        found = []
        for line in listing.splitlines():
            oid, _, subject = line.partition("\0")
            if oid and not _SUBJECT.fullmatch(subject):
                found.append((oid, subject))
        return found

    def _fold_command(self, base: str) -> str:
        """The way out for such commits: their changes stay, as changes of the transaction."""
        return f"git -C {self.root} reset --soft {base}"

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
        bad = self._nonconventional(self.tip)
        if bad:
            self.ask.append(
                {
                    "code": "nonconventional-commits",
                    "commits": [oid for oid, _ in bad],
                    "subjects": [subject for _, subject in bad],
                    "run": self._fold_command(self.tip),
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
                f"the checkout and the remote diverged ({len(ahead)} local, {len(behind)} remote commits): when the "
                "local ones are an earlier dotsteward apply that lost the race of its push, the same apply moves them "
                f"onto the tip; else run git -C {self.root} pull --rebase, then dotsteward maintain begin"
            )
        if behind:
            done = self._git("merge", "--quiet", "--ff-only", self.tip)
            if done.code != 0:
                paths = [line.strip() for line in done.stderr.splitlines() if line.startswith("\t")]
                if paths:
                    return (
                        f"the fast-forward to {self.tip[:12]} would overwrite local changes of {', '.join(paths)}: "
                        "keep a copy of those changes outside the checkout and undo them, run dotsteward maintain "
                        "begin, then make them again on the new tip"
                    )
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
            "refused": self.refused,
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
        self.replayed = False
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
            committed = (
                self._start()
                and self._stage()
                and self._generate()
                and self._not_held()
                and self._gate()
                and self._commit()
            )
            if committed and self.base != self.tip and not self.offline:
                # A run that stopped after a lost race: the commits move onto the tip first.
                committed = self._move_on()
            if committed and self._activated():
                self._publish()
                if self.published:
                    self._record_state()
        except KeyboardInterrupt:
            self.interrupted = True
            self.run.mark_interrupted(self.run.interrupted or ["SIGINT"])
            self.run.step("interrupted", report.FAILED, detail="the same command goes on from here")
        return self._end()

    def _not_held(self) -> bool:
        """A consumer never activates the shared lock that went red here (T19): the staged tree with
        that lock is refused before the gate, and stays staged."""
        if not self.activate:
            return True
        tree = self._git("write-tree").stdout.strip()
        reason = consumer.refusal(self.root, self.state_root, tree, facts.role(self.instance, self.name))
        if reason is None:
            return True
        return self._refuse(f"{reason}; --no-activate commits it without activating it here")

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
            # Commits of an earlier run that lost the race: they move onto the tip after the gate.
            self.base = self._git("merge-base", "HEAD", self.tip).stdout.strip()
            if not self.base:
                return self._refuse(f"the checkout and the remote {self.tip[:12]} have no commit in common")
        else:
            self.base = self.tip
        bad = self._nonconventional(self.base)
        if bad:
            said = ", ".join(f"{oid[:12]} {subject!r}" for oid, subject in bad)
            self.run.item(
                "nonconventional-commits",
                commits=[oid for oid, _ in bad],
                run=self._fold_command(self.base),
                message="txn publish refuses these subjects: keep their changes with the command, then apply -m",
            )
            return self._refuse(
                f"unpublished commits without a conventional subject, which txn publish refuses: {said}; keep their "
                f"changes as changes of this transaction with {self._fold_command(self.base)}, then run dotsteward "
                'apply -m "<type>: <summary>"'
            )
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

    def _generate(self) -> bool:
        """The mirrors of the tree and the values derived from it, in the same commit as the change."""
        started = time.monotonic()
        status = self._ds_quiet("generate")
        if status != 0:
            self._step("generate", report.FAILED, started, exit_status=status)
            self.run.item(
                "generate-failed",
                run=self._again(self.subject),
                message="dotsteward generate failed: nothing was committed; fix it and run the same command again",
            )
            return False
        added = self._git("add", "-A")
        if added.code != 0:
            self._step("generate", report.FAILED, started, detail=added.stderr.strip())
            return False
        if self._staged() and not self.subject:
            self._step("generate", report.FAILED, started, detail="the mirrors changed")
            return self._refuse(
                'generate changed the mirrors: give the subject of their commit with -m "<type>: <summary>"'
            )
        self._step("generate", report.OK, started)
        return True

    def _gate(self) -> bool:
        started = time.monotonic()
        wall = time.time()
        _say("apply", "the gate proves the tree")
        status = self._ds_quiet("gate", "--scope", "maintain", "--expected-base", self.base)
        log = str(Path(self.state_root) / "update" / "validate.log")
        if status == 0:
            self._step("gate", report.OK, started)
            return True
        if f"{writers.CODE}: " in self.quiet_output:
            return self._writer_class(started)
        environment = self._gate_environment(wall)
        if environment is not None:
            network = environment.startswith("the network")
            self._step("gate", report.PARTIAL if network else report.FAILED, started, detail=environment)
            self.run.item(
                "gate-failed",
                log=log,
                environment=environment,
                run=self._again(self.subject),
                message=f"the gate could not judge the tree: {environment}; {self._nothing_new()}",
            )
            return False
        self._step("gate", status, started)
        self.run.item(
            "gate-failed",
            log=log,
            run=self._again(self.subject),
            message=f"the gate refused the tree: {self._nothing_new()}; fix it and run the same command again",
        )
        return False

    def _nothing_new(self) -> str:
        """What a red gate left: nothing new, or the commits a replay moved, which wait here."""
        if self.replayed:
            return f"the commits moved onto {self.base[:12]} and wait here, nothing was pushed"
        return "nothing was committed"

    def _writer_class(self, started: float) -> bool:
        """The tree changes what another machine writes: nothing is committed."""
        paths = sorted(set(_WRITER_PATH.findall(self.quiet_output)))
        producer = writers.producer_of(self.root, self.base)
        pins = [path for path in paths if not path.startswith(f"{machine.HOSTS_DIR}/")]
        self._step("gate", report.FAILED, started, detail=writers.CODE)
        _error(f"{writers.CODE}: this machine does not write {', '.join(paths)}: {self._nothing_new()}")
        if pins:
            self.run.item(
                writers.CODE,
                paths=paths,
                producer=producer,
                run=f"dotsteward host producer {self.name}",
                message=(
                    f"{producer} is the producer: only it moves a pin the base has; take these changes back and let "
                    "it move them, or make this machine the producer"
                ),
            )
        else:
            self.run.item(
                writers.CODE, paths=paths, message="only the machine of a host file writes it: take these changes back"
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

    def _proved(self, step: str, started: float) -> bool:
        """The tree of HEAD is the tree the gate proved."""
        if self._tree_of(self.root) == self._validated_tree():
            return True
        self._step(step, report.FAILED, started, detail="the committed tree is not the tree the gate proved")
        self.run.item(
            "tree-changed",
            run=self._again(),
            message="the tree changed after the gate (a hook?): the gate proves it again on the next run",
        )
        return False

    # --- activation ---------------------------------------------------------------------------

    def _activated(self) -> bool:
        return not self.activate or (self._install() and self._rebuild() and self._e2e())

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
        methods = _SYSTEM_LEVEL.get(config.runtime_platform(self.env), ())
        before = self._mirror_at(self.base)
        names = []
        for component in facts.active_components(self.instance, self.profile, self.env):
            name = str(component.get("name"))
            modes = component.get("modes") or {}
            if component.get("method") not in methods or modes.get(self.profile) != "adopt":
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
        for attempt in range(1, publishing.ATTEMPTS + 1):
            status = self._ds_quiet("txn", "publish", "--scope", "maintain", "--expected-base", self.base)
            if status == 0:
                self._step("publish", report.OK, started)
                self.published = True
                self.commit = self._head()
                self.run.data.update(commit=self.commit)
                self._track(self.commit)
                return
            if status == _TXN_OFFLINE:
                self.offline = True
                self._step("publish", report.PARTIAL, started, detail="offline: the same command publishes later")
                return
            if status != _TXN_RACE:
                said = [line for line in self.quiet_output.splitlines() if line.startswith("[dotsteward] ERROR: ")]
                reason = said[-1].removeprefix("[dotsteward] ERROR: ") if said else "see above"
                self._step("publish", status, started, detail=reason)
                self.run.item("publish-refused", message=f"txn publish or the remote refused the commits: {reason}")
                return
            if attempt == publishing.ATTEMPTS:
                break
            _say("apply", "another machine published first: the commits move onto its tip")
            publishing.backoff(attempt)
            why = self._fetch()
            if why is not None:
                self._step("publish", report.FAILED, started, detail=why)
                return
            if self.offline:
                self._step("publish", report.PARTIAL, started, detail="offline: the same command publishes later")
                return
            if not (self._move_on() and self._activated()):
                return
            started = time.monotonic()
        self._step("publish", report.PENDING, started, detail="other machines kept publishing")
        self.run.item(
            "publish-race",
            tip=self.tip,
            run=self._again(),
            message=(
                f"the remote moved {publishing.ATTEMPTS} times (another machine, or a skill capture of this one) while "
                "this one proved its commits: they stay here; the same command moves them onto the new tip and "
                "publishes them"
            ),
        )

    def _record_state(self) -> None:
        """What this machine observes, on its state branch: the intent it publishes and the state
        of the machine travel together. A record that cannot be made is a note, never a red run:
        the commit is published, and the next record or state push catches up."""
        from dotsteward_cli import state as state_branch

        started = time.monotonic()
        detail = None
        code = report.OK
        if not self.activate:
            # The state of this machine is what is active here: a tree it did not activate changed
            # nothing of it. The next activation records.
            detail = "not recorded: nothing was activated here"
        else:
            try:
                code = state_branch.record(self.instance, self.env, by="apply")
            except KeyboardInterrupt:
                detail = "not recorded: interrupted (dotsteward state record)"
            except Exception as why:  # the commit is published: no failure of the record turns it red
                detail = f"not recorded: {why or type(why).__name__}"
        if detail is None:
            if code == report.PARTIAL:
                detail = "recorded here; the push waits for the network (dotsteward state push)"
            elif code != report.OK:
                detail = f"recorded here; the push did not land (exit {code}, dotsteward state push)"
        self._step("state", report.OK, started, **({"detail": detail} if detail else {}))
        if detail:
            _say("apply", f"state: {detail}")

    # --- the replay ---------------------------------------------------------------------------

    def _move_on(self) -> bool:
        """The commits after the base onto the tip, proved by the gate."""
        started = time.monotonic()
        return self._replay() and self._gate() and self._proved("gate", started)

    def _replay(self) -> bool:
        """The commits of BASE..HEAD picked onto the tip in a clone of their own; the checkout moves
        only when that is done. False: the checkout is as it was."""
        started = time.monotonic()
        tip = self.tip
        if publishing.is_ancestor(self.root, "HEAD", tip):
            # The commits are on the remote already: a push whose answer got lost.
            return self._land(tip, started, detail=f"already on {tip[:12]}")
        work = Path(self.state_root) / "apply" / "replay"
        try:
            replayed = self._pick(work, tip, started)
            if replayed is None:
                return False
            fetched = self._git("fetch", "--quiet", "--no-tags", "--refmap=", str(work), f"+HEAD:{_REPLAYED_REF}")
            if fetched.code != 0:
                return self._replay_failed(started, f"git fetch from the replay failed: {fetched.stderr.strip()}")
            return self._land(replayed, started, detail=f"onto {tip[:12]}")
        finally:
            shutil.rmtree(work, ignore_errors=True)
            self._git("update-ref", "-d", _REPLAYED_REF)

    def _land(self, commit: str, started: float, *, detail: str) -> bool:
        moved = self._git("reset", "--quiet", "--keep", commit)
        if moved.code != 0:
            return self._replay_failed(started, f"git reset --keep in the checkout failed: {moved.stderr.strip()}")
        self.base = self.tip
        self.commit = commit
        self.replayed = True
        self.run.data.update(base=self.base, commit=commit)
        self._step("replay", report.OK, started, detail=detail)
        _say("apply", f"the commits are on {self.tip[:12]} now: {commit[:12]}")
        return True

    def _replay_failed(self, started: float, why: str) -> bool:
        self._step("replay", report.FAILED, started, detail=why)
        self.run.item("replay-failed", run=self._again(), message=f"the commits could not move onto the tip: {why}")
        return False

    def _pick(self, work: Path, tip: str, started: float) -> str | None:
        """The replayed HEAD of the clone WORK, or None when it stopped (recorded)."""
        shutil.rmtree(work, ignore_errors=True)
        atomic.make_private_dirs(work.parent)
        commits = self._git("rev-list", "--reverse", "--topo-order", f"{self.base}..HEAD").stdout.split()
        merges = self._git("rev-list", "--merges", f"{self.base}..HEAD").stdout.split()
        if merges:
            self._merge_waits(merges, started)
            return None
        made = self._git("clone", "--quiet", "--shared", "--no-checkout", str(self.root), str(work))
        if made.code != 0:
            self._replay_failed(started, f"git clone failed: {made.stderr.strip()}")
            return None
        self._clone_config(work)
        checked = publishing.git(work, "checkout", "--quiet", "--detach", tip)
        if checked.code != 0:
            self._replay_failed(started, f"git checkout of the tip failed: {checked.stderr.strip()}")
            return None
        identity = commit_identity(self.root, "HEAD")
        lock_taken = False
        for commit in commits:
            # A commit whose change the tip has already stays, empty: no commit of the person goes.
            picked = publishing.git(
                work, *identity, "cherry-pick", "--allow-empty", "--keep-redundant-commits", commit, env={"TZ": "UTC"}
            )
            if picked.code == 0:
                continue
            unmerged = publishing.git(work, "diff", "--name-only", "--diff-filter=U", "-z").stdout.split("\0")[:-1]
            if not unmerged and self._keep_empty(work, identity):
                continue
            others = [path for path in unmerged if not (path.startswith(_DERIVED) or path == _FLAKE_LOCK)]
            if _FLAKE_LOCK in unmerged and not self._lock_added_to(commit):
                # This commit moved a pin of its parent's lock: taking the tip's lock would drop it.
                others.append(_FLAKE_LOCK)
            if not unmerged or others:
                publishing.git(work, "cherry-pick", "--abort")
                if not unmerged:
                    self._replay_failed(
                        started, f"git cherry-pick {commit[:12]} failed: {picked.stderr.strip()[-400:]}"
                    )
                    return None
                self._conflict(others, started)
                return None
            for path in unmerged:
                # The tip's side: a value of the tree, made again below.
                if publishing.git(work, "checkout", "--ours", "--", path).code != 0:
                    publishing.git(work, "rm", "--quiet", "--cached", "--ignore-unmatch", "--", path)
                    with contextlib.suppress(FileNotFoundError):
                        (work / path).unlink()
                else:
                    publishing.git(work, "add", "--", path)
            lock_taken = lock_taken or _FLAKE_LOCK in unmerged
            done = publishing.git(
                work, *identity, "-c", "core.editor=true", "cherry-pick", "--continue", env={"TZ": "UTC"}
            )
            if done.code != 0 and not self._keep_empty(work, identity):
                publishing.git(work, "cherry-pick", "--abort")
                self._replay_failed(started, f"git cherry-pick {commit[:12]} failed: {done.stderr.strip()[-400:]}")
                return None
        if lock_taken and not self._lock_flake(work, started):
            return None
        return self._fold(work, started)

    @staticmethod
    def _keep_empty(work: Path, identity: Sequence[str]) -> bool:
        """A pick that stopped because nothing of it is left is committed empty, with its message and
        author; True when it was."""
        if publishing.git(work, "diff", "--cached", "--quiet", "HEAD").code != 0:
            return False
        made = publishing.git(
            work, *identity, "commit", "--quiet", "--allow-empty", "-C", "CHERRY_PICK_HEAD", env={"TZ": "UTC"}
        )
        return made.code == 0

    def _lock_added_to(self, commit: str) -> bool:
        """COMMIT only added to the flake.lock of its parent: no value the parent had moved or went."""

        def lock_at(revision: str) -> Any:
            shown = self._git("show", f"{revision}:{_FLAKE_LOCK}")
            if shown.code != 0:
                return {}
            try:
                return json.loads(shown.stdout)
            except ValueError:
                return None

        before, after = lock_at(f"{commit}^"), lock_at(commit)
        return before is not None and after is not None and not writers.moved_values(before, after)

    def _merge_waits(self, merges: Sequence[str], started: float) -> None:
        self._step("replay", report.PENDING, started, detail="a merge commit among the commits")
        self.run.item(
            "replay-merge",
            commits=list(merges),
            tip=self.tip,
            run=f"git -C {self.root} pull --rebase origin {self.branch} && {self._again()}",
            message=(
                "a merge commit cannot move onto the tip by itself: nothing was pushed and the checkout is as it was; "
                "the command takes the remote in and lines the commits up, then the same apply publishes them"
            ),
        )

    def _conflict(self, paths: Sequence[str], started: float) -> None:
        self._step("replay", report.PENDING, started, detail=f"the same lines changed on {self.tip[:12]}")
        message = (
            f"another machine changed the same lines of {', '.join(paths)}: nothing was pushed and the checkout "
            "is as it was; the command takes the remote in for you to settle them, then the same apply proves the "
            "combined tree and publishes"
        )
        if self._changes():
            message = (
                "the checkout has uncommitted changes, which a pull --rebase refuses: make them part of this "
                "transaction with apply -m, or remove them, first; " + message
            )
        self.run.item(
            "publish-conflict",
            paths=list(paths),
            tip=self.tip,
            run=f"git -C {self.root} pull --rebase origin {self.branch} && {self._again()}",
            message=message,
        )

    def _lock_flake(self, work: Path, started: float) -> bool:
        """flake.lock of the tip, and what this tree adds to it: nix flake lock only adds what is missing."""
        locked = subprocess.run(
            [
                doctor.find_nix(self.env) or "nix",
                "--extra-experimental-features",
                "nix-command flakes",
                "flake",
                "lock",
            ],
            cwd=work,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
        if locked.returncode != 0:
            self._replay_failed(started, f"nix flake lock failed: {locked.stderr.strip()[-400:]}")
            return False
        return True

    def _fold(self, work: Path, started: float) -> str | None:
        """generate in the clone; what it changes goes into the top commit, which keeps its author,
        dates and message. The replayed HEAD, or None."""
        argv = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(work), "generate"]
        generated = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
        if generated.returncode in runner.SIGNALLED:
            raise KeyboardInterrupt
        if generated.returncode != 0:
            self._replay_failed(started, f"dotsteward generate failed: {generated.stderr.strip()[-400:]}")
            return None
        head = publishing.git(work, "rev-parse", "HEAD").stdout.strip()
        publishing.git(work, "add", "-A")
        tree = publishing.git(work, "write-tree").stdout.strip()
        if tree == publishing.git(work, "rev-parse", "HEAD^{tree}").stdout.strip():
            return head
        folded = publishing.rewrite(work, head, tree=tree)
        publishing.git(work, "update-ref", "HEAD", folded, head)
        return folded

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
    if options.subject is not None and ("\n" in options.subject or "\r" in options.subject):
        _error("the subject is one line: the commit message is the subject and the trace line of this machine")
        return EXIT_USAGE
    if options.subject is not None and not _SUBJECT.fullmatch(options.subject):
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
    if document_out is not None:
        _print_document(document_out, run.document())
    elif run.refused is None:
        run.say()
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
