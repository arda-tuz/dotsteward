"""``dotsteward skills hooks install|check|remove``: the hooks in an agent's configuration.

    claude  ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json, key hooks
    codex   ${CODEX_HOME:-~/.codex}/hooks.json, the user's hooks file; config.toml stays

One entry per event, appended to what the user has; an entry of ours that exists is
replaced where it is, since Codex keeps its trust by position. Nothing is written without
a change, and a file that is no JSON object is refused and stays. ``hook-context.json``
tells the hooks where everything is, so they need not look for the instance.

The command never changes with a generation: Codex binds its trust to the text. It names
a stable path of the profile, never a store path, needs no variable (it runs under the
shell of the user, which may not take an assignment) and passes no status through: a
status 2 from a Stop hook would keep the agent from stopping.

``[skills] tracking`` is the one switch: off, ``install`` removes what is there. A hook
that is missing is a note and never a failure: ``remove`` is meant to last until the next
`rebuild`. Codex runs no hook of the user's file before ``/hooks`` trusted it, which is a
note as well.
"""

from __future__ import annotations

import contextlib
import json
import os
from collections.abc import Mapping, Sequence
from typing import Any

from dotsteward_cli import atomic, config, tomlfile
from dotsteward_cli.skills import reconcile

AGENTS = ("claude", "codex")
COMPONENTS = {"claude": "claude-code", "codex": "codex"}
# (event, matcher, timeout in seconds)
EVENTS: dict[str, tuple[tuple[str, str | None, int], ...]] = {
    "claude": (
        ("SessionStart", None, 10),
        ("PostToolUse", "Write|Edit|MultiEdit", 5),
        ("Stop", None, 10),
        ("SessionEnd", None, 3),
    ),
    "codex": (
        ("SessionStart", None, 10),
        ("PostToolUse", "apply_patch|Edit|Write", 5),
        ("Stop", None, 10),
        ("SessionEnd", None, 3),
    ),
}
_CODEX_TRUST_EVENT = {
    "SessionStart": "session_start",
    "PostToolUse": "post_tool_use",
    "Stop": "stop",
    "SessionEnd": "session_end",
}


class HooksError(RuntimeError):
    """A configuration file that cannot be read as a JSON object."""


def _home() -> str:
    return os.environ.get("HOME") or os.path.expanduser("~")


def config_file(agent: str) -> str:
    if agent == "claude":
        return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(_home(), ".claude"), "settings.json")
    return os.path.join(os.environ.get("CODEX_HOME") or os.path.join(_home(), ".codex"), "hooks.json")


def stable_cli() -> str:
    """The path of the CLI in the profile, as the hook text writes it: below $HOME when
    it is, and never a store path. ``~/.nix-profile`` when nothing is there yet."""
    home = _home()
    profiles = os.path.join(home, ".local", "state", "nix", "profiles")
    candidates = (
        os.path.join(home, ".nix-profile", "bin", "dotsteward"),
        os.path.join(profiles, "home-manager", "home-path", "bin", "dotsteward"),
        os.path.join(profiles, "profile", "bin", "dotsteward"),
    )
    chosen = next((path for path in candidates if os.access(path, os.X_OK)), candidates[0])
    return "$HOME" + chosen[len(home) :] if chosen.startswith(home + os.sep) else chosen


def hook_text(event: str, agent: str, cli: str) -> str:
    return f'[ -x "{cli}" ] && "{cli}" skills hook {event} --agent {agent} 2>/dev/null; exit 0'


def _marker(event: str, agent: str) -> str:
    return f"skills hook {event} --agent {agent}"


def _read(path: str) -> dict[str, Any]:
    """The JSON object in the file at PATH, an empty one when there is no file."""
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        raise HooksError(f"cannot read {path}: {error}") from error
    if not isinstance(document, dict):
        raise HooksError(f"cannot read {path}: not a JSON object")
    hooks = document.get("hooks", {})
    if not isinstance(hooks, dict) or not all(isinstance(entries, list) for entries in hooks.values()):
        raise HooksError(f"cannot read {path}: hooks is not an object of lists")
    return document


def _write(path: str, document: Mapping[str, Any]) -> None:
    atomic.atomic_write(path, json.dumps(document, indent=2, ensure_ascii=False) + "\n", parents=True)


def _position(entries: Sequence[Any], marker: str) -> int | None:
    """The index of the entry of ours in the entries of an event."""
    for index, entry in enumerate(entries):
        hooks = entry.get("hooks") if isinstance(entry, dict) else None
        for hook in hooks if isinstance(hooks, list) else []:
            if isinstance(hook, dict) and marker in str(hook.get("command", "")):
                return index
    return None


def merge_agent(agent: str) -> bool:
    """Puts the hooks of AGENT into its configuration; whether the file changed."""
    path = config_file(agent)
    document = _read(path)
    cli = stable_cli()
    hooks = document.setdefault("hooks", {})
    changed = False
    for event, matcher, timeout in EVENTS[agent]:
        command = {"type": "command", "command": hook_text(event, agent, cli), "timeout": timeout}
        wanted: dict[str, Any] = {"matcher": matcher, "hooks": [command]} if matcher else {"hooks": [command]}
        entries = hooks.setdefault(event, [])
        position = _position(entries, _marker(event, agent))
        if position is None:
            entries.append(wanted)
            changed = True
        elif entries[position] != wanted:
            entries[position] = wanted
            changed = True
    if changed:
        _write(path, document)
    return changed


def remove_agent(agent: str) -> bool:
    """Takes the hooks of AGENT out of its configuration; whether the file changed."""
    path = config_file(agent)
    if not os.path.exists(path):
        return False
    document = _read(path)
    hooks = document.get("hooks", {})
    changed = False
    for event, _, _ in EVENTS[agent]:
        entries = hooks.get(event)
        position = None if entries is None else _position(entries, _marker(event, agent))
        if entries is not None and position is not None:
            del entries[position]
            changed = True
            if not entries:
                del hooks[event]
    if changed:
        if not hooks:
            document.pop("hooks", None)
        _write(path, document)
    return changed


def installed_events(agent: str) -> list[str]:
    """The events of AGENT that have an entry of ours."""
    document = _read(config_file(agent))
    hooks = document.get("hooks", {})
    return [
        event for event, _, _ in EVENTS[agent] if _position(hooks.get(event, []), _marker(event, agent)) is not None
    ]


def untrusted_codex_events() -> list[str]:
    """The events whose entry `/hooks` of Codex has not trusted yet."""
    path = config_file("codex")
    document = _read(path)
    home = os.path.dirname(path)
    try:
        toml = tomlfile.load(os.path.join(home, "config.toml"))
    except (OSError, ValueError):
        toml = {}
    known = toml.get("hooks", {}).get("state", {}) if isinstance(toml.get("hooks"), dict) else {}
    missing = []
    for event, _, _ in EVENTS["codex"]:
        entries = document.get("hooks", {}).get(event, [])
        position = _position(entries, _marker(event, "codex"))
        if position is None:
            continue
        key = f"{os.path.abspath(path)}:{_CODEX_TRUST_EVENT[event]}:{position}:0"
        if key not in known:
            missing.append(event)
    return missing


def build_context(loaded: config.Instance) -> dict[str, Any]:
    """What ``hook-context.json`` holds for this instance on this machine."""
    from dotsteward_cli.skills import commands, layout

    where = layout.read(loaded)
    state_root = config.state_root(loaded)
    roots = [where.canonical, *where.legacy_roots, *where.link_roots, *where.agent_roots.values()]
    context: dict[str, Any] = {
        "schema_version": 1,
        "instance": str(loaded.root),
        "state_root": state_root,
        "lock_path": str(loaded.root / loaded.config["skills"]["lock"]),
        "repo_owned_revisions": sorted(commands.own_revisions(loaded)),
        "roots": list(dict.fromkeys(roots)),
        "scoped_store": where.scoped_store,
        "exclude": sorted({"synced", *where.excluded}),
        "capture_delay_seconds": commands.setting(loaded, "capture_delay_seconds", 600),
        "capture_max_mib": commands.setting(loaded, "capture_max_mib", 100),
    }
    aliases = [where.scoped_store, *(os.path.realpath(root) for root in context["roots"])]
    context["root_aliases"] = [root for root in dict.fromkeys(aliases) if root not in context["roots"]]
    context["machine"] = reconcile.machine_name(context)
    return context


def write_context(loaded: config.Instance) -> None:
    atomic.atomic_write_json(reconcile.context_path(), build_context(loaded), mode=0o600, parents=True)


def remove_context() -> None:
    with contextlib.suppress(OSError):
        os.unlink(reconcile.context_path())
