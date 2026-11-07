"""T7-b: plugin marketplaces update themselves; `upgrade` only looks at what they did.

Nothing here starts an agent, updates a marketplace or changes ``autoUpdate``. Every installed
plugin tree of the agents' caches gets a digest; a tree that is new or changed since
``<state>/plugins/scan.json`` is scanned where it lies. The first run only learns what is there. A
finding is a review item and nothing is rolled back: the marketplace is yours.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config

_FILE = Path("plugins") / "scan.json"
SCHEMA_VERSION = 1


def _roots(env: Mapping[str, str]) -> list[tuple[str, Path]]:
    home = Path(env.get("HOME", "~")).expanduser()
    claude = Path(env.get("CLAUDE_CONFIG_DIR") or home / ".claude")
    codex = Path(env.get("CODEX_HOME") or home / ".codex")
    return [("claude", claude / "plugins" / "cache"), ("codex", codex / "plugins" / "cache")]


def _digest(tree: Path) -> str:
    digest = hashlib.sha256()
    for directory, _, files in sorted(os.walk(tree)):
        for name in sorted(files):
            path = Path(directory) / name
            digest.update(str(path.relative_to(tree)).encode())
            try:
                if path.is_symlink():
                    digest.update(os.readlink(path).encode())
                else:
                    digest.update(hashlib.sha256(path.read_bytes()).digest())
            except OSError:
                digest.update(b"unreadable")
    return digest.hexdigest()


def _installed(env: Mapping[str, str]) -> dict[str, Path]:
    """``agent:market/name/version`` of every installed tree: the layout both agents keep."""
    found = {}
    for agent, root in _roots(env):
        for tree in sorted(root.glob("*/*/*")):
            if tree.is_dir():
                found[f"{agent}:{tree.relative_to(root)}"] = tree
    return found


def scan(state_root: str, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """``{"updated": N, "findings": [plugin, ...], "failed": [plugin, ...], "learned": bool}``; writes the
    state. A finding stays a finding until its tree changes, without a second scan. Only the shape of a
    real secret counts: a mail address or a word in another script says nothing about a plugin."""
    env = os.environ if env is None else env
    path = Path(state_root) / _FILE
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        stored = None
    stored = stored if isinstance(stored, dict) else None
    known: dict[str, str] | None = stored.get("plugins") if stored else None
    flagged: dict[str, str] = (stored.get("findings") or {}) if stored else {}
    installed = _installed(env)
    digests = {key: _digest(tree) for key, tree in installed.items()}
    findings = {key: digest for key, digest in flagged.items() if digests.get(key) == digest}
    failed = []
    updated = 0
    if known is not None:
        scanner = [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "scan", "--tree", "--secrets-only", "--redact"]
        for key, digest in digests.items():
            if known.get(key) == digest:
                continue
            updated += 1
            ceiling = {**env, "GIT_CEILING_DIRECTORIES": str(installed[key].parent)}
            done = subprocess.run(scanner, cwd=installed[key], env=ceiling, capture_output=True, check=False)
            if done.returncode != 0 and done.stdout.strip():
                findings[key] = digest
            elif done.returncode != 0:
                failed.append(key)
    if known != digests or flagged != findings:
        atomic.make_private_dirs(path.parent)
        document = {"schema_version": SCHEMA_VERSION, "plugins": digests, "findings": findings}
        atomic.atomic_write(path, json.dumps(document, indent=2, sort_keys=True) + "\n", mode=0o600)
    return {"updated": updated, "findings": sorted(findings), "failed": failed, "learned": known is None}
