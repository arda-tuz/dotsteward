"""What a command that puts other commands of this CLI in order shares: ``upgrade`` and ``apply``.

A run holds the instance lock of its caller and calls the commands of this CLI (gate, rebuild, e2e,
txn, install) as children: on the terminal, with their output kept, or quietly. A signal that ended
a child ends the run as well. Besides it knows the records those commands leave: which tree is
active on this machine, and why a gate could not judge a tree.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

from dotsteward_cli import config, machine, procs
from dotsteward_cli import publish as publishing

# 128 + SIGINT, SIGTERM, SIGHUP.
SIGNALLED = {130, 143, 129}
# A child killed from outside: 137 through a shell, a negative status straight from Python.
KILLED = 137
# What says that the gate could not judge the tree, rather than that the tree is red: in its own
# words or in its log. A red of these holds nothing.
GATE_LOCKED = "another gate is running"
ENVIRONMENT_MARKERS = (
    "No space left on device",
    "Cannot allocate memory",
    "Out of memory",
    "out of memory",
    "killed by signal 9",
)


class Runner:
    """The common part of a run: the instance, the CLI, git in the checkout and the records."""

    def __init__(self, instance: config.Instance, state_root: str, publish_scope: str) -> None:
        self.instance = instance
        self.root = instance.root
        self.state_root = state_root
        # The private ref of the fetches of this command: refs/dotsteward/<scope>/tip.
        self.publish_scope = publish_scope
        self.env = os.environ
        self.branch = str(instance.config["instance"]["branch"])
        self.profile: str | None = None
        self.offline = False
        self.framework_moved = False
        self.quiet_output = ""

    # --- the commands of this CLI ----------------------------------------------------------

    def _target(self) -> Path:
        """The tree the commands run on."""
        return self.root

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
        if status in SIGNALLED:
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
        if child.returncode in SIGNALLED:
            raise KeyboardInterrupt
        if child.returncode != 0:
            print("".join(others), end="", flush=True)
        return child.returncode

    # --- git in the checkout ---------------------------------------------------------------

    def _git(self, *arguments: str) -> publishing.GitResult:
        """Git in the checkout."""
        return publishing.git(self.root, *arguments)

    def _head(self) -> str:
        return self._git("rev-parse", "HEAD").stdout.strip()

    def _tree_of(self, where: Path) -> str:
        return publishing.git(where, "rev-parse", "HEAD^{tree}").stdout.strip()

    def _checkout_clean(self) -> bool:
        return not self._git("status", "--porcelain", "--untracked-files=normal").stdout.strip()

    def _track(self, commit: str) -> None:
        """The tracking ref of the checkout says what the remote has, so `git status` does not count
        a published commit as one of its own."""
        tracking = f"refs/remotes/origin/{self.branch}"
        if self._git("rev-parse", "--verify", "--quiet", tracking).code == 0:
            self._git("update-ref", tracking, commit)

    # --- the records of the commands -------------------------------------------------------

    def _activation(self) -> dict[str, Any]:
        path = Path(self.state_root) / "current" / "activation.json"
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return record if isinstance(record, dict) else {}

    def _is_active(self, where: Path) -> bool:
        """The tree of WHERE is the active generation of this machine, for the profile of the run,
        built from WHERE."""
        active = self._activation()
        return (
            active.get("tree_oid") == self._tree_of(where)
            and active.get("profile") == self.profile
            and active.get("tags_sha256") in (None, machine.effective(self.instance, self.env)["nix_tags_sha256"])
            and os.path.realpath(str(active.get("root"))) == os.path.realpath(where)
        )

    def _gate_environment(self, started: float) -> str | None:
        """Why the gate could not judge the tree, or None when its no is about the tree: another gate,
        a step that never reached the tree, a full disk or no memory in its log, the network gone."""
        if GATE_LOCKED in self.quiet_output:
            return GATE_LOCKED
        log = Path(self.state_root) / "update" / "validate.log"
        try:
            # A log of an earlier gate says nothing about this one.
            text = log.read_text(encoding="utf-8", errors="replace") if log.stat().st_mtime >= started - 1 else ""
        except OSError:
            text = ""
        steps = re.findall(r"^== ([a-z0-9-]+):", text, re.MULTILINE)
        if steps and steps[-1] == "preflight":
            return "the preflight of the gate failed (the binary cache or the free space of the store)"
        for marker in ENVIRONMENT_MARKERS:
            if marker in text or marker in self.quiet_output:
                return marker
        outcome, _, _ = publishing.fetch_tip(self.root, self.branch, self.publish_scope)
        if outcome == publishing.NETWORK:
            self.offline = True
            return "the network went away during the gate"
        return None
