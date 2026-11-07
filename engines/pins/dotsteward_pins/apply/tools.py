"""The external programs of ``pins apply``. A failure is a ``GroupFailure``: it fails
the group that ran it, not the run."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from dotsteward_cli import config as ds_config
from dotsteward_cli import context

COMMAND_TIMEOUT = 300
BUILD_TIMEOUT = 3600
ERROR_LINES = 12
# What the documentation of the hashes calls the placeholder; `pins check` refuses
# it, so a value left behind cannot pass.
PLACEHOLDER = "sha256-" + "A" * 43 + "="
_GOT = re.compile(r"got:\s*(sha256-[A-Za-z0-9+/]+=*)")
_NIX = ("nix", "--extra-experimental-features", "nix-command flakes")


class GroupFailure(Exception):
    """A step of a group failed; the group restores what it touched."""


class Waits(Exception):
    """The group waits for a person or an agent: a review item, and the group restores
    what it touched."""

    def __init__(self, code: str, **fields: Any) -> None:
        super().__init__(code)
        self.code = code
        self.fields = fields


def nix_system() -> str:
    return context.nix_system("darwin" if sys.platform == "darwin" else "linux")


def _tail(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return "; ".join(lines[-ERROR_LINES:])


def _title(command: list[str]) -> str:
    """The start of a command for a message, without the options of nix."""
    if tuple(command[: len(_NIX)]) == _NIX:
        return " ".join(["nix", *command[len(_NIX) : len(_NIX) + 2]])
    return " ".join(command[:3])


class Tools:
    def __init__(self, root: Path) -> None:
        self.root = root

    def run(
        self,
        command: list[str],
        *,
        timeout: int = COMMAND_TIMEOUT,
        stdin: str | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Runs COMMAND and returns the result whatever its status; GroupFailure when
        it cannot run or takes too long."""
        environment = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        try:
            return subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout,
                input=stdin,
                stdin=subprocess.DEVNULL if stdin is None else None,
                cwd=cwd or self.root,
                env=environment,
                check=False,
            )
        except FileNotFoundError as error:
            raise GroupFailure(f"{command[0]} is not on PATH") from error
        except subprocess.TimeoutExpired as error:
            raise GroupFailure(f"{_title(command)} timed out after {timeout} seconds") from error

    def checked(self, command: list[str], **options: Any) -> str:
        result = self.run(command, **options)
        if result.returncode != 0:
            detail = _tail(result.stderr) or _tail(result.stdout) or f"exit status {result.returncode}"
            raise GroupFailure(f"{_title(command)} failed: {detail}")
        return result.stdout

    # -- nix --

    def nix(self, *arguments: str, timeout: int = COMMAND_TIMEOUT) -> str:
        return self.checked([*_NIX, *arguments], timeout=timeout)

    def flake_lock(self) -> None:
        self.nix("flake", "lock", str(self.root), timeout=BUILD_TIMEOUT)

    def framework_source(self) -> Path:
        """The source of the dotsteward input flake.lock holds."""
        text = self.nix("flake", "archive", "--json", "--dry-run", "--no-update-lock-file", str(self.root))
        try:
            return Path(json.loads(text)["inputs"]["dotsteward"]["path"])
        except (ValueError, KeyError, TypeError) as error:
            raise GroupFailure(f"nix flake archive does not name the framework source: {text[:200]!r}") from error

    def fake_hash_build(self, attribute: str) -> str:
        """Builds ATTRIBUTE of the instance, whose hash is the placeholder, and returns
        the hash Nix got. A stale hash would build the old source silently, which is
        why the placeholder is there at all."""
        target = f"{self.root}#{attribute}"
        arguments = ["build", "--no-link", "--no-update-lock-file", target]
        result = self.run([*_NIX, *arguments], timeout=BUILD_TIMEOUT)
        if result.returncode == 0:
            raise GroupFailure(f"{attribute} builds with the placeholder hash, so it does not use this field")
        found = _GOT.findall(result.stderr)
        if not found:
            raise GroupFailure(f"nix build {attribute} failed: {_tail(result.stderr)}")
        return str(found[-1])

    def nix_tool(self, tool: str, *command: str, stdin: str | None = None) -> str:
        """COMMAND with TOOL of the nixpkgs the instance locks on its PATH, so the
        result does not depend on what the machine has installed."""
        arguments = ["shell", "--inputs-from", str(self.root), f"nixpkgs#{tool}", "-c", *command]
        return self.checked([*_NIX, *arguments], timeout=BUILD_TIMEOUT, stdin=stdin)

    def prefetch(self, url: str) -> tuple[str, int]:
        """The hex SHA-256 and the size of the file at URL, downloaded by Nix."""
        text = self.nix("store", "prefetch-file", "--json", url, timeout=BUILD_TIMEOUT)
        try:
            document = json.loads(text)
            digest, path = document["hash"], document["storePath"]
        except (ValueError, KeyError, TypeError) as error:
            raise GroupFailure(f"nix store prefetch-file answered {text[:200]!r}") from error
        hexadecimal = self.nix("hash", "convert", "--hash-algo", "sha256", "--to", "base16", digest).strip()
        return hexadecimal, os.path.getsize(path)

    # -- git --

    def tag_objects(self, repository: str, tag: str) -> tuple[str, str | None] | None:
        """(commit, tag object or None for a lightweight tag) of TAG of a GitHub
        repository, None when it has no such tag."""
        url = f"https://github.com/{repository}"
        reference = f"refs/tags/{tag}"
        text = self.checked(["git", "ls-remote", url, reference, f"{reference}^{{}}"], timeout=60)
        refs = {}
        for line in text.splitlines():
            sha, _, name = line.partition("\t")
            refs[name] = sha
        if reference not in refs:
            return None
        peeled = refs.get(f"{reference}^{{}}")
        return (peeled, refs[reference]) if peeled else (refs[reference], None)

    def stage(self, paths: list[str]) -> None:
        """Nix does not see untracked files: the writer stages what it wrote, and only
        that. Outside a repository there is nothing to do."""
        if not paths:
            return
        inside = self.run(["git", "rev-parse", "--is-inside-work-tree"], timeout=60)
        if inside.returncode == 0 and inside.stdout.strip() == "true":
            self.checked(["git", "add", "--", *paths], timeout=60)

    # -- the framework's own commands --

    def dotsteward(self, *arguments: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        program = str(ds_config.FRAMEWORK_ROOT / "cli" / "dotsteward")
        return self.run([program, *arguments], timeout=BUILD_TIMEOUT, cwd=cwd)

    def generate(self, *flags: str) -> None:
        """Today's `dotsteward sync`: `dotsteward generate` once T1 lands."""
        result = self.dotsteward("--instance", str(self.root), "sync", *flags)
        if result.returncode != 0:
            raise GroupFailure(f"dotsteward sync failed: {_tail(result.stderr)}")
