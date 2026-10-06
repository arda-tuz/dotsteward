"""The instance the engine works on: discovery, configuration, lock files,
manifest mirrors and the two external programs it may call (git, nix).

Discovery (SPEC 6.1): ``--instance`` > ``DOTSTEWARD_INSTANCE`` >
(``DOTFILES_ROOT`` with ``[compat] legacy_env``) > the nearest
``workstation.toml`` above the working directory, through the shared
configuration reader ``dotsteward_cli.config``.

Configuration used: ``[pins] versions_lock`` and ``excluded_flake_inputs``,
``[skills] lock`` and ``vendor_dir``, ``[compat] repo_owned_revision`` and
``[nix] systems``.

Rules: the ``pins.rules`` (and ``pins.latest``) of the committed manifest
mirror ``.dotsteward/manifest.<system>.json`` of every system in
``[nix] systems``, united in order; an entry repeated by several systems
counts once. A missing mirror is an error (run ``dotsteward sync``), never
an empty rule set.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import config as ds_config

from .lockfile import SKILLS, VERSIONS, Locks, load_json

MANIFEST_SCHEMA_VERSION = 1
REPO_OWNED_REVISION = "same-as-instance-checkout"
NIX_TIMEOUT_SECONDS = 900
# The generated .dotsteward/ mirrors (the names cli/commands/sync.sh writes).
MIRROR_PATH = re.compile(r"\.dotsteward/(manifest\.[A-Za-z0-9_-]+\.json|stage0\.[a-z]+\.env)")


class EngineError(Exception):
    """An error that stops the command with exit status 2."""

    def __init__(self, *messages: str) -> None:
        super().__init__("\n".join(messages))
        self.messages = list(messages)


class Refusal(Exception):
    """A refusal the user can resolve; exit status 1."""

    def __init__(self, *messages: str) -> None:
        super().__init__("\n".join(messages))
        self.messages = list(messages)


@dataclass(frozen=True)
class Declaration:
    """One manifest entry with the mirror it came from (for messages)."""

    source: str
    index: int
    data: Mapping[str, Any]


@dataclass
class Instance:
    root: Path
    config: dict[str, Any]
    versions_label: str
    skills_label: str
    vendor_dir: str
    systems: list[str]
    excluded_flake_inputs: list[str]
    repo_owned_revisions: tuple[str, ...]
    _manifests: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def versions_path(self) -> Path:
        return self.root / self.versions_label

    @property
    def skills_path(self) -> Path:
        return self.root / self.skills_label

    def path(self, relative: str) -> Path:
        return self.root / relative

    def relative(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.root))
        except ValueError:
            return str(path)

    # -- lock files --

    def load_locks(self) -> Locks:
        """Both lock documents; the skills lock may be absent."""
        locks = Locks(labels={VERSIONS: self.versions_label, SKILLS: self.skills_label})
        try:
            locks.documents[VERSIONS] = load_json(self.versions_path)
        except (OSError, ValueError) as error:
            raise EngineError(f"cannot read {self.versions_label}: {_reason(error)}") from error
        try:
            locks.documents[SKILLS] = load_json(self.skills_path)
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as error:
            raise EngineError(f"cannot read {self.skills_label}: {_reason(error)}") from error
        return locks

    # -- manifest mirrors --

    def manifest(self, system: str) -> dict[str, Any]:
        if system not in self._manifests:
            label = f".dotsteward/manifest.{system}.json"
            path = self.root / label
            if not path.is_file():
                raise EngineError(f"missing manifest mirror {label}; run 'dotsteward sync'")
            try:
                document = load_json(path)
            except ValueError as error:
                raise EngineError(f"{label}: invalid JSON ({error})") from error
            except OSError as error:
                raise EngineError(f"cannot read {label}: {_reason(error)}") from error
            if not isinstance(document, dict):
                raise EngineError(f"{label}: expected a JSON object")
            version = document.get("schema_version")
            if version != MANIFEST_SCHEMA_VERSION:
                raise EngineError(f"{label}: unsupported schema_version {version!r}")
            self._manifests[system] = document
        return self._manifests[system]

    def declarations(self, section: str) -> list[Declaration]:
        """The pins.<section> entries ("rules" or "latest") of every
        system's mirror, united in order."""
        seen: set[str] = set()
        result: list[Declaration] = []
        for system in self.systems:
            label = f".dotsteward/manifest.{system}.json"
            pins = self.manifest(system).get("pins")
            entries = pins.get(section) if isinstance(pins, dict) else None
            if not isinstance(entries, list):
                raise EngineError(f"{label}: pins.{section} is not a list")
            for index, entry in enumerate(entries, start=1):
                if not isinstance(entry, dict):
                    raise EngineError(f"{label}: pins.{section} entry {index} is not an object")
                key = json.dumps(entry, sort_keys=True)
                if key in seen:
                    continue
                seen.add(key)
                result.append(Declaration(label, index, entry))
        return result

    # -- external programs --

    def refuse_untracked(self) -> None:
        """Nix evaluates the git-visible tree: untracked, not ignored files
        would silently be missing, so they are refused (SPEC 6.3).

        Untracked generated mirrors are not refused: they are outputs of the
        evaluation that ``dotsteward sync`` may have just written, the
        evaluated attributes never read them, and this engine reads them from
        disk."""
        try:
            inside = subprocess.run(
                ["git", "-C", str(self.root), "rev-parse", "--is-inside-work-tree"],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            return
        if inside.returncode != 0 or inside.stdout.strip() != "true":
            return
        listed = subprocess.run(
            ["git", "-C", str(self.root), "ls-files", "-z", "--others", "--exclude-standard"],
            capture_output=True,
            check=False,
        )
        if listed.returncode != 0:
            raise EngineError(f"git ls-files failed: {listed.stderr.decode(errors='replace').strip()}")
        files = [os.fsdecode(name) for name in listed.stdout.split(b"\0") if name]
        files = [name for name in files if not MIRROR_PATH.fullmatch(name)]
        if files:
            raise Refusal(f"Nix does not see untracked files; run 'git add -A' first: {' '.join(files)}")

    def nix_eval(self, attribute: str) -> Any:
        """``nix eval --json --no-update-lock-file <root>#<attribute>``; with
        a framework override (``DOTSTEWARD_FRAMEWORK_OVERRIDE``, set by the
        gate for its steps) the dotsteward input is replaced in memory."""
        command = [
            "nix",
            "--extra-experimental-features",
            "nix-command flakes",
            "eval",
            "--json",
            "--no-update-lock-file",
            f"{self.root}#{attribute}",
        ]
        override = os.environ.get("DOTSTEWARD_FRAMEWORK_OVERRIDE", "")
        if override:
            command += ["--override-input", "dotsteward", override, "--no-write-lock-file"]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=NIX_TIMEOUT_SECONDS, check=False)
        except FileNotFoundError as error:
            raise EngineError("nix is not on PATH; --nix needs Nix (run ./bootstrap.sh first)") from error
        except subprocess.TimeoutExpired as error:
            raise EngineError(f"nix eval of {attribute} timed out after {NIX_TIMEOUT_SECONDS} seconds") from error
        if result.returncode != 0:
            detail = result.stderr.strip()
            suffix = f": {detail}" if detail else ""
            raise EngineError(f"nix eval of {attribute} failed (exit {result.returncode}){suffix}")
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise EngineError(f"nix eval of {attribute} printed invalid JSON ({error})") from error


def _reason(error: BaseException) -> str:
    if isinstance(error, OSError):
        return error.strerror or str(error)
    return str(error)


def load(explicit: str | None = None) -> Instance:
    """Discovers and loads the instance; EngineError when there is none or
    its configuration is invalid."""
    try:
        loaded = ds_config.load_instance(explicit)
    except ds_config.DotstewardError as error:
        raise EngineError(*(f"{error.prefix}{message}" for message in error.messages)) from error
    cfg = loaded.config
    revisions = [REPO_OWNED_REVISION]
    extra = cfg.get("compat", {}).get("repo_owned_revision")
    if isinstance(extra, str) and extra and extra not in revisions:
        revisions.append(extra)
    return Instance(
        root=loaded.root,
        config=cfg,
        versions_label=cfg["pins"]["versions_lock"],
        skills_label=cfg["skills"]["lock"],
        vendor_dir=cfg["skills"]["vendor_dir"],
        systems=list(cfg["nix"]["systems"]),
        excluded_flake_inputs=list(cfg["pins"]["excluded_flake_inputs"]),
        repo_owned_revisions=tuple(revisions),
    )
