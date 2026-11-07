"""The channels nothing tracks: a read only look, and the update when the owner says so.

Everything runs as the user, with a time limit per channel; a missing tool is ``available: false``,
a failing one has ``error``, and neither ends the run. Without a network the channels that ask one
say ``skipped``. The result stays in ``<state>/upgrade/analysis.json`` and is never published: it
names packages of this machine. Updating here enters nothing into the intent, the lock or the state.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import subprocess
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, procs

SCHEMA_VERSION = 1
_SECONDS = 60
_FILE = Path("upgrade") / "analysis.json"
_RUSTUP_UPDATE = re.compile(r"update available", re.IGNORECASE)
_TOOL_OUTDATED = re.compile(r"^(\S+) v?(\S+) \[latest: v?([^\]]+)\]")
_MAX_NAMES = 3


def _read(argv: Sequence[str], env: Mapping[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv), capture_output=True, text=True, timeout=_SECONDS, stdin=subprocess.DEVNULL, env=env, check=False
    )


def _channel(tool: str, offline: bool) -> dict[str, Any] | None:
    """The answer of a channel that has nothing to read: no tool, or no network."""
    if shutil.which(tool) is None:
        return {"available": False, "count": 0}
    if offline:
        return {"available": True, "count": 0, "skipped": "offline"}
    return None


def _guarded(read: Any, *args: Any) -> dict[str, Any]:
    try:
        result: dict[str, Any] = read(*args)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return {"available": True, "count": 0, "error": str(error)}
    return result


def _snap() -> dict[str, Any]:
    done = _read(["snap", "refresh", "--list"])
    if done.returncode != 0:
        return {"available": True, "count": 0, "error": done.stderr.strip()}
    rows = [line.split() for line in done.stdout.splitlines()[1:] if line.strip()]
    items = [{"name": row[0], "version": row[1] if len(row) > 1 else ""} for row in rows if row]
    return {"available": True, "count": len(items), "items": items}


def _flatpak() -> dict[str, Any]:
    items = []
    for scope in ("--user", "--system"):
        done = _read(["flatpak", "remote-ls", "--updates", "--columns=application,version,origin", scope])
        if done.returncode != 0:
            return {"available": True, "count": 0, "error": done.stderr.strip()}
        for line in done.stdout.splitlines():
            fields = line.split("\t")
            if fields and fields[0]:
                items.append(
                    {
                        "application": fields[0],
                        "version": fields[1] if len(fields) > 1 else "",
                        "origin": fields[2] if len(fields) > 2 else "",
                        "scope": scope.removeprefix("--"),
                    }
                )
    return {"available": True, "count": len(items), "items": items}


def _rustup() -> dict[str, Any]:
    done = _read(["rustup", "check"])
    if done.returncode != 0:
        return {"available": True, "count": 0, "error": done.stderr.strip()}
    lines = [line.strip() for line in done.stdout.splitlines() if _RUSTUP_UPDATE.search(line)]
    return {"available": True, "count": len(lines), "items": lines}


def _sampletool() -> dict[str, Any]:
    done = _read(["sampletool", "tool", "list", "--outdated"])
    if done.returncode != 0:
        return {"available": True, "count": 0, "error": done.stderr.strip()}
    items = []
    for line in done.stdout.splitlines():
        match = _TOOL_OUTDATED.match(line)
        if match:
            items.append({"name": match.group(1), "current": match.group(2), "latest": match.group(3)})
    return {"available": True, "count": len(items), "items": items}


def node_npms(env: Mapping[str, str]) -> list[tuple[str, Path]]:
    """Every Node of nodevers with its npm: the version and the file."""
    home = Path(env.get("HOME", "~")).expanduser()
    root = Path(env.get("NODEVERS_DIR") or home / ".nodevers") / "versions" / "node"
    return [(path.parent.parent.name, path) for path in sorted(root.glob("*/bin/npm"))]


def _node_env(npm: Path, env: Mapping[str, str]) -> dict[str, str]:
    return {**env, "PATH": f"{npm.parent}{os.pathsep}{env.get('PATH', '')}"}


def _provides(npm: Path, package: str) -> set[str]:
    """The command names a global package puts on PATH."""
    manifest = npm.parent.parent / "lib" / "node_modules" / package / "package.json"
    try:
        declared = json.loads(manifest.read_text(encoding="utf-8")).get("bin")
    except (OSError, ValueError, AttributeError):
        return set()
    if isinstance(declared, str):
        return {package.rsplit("/", 1)[-1]}
    return set(declared) if isinstance(declared, dict) else set()


def _npm(tracked: set[str], env: Mapping[str, str]) -> dict[str, Any]:
    nodes: dict[str, Any] = {}
    count = 0
    for version, npm in node_npms(env):
        items: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []
        node: dict[str, Any] = {"items": items, "skipped": skipped}
        nodes[version] = node
        try:
            # Exit 1 is the normal answer when something is outdated.
            done = _read([str(npm), "outdated", "-g", "--json", "--depth=0"], _node_env(npm, env))
            outdated = json.loads(done.stdout or "{}")
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            node["error"] = str(error)
            continue
        for name, row in sorted(outdated.items()):
            if _provides(npm, name) & tracked:
                skipped.append({"name": name, "reason": "tracked-command"})
            else:
                items.append({"name": name, "current": row.get("current"), "latest": row.get("latest")})
        count += len(items)
    return {"available": bool(nodes), "count": count, "nodes": nodes}


def read_user_channels(tracked_commands: set[str], offline: bool, env: Mapping[str, str]) -> dict[str, Any]:
    """Every channel but apt, which needs the engine."""
    channels: dict[str, Any] = {}
    for name, tool, read, args in (
        ("snap", "snap", _snap, ()),
        ("flatpak", "flatpak", _flatpak, ()),
        ("rustup", "rustup", _rustup, ()),
        ("sampletool", "sampletool", _sampletool, ()),
    ):
        channels[name] = _channel(tool, offline) or _guarded(read, *args)
    if offline:
        channels["npm"] = {"available": bool(node_npms(env)), "count": 0, "nodes": {}, "skipped": "offline"}
    else:
        channels["npm"] = _guarded(_npm, tracked_commands, env)
    return channels


def store(state_root: str, channels: Mapping[str, Any]) -> Path:
    path = Path(state_root) / _FILE
    atomic.make_private_dirs(path.parent)
    at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    document = {"schema_version": SCHEMA_VERSION, "at": at, "channels": dict(channels)}
    atomic.atomic_write(path, json.dumps(document, indent=2, sort_keys=True) + "\n", mode=0o600)
    return path


def counts(channels: Mapping[str, Any]) -> dict[str, int]:
    return {name: int(channel.get("count", 0)) for name, channel in sorted(channels.items())}


def _names(items: Sequence[Mapping[str, Any]]) -> str:
    names = [str(item.get("name")) for item in items[:_MAX_NAMES]]
    return ", ".join(names) + (", ..." if len(items) > _MAX_NAMES else "")


def lines(channels: Mapping[str, Any]) -> list[str]:
    """One line per channel, for a person; ``--json`` has the rest."""
    said = []
    for name in ("apt", "snap", "flatpak", "npm", "rustup", "sampletool"):
        channel = channels.get(name) or {}
        if channel.get("error"):
            said.append(f"{name}: could not be read: {channel['error']}")
        elif not channel.get("available"):
            said.append(f"{name}: not on this machine")
        elif channel.get("skipped"):
            said.append(f"{name}: skipped ({channel['skipped']})")
        elif name == "apt":
            packages = channel.get("packages") or []
            phased = sum(1 for package in packages if package.get("phased"))
            detail = f", {phased} phased" if phased else ""
            shown = f" ({_names(packages)})" if packages else ""
            count = channel.get("count", 0)
            said.append(f"apt {count} {'package' if count == 1 else 'packages'}{detail}{shown}")
        elif name == "npm":
            nodes = [
                f"{version}: {len(node.get('items') or [])}"
                + (f" (tracked commands left out: {len(node['skipped'])})" if node.get("skipped") else "")
                for version, node in channel.get("nodes", {}).items()
            ]
            said.append("npm " + "; ".join(nodes))
        else:
            said.append(f"{name} {channel.get('count', 0)}")
    apt = channels.get("apt") or {}
    if apt.get("autoremovable"):
        said.append(f"apt autoremove could take {apt['autoremovable']}; this command never does that")
    if apt.get("boot_low"):
        said.append(f"/boot has only {apt.get('boot_free_mib')} MiB free; nothing is removed by this command")
    return said


def _run(argv: Sequence[str], env: Mapping[str, str] | None = None) -> int:
    try:
        return procs.run_attached(list(argv), env=env)
    except OSError:
        return 127


def update_user_channels(tracked_commands: set[str], offline: bool, env: Mapping[str, str]) -> dict[str, int]:
    """The updates of what runs as the user; a status per channel that ran. Nothing is tracked by
    this. A global npm package that provides a tracked command stays as it is."""
    statuses: dict[str, int] = {}
    if offline:
        return statuses
    if shutil.which("flatpak"):
        statuses["flatpak"] = _run(["flatpak", "update", "--user", "--noninteractive", "-y"])
    npm = _guarded(_npm, tracked_commands, env)
    for version, node in npm.get("nodes", {}).items():
        names = [str(item["name"]) for item in node.get("items", ())]
        if names:
            path = dict(node_npms(env))[version]
            statuses[f"npm {version}"] = _run([str(path), "update", "-g", *names], _node_env(path, env))
    if shutil.which("rustup"):
        statuses["rustup"] = _run(["rustup", "update", "stable"])
    if shutil.which("sampletool"):
        statuses["sampletool"] = _run(["sampletool", "tool", "upgrade", "--all"])
    return statuses
