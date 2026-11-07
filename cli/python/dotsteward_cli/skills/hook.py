"""``dotsteward skills hook <event> --agent claude|codex``: inside an agent's session.

This must never fail or delay the agent. Whatever goes wrong is swallowed, writing the
error log included, and the status is always 0. A status 2 from a Stop hook would keep
the agent from stopping, which is why the arguments are read by hand: argparse exits 2 on
what it does not know, and the text in the agent's configuration outlives any CLI.

    SessionStart  reconcile; say what waits, if somebody attends the session
    PostToolUse   a file tool wrote below a skill root: evidence, and the debounce
    Stop          reconcile; Claude Code only: one block per session with what waits
    SessionEnd    what this session wrote is captured now, detached

``DOTSTEWARD_HOOKS_OFF=1`` ends it first. In a subagent PostToolUse records its evidence,
so a skill it wrote asks no question, and everything else ends at once. An item is said
at most once in 24 hours, with at most 10 names, and never any content of a skill.

A question needs somebody to answer it, and every ``claude -p`` is a session of its own,
so the default is silence: ``CLAUDE_CODE_SESSION_ATTENDED=0`` never speaks, ``1`` or an
entrypoint of ``cli`` does, anything else does not. Codex has no such variable: it speaks
only under a ``codex`` process that is not ``codex exec``, read from ``/proc`` on Linux and
from ``ps`` on macOS; it never blocks. The items wait in pending.json for the next session or `upgrade`.

Nothing here imports at module level what the path without a change does not need:
modules below this one take no ``pathlib``, ``tomllib``, ``subprocess`` or
``dotsteward_cli.config`` until something happened.
"""

from __future__ import annotations

import json
import os
import re
import select
import sys
import time
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

EVENTS = ("SessionStart", "PostToolUse", "Stop", "SessionEnd")
AGENTS = ("claude", "codex")
MAX_NAMES = 10
ASK_AGAIN_SECONDS = 24 * 3600
OFFLINE_NOTICE_SECONDS = 24 * 3600
_SESSION_MARK_AGE_SECONDS = 7 * 24 * 3600
_CLAUDE_FILE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})
_CODEX_FILE_TOOLS = frozenset({"apply_patch", "Edit", "Write"})
_PATCH_PATH = re.compile(r"^\*\*\* (Add File|Update File|Move to): (.+)$", re.MULTILINE)
_MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
_PAYLOAD_SECONDS = 2.0
_ERROR_LOG = "hook-errors.log"
_ERROR_LOG_BYTES = 64 * 1024


def _parse(argv: Sequence[str]) -> tuple[str, str] | None:
    """(event, agent) of ``<event> --agent <agent>``; None for anything else."""
    if len(argv) == 3 and argv[0] in EVENTS and argv[1] == "--agent" and argv[2] in AGENTS:
        return argv[0], argv[2]
    return None


def _read_payload() -> dict[str, Any] | None:
    """The JSON object on standard input. An agent writes it and closes the pipe; one
    that does not get that far must not keep the hook waiting."""
    if os.isatty(0):
        return None
    chunks = []
    size = 0
    give_up_at = time.monotonic() + _PAYLOAD_SECONDS
    while size < _MAX_PAYLOAD_BYTES:
        ready, _, _ = select.select([0], [], [], max(0.0, give_up_at - time.monotonic()))
        if not ready:
            return None
        data = os.read(0, 1 << 20)
        if not data:
            break
        chunks.append(data)
        size += len(data)
    document = json.loads(b"".join(chunks))
    return document if isinstance(document, dict) else None


def attended(agent: str, payload: Mapping[str, Any]) -> bool:
    """Whether somebody reads what the agent is told; see the module documentation."""
    if agent == "claude":
        value = os.environ.get("CLAUDE_CODE_SESSION_ATTENDED")
        if value == "0":
            return False
        return value == "1" or os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "cli"
    return bool(payload.get("transcript_path")) and _under_codex_session()


def _under_codex_session() -> bool:
    """A process above this one is ``codex``, and it is not ``codex exec``."""
    from dotsteward_cli import config

    read = _proc_process if config.runtime_platform() == "linux" else _ps_process
    pid = os.getppid()
    for _ in range(5):
        if pid <= 1:
            return False
        process = read(pid)
        if process is None or not process[1]:
            return False
        pid, arguments = process
        if os.path.basename(arguments[0]) == b"codex":
            return b"exec" not in arguments[1:]
    return False


def _proc_process(pid: int) -> tuple[int, list[bytes]] | None:
    """(parent pid, command line) of PID from ``/proc`` (Linux); None when unreadable."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            arguments = handle.read().split(b"\0")
        with open(f"/proc/{pid}/stat", "rb") as handle:
            parent = int(handle.read().rpartition(b")")[2].split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return parent, arguments


def _ps_process(pid: int) -> tuple[int, list[bytes]] | None:
    """The same from ``ps``, where there is no ``/proc`` (macOS, where it is ``/bin/ps``
    when the agent's PATH lacks it). The command line comes back as one line, split at
    blanks; an argument with a blank in it is several."""
    import shutil
    import subprocess

    try:
        done = subprocess.run(
            [shutil.which("ps") or "/bin/ps", "-ww", "-o", "ppid=", "-o", "args=", "-p", str(pid)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=_PAYLOAD_SECONDS,
            env={**os.environ, "LC_ALL": "C"},
            check=False,
        )
        fields = done.stdout.split()
        if done.returncode != 0 or len(fields) < 2:
            return None
        return int(fields[0]), fields[1:]
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


# --- what a file tool wrote ------------------------------------------------------------


def _written_paths(agent: str, payload: Mapping[str, Any]) -> tuple[str, list[str]]:
    """The tool of a PostToolUse and the absolute paths it wrote."""
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        return "", []
    allowed = _CLAUDE_FILE_TOOLS if agent == "claude" else _CODEX_FILE_TOOLS
    if tool not in allowed:
        return tool, []
    paths: list[str] = []
    file_path = tool_input.get("file_path")
    if isinstance(file_path, str):
        paths.append(file_path)
    command = tool_input.get("command")
    if isinstance(command, str):
        paths.extend(match.group(2).strip() for match in _PATCH_PATH.finditer(command))
    cwd = payload.get("cwd")
    base = cwd if isinstance(cwd, str) else ""
    return tool, [os.path.normpath(os.path.join(base, path)) for path in paths]


def _locate(paths: Iterable[str], context: Mapping[str, Any]) -> list[tuple[str, str, str]]:
    """(skill path, name, path below it) of each path below a skill root."""
    from_roots = [str(root) for root in (context.get("roots") or []) + (context.get("root_aliases") or [])]
    excluded = context.get("exclude") or []
    hits: list[tuple[str, str, str]] = []
    for path in paths:
        for root in from_roots:
            if not path.startswith(root + os.sep):
                continue
            name, _, below = path[len(root) + 1 :].partition(os.sep)
            if below and not name.startswith((".", "dotsteward-")) and name not in excluded:
                hits.append((os.path.join(root, name), name, below))
            break
    return hits


# --- what waits for a person ------------------------------------------------------------


def _waiting(document: Mapping[str, Any], now: float) -> list[Mapping[str, Any]]:
    """The items to say now: they wait for a person and were not said in 24 hours."""
    waiting = []
    for item in document["items"].values():
        if not isinstance(item, dict) or item.get("kind") == "plugin":
            continue
        asked = item.get("last_asked")
        if isinstance(asked, (int, float)) and now - asked < ASK_AGAIN_SECONDS:
            continue
        status = item.get("state")
        if status in {"ask", "conflict", "blocked", "name-taken", "deleted"}:
            waiting.append(item)
        elif status == "capture" and item.get("reason"):
            since = item.get("offline_since")
            if isinstance(since, (int, float)) and now - since >= OFFLINE_NOTICE_SECONDS:
                waiting.append(item)
    return sorted(waiting, key=lambda item: str(item.get("name")))


def _question(items: Sequence[Mapping[str, Any]]) -> str:
    """What the agent is told: names and commands, at most MAX_NAMES names."""
    from dotsteward_cli.skills import state

    groups: dict[str, list[str]] = {}
    room = MAX_NAMES
    said = 0
    for item in items:
        name = str(item.get("name"))
        if not state.PLAIN_NAME.fullmatch(name):
            continue
        if room == 0:
            continue
        room -= 1
        said += 1
        status = str(item.get("state"))
        groups.setdefault("offline" if status == "capture" else status, []).append(name)
    if not groups and not items:
        return ""
    lines = [
        "Skill tracking (dotsteward) has something the user should decide. "
        "Ask in the language of the user, then run what the answer names."
    ]
    if "ask" in groups:
        lines.append(
            f"- Not tracked yet: {', '.join(groups['ask'])}. Ask for each whether to track it on all machines, "
            "only on this machine, or never: dotsteward skills track <name> --all | --here | --never."
        )
    if "conflict" in groups:
        lines.append(
            f"- Changed here and in the repository: {', '.join(groups['conflict'])}. "
            "See dotsteward skills diff <name> --json; then dotsteward skills resolve <name> --ours | --theirs."
        )
    if "blocked" in groups:
        lines.append(
            f"- Not published: {', '.join(groups['blocked'])}. The reason is in dotsteward skills status; "
            "the skill keeps working here. Once the cause is gone: dotsteward skills retry <name>."
        )
    if "name-taken" in groups:
        lines.append(
            f"- The name is taken here by another skill, a second copy of this skill or a skill of another "
            f"machine: {', '.join(groups['name-taken'])}; dotsteward skills status says which. Ask the user to rename "
            "the skill or remove the other copy, then dotsteward skills retry <name>; "
            "or to answer dotsteward skills track <name> --never."
        )
    if "deleted" in groups:
        lines.append(
            f"- Deleted on this machine: {', '.join(groups['deleted'])}. Ask whether to delete it everywhere "
            "(dotsteward skills forget <name>), to keep it away from this machine only "
            "(dotsteward skills track <name> --never) or to bring it back (dotsteward skills restore <name>)."
        )
    if "offline" in groups:
        lines.append(
            f"- Waiting for a push for more than a day: {', '.join(groups['offline'])}. "
            "The reason is in dotsteward skills status; it may be the network or the credentials of the "
            "instance remote."
        )
    remaining = len(items) - said
    if remaining > 0:
        lines.append(f"+{remaining} more: dotsteward skills status")
    return "\n".join(lines)


def _mark_asked(state_root: str, items: Sequence[Mapping[str, Any]], now: float) -> None:
    from dotsteward_cli.skills import state

    keys = {f"{item.get('kind') or 'skill'}:{item.get('name')}" for item in items}

    def change(document: dict[str, Any]) -> bool:
        for key in keys:
            item = document["items"].get(key)
            if isinstance(item, dict):
                item["last_asked"] = now
        return True

    state.change_pending(state_root, change)


def _mark_session(state_root: str, payload: Mapping[str, Any]) -> bool:
    """The one block of a session: the mark comes first, and without a mark no block."""
    from dotsteward_cli import atomic
    from dotsteward_cli.skills import state

    session = payload.get("session_id")
    if not isinstance(session, str) or not state.PLAIN_NAME.fullmatch(session) or session in {".", ".."}:
        return False
    directory = os.path.join(state.directory(state_root), "sessions")
    atomic.make_private_dirs(directory)
    try:
        os.close(os.open(os.path.join(directory, session), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except OSError:
        return False
    return True


def _prune_sessions(state_root: str, now: float) -> None:
    directory = os.path.join(state_root, "skills", "sessions")
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                if now - entry.stat().st_mtime > _SESSION_MARK_AGE_SECONDS:
                    os.unlink(entry.path)
    except OSError:
        return


# --- the events -------------------------------------------------------------------------


def _capture_items(document: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    return [
        item
        for item in document["items"].values()
        if isinstance(item, dict) and item.get("state") == "capture" and item.get("kind") != "plugin"
    ]


def _session_start(context: Mapping[str, Any], agent: str, payload: Mapping[str, Any]) -> None:
    from dotsteward_cli.skills import reconcile

    now = time.time()
    state_root = str(context["state_root"])
    _prune_sessions(state_root, now)
    document = reconcile.reconcile(context)
    items = _capture_items(document)
    if items:
        from dotsteward_cli.skills import sleeper

        sleeper.resume(context, items)
    waiting = _waiting(document, now)
    if not waiting or not attended(agent, payload):
        return
    text = _question(waiting)
    if not text:
        return
    _mark_asked(state_root, waiting, now)
    sys.stdout.write(
        json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}) + "\n"
    )


def _stop(context: Mapping[str, Any], agent: str, payload: Mapping[str, Any]) -> None:
    from dotsteward_cli.skills import reconcile

    if payload.get("stop_hook_active") is True:
        return
    now = time.time()
    document = reconcile.reconcile(context)
    items = _capture_items(document)
    if items:
        from dotsteward_cli.skills import sleeper

        sleeper.resume(context, items)
    if agent != "claude":
        return
    waiting = _waiting(document, now)
    if not waiting or not attended(agent, payload):
        return
    text = _question(waiting)
    state_root = str(context["state_root"])
    if not text or not _mark_session(state_root, payload):
        return
    _mark_asked(state_root, waiting, now)
    sys.stdout.write(json.dumps({"decision": "block", "reason": text}) + "\n")


def _post_tool_use(context: Mapping[str, Any], agent: str, payload: Mapping[str, Any], subagent: bool) -> None:
    tool, paths = _written_paths(agent, payload)
    hits = _locate(paths, context)
    if not hits:
        return
    from dotsteward_cli.skills import reconcile

    session = payload.get("session_id")
    own_changed, _ = reconcile.note_writes(context, hits, agent, tool, session if isinstance(session, str) else None)
    if own_changed and not subagent:
        from dotsteward_cli.skills import sleeper

        sleeper.arm(context)


def _session_end(context: Mapping[str, Any], payload: Mapping[str, Any]) -> None:
    """What this session wrote goes out now, unless another session wrote it as well and
    has not ended. Everything else keeps its delay: other sessions may still be writing."""
    from dotsteward_cli.skills import state

    state_root = str(context["state_root"])
    session = payload.get("session_id")
    if not any(session in (item.get("writers") or []) for item in _capture_items(state.load_pending(state_root))):
        return
    finished: list[str] = []

    def change(document: dict[str, Any]) -> bool:
        finished.clear()
        for item in _capture_items(document):
            writers = item.get("writers") or []
            if session in writers:
                item["writers"] = [other for other in writers if other != session]  # type: ignore[index]
                if not item["writers"]:
                    item["due"] = True  # type: ignore[index]
                    finished.append(str(item.get("name")))
        return True

    state.change_pending(state_root, change)
    if not finished:
        return
    from dotsteward_cli.skills import sleeper

    if len(finished) == len(_capture_items(state.load_pending(state_root))):
        sleeper.write_deadline(state_root, time.time())
    names = [argument for name in finished for argument in ("--name", name)]
    sleeper.spawn(context, "capture", "--now", *names)


def _run(argv: Sequence[str]) -> None:
    if os.environ.get("DOTSTEWARD_HOOKS_OFF") == "1":
        return
    parsed = _parse(argv)
    if parsed is None:
        return
    event, agent = parsed
    payload = _read_payload()
    if payload is None:
        return
    subagent = bool(payload.get("agent_id"))
    if subagent and event != "PostToolUse":
        return
    from dotsteward_cli.skills import reconcile

    context = reconcile.load_context()
    if context is None:
        return
    if event == "PostToolUse":
        _post_tool_use(context, agent, payload, subagent)
    elif event == "SessionStart":
        _session_start(context, agent, payload)
    elif event == "Stop":
        _stop(context, agent, payload)
    else:
        _session_end(context, payload)


def _log_error() -> None:
    """Keeps the last errors for whoever looks; failing here is no failure either."""
    try:
        from dotsteward_cli.skills import reconcile, state

        context = reconcile.load_context()
        if context is None:
            return
        kind = sys.exc_info()[0]
        state.append_log(
            os.path.join(str(context["state_root"]), "skills", _ERROR_LOG),
            f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {kind.__name__ if kind else 'error'}",
            _ERROR_LOG_BYTES,
        )
    except BaseException:
        return


def main(argv: Sequence[str]) -> int:
    try:
        _run(argv)
        sys.stdout.flush()
    except BaseException:
        _log_error()
    return 0
