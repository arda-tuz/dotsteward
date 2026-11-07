"""The one way to the remote of an instance: no force, and no rebase in a checkout.

    publish(repository, branch, scope, build):
        fetch the branch into refs/dotsteward/<scope>/tip
        build a commit on that tip (None: nothing to publish)
        push it without force
        the remote moved: wait a little and build again on the new tip

A private ref, because concurrent fetches of the shared remote-tracking ref fail on its
lock. A push that fails without a clear no is settled by a fetch: when the commit is on the
remote, it landed. A zero status of a push is the answer as it stands: comparing the remote
with HEAD afterwards would fail whenever another machine pushed in between.

A failure gets one of three names. ``NETWORK``: the name did not resolve, the connection
failed or timed out, the remote hung up: nothing was decided, try later. ``REFUSED``: the
remote answered no, or a hook did: trying again says the same, and a person must hear of
it, so a dead credential does not stay silent as an eternal "offline". ``RACE``: the remote
moved between the fetch and the push. A skill and a host file publish through here so far.
"""

from __future__ import annotations

import os
import random
import re
import signal
import subprocess
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass

OK = "ok"
NETWORK = "network"
REFUSED = "refused"
RACE = "race"
EXHAUSTED = "exhausted"

FETCH_SECONDS = 60
PUSH_SECONDS = 180
SKILL_ATTEMPTS = 5
_TIMED_OUT = 124

# What ssh, git and a remote print when the remote answered and refused.
_REFUSED_WORDS = re.compile(
    r"permission denied|permission to .* denied|repository .*not found|does not appear to be a git repository"
    r"|authentication failed|could not read username|host key verification failed|returned error: 40[0-9]"
    r"|\[remote rejected\]|hook declined|pre-push hook",
    re.IGNORECASE,
)
# What a transport says when the connection, not the remote, failed; git exits 1 with some.
_NETWORK_WORDS = re.compile(r"the remote end hung up|rpc failed|early eof", re.IGNORECASE)
# A remote that lost a race on its own ref says it in its rejection.
_RACE_WORDS = re.compile(
    r"\[rejected\]|non-fast-forward|fetch first|cannot lock ref|failed to update ref|stale info|incorrect old value",
    re.IGNORECASE,
)
_REPOSITORY_VARIABLES = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_PREFIX",
    "GIT_QUARANTINE_PATH",
)


@dataclass(frozen=True)
class GitResult:
    code: int
    stdout: str
    stderr: str


@dataclass
class Published:
    """What became of a publish: OUTCOME, the COMMIT that landed (None when there was
    nothing to publish), the TIP it was built on, and what git said."""

    outcome: str
    commit: str | None = None
    tip: str | None = None
    detail: str = ""


def clean_env(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    """The environment of git: a hook may run inside another repository's hook, messages
    are read, and nothing may ask a person."""
    env = {key: value for key, value in os.environ.items() if key not in _REPOSITORY_VARIABLES}
    env["LC_ALL"] = "C"
    env.pop("LANGUAGE", None)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.setdefault("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=15")
    if extra:
        env.update(extra)
    return env


def run(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike[str] | None = None,
    seconds: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: str | None = None,
) -> GitResult:
    """ARGV with the environment of ``clean_env``. Output through files, not pipes: an SSH
    master that stays behind would keep a pipe open. A time limit ends the whole process
    group, status 124."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err, tempfile.TemporaryFile() as given:
        if stdin is not None:
            given.write(stdin.encode())
            given.seek(0)
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            stdin=given if stdin is not None else subprocess.DEVNULL,
            stdout=out,
            stderr=err,
            env=clean_env(env),
            start_new_session=True,
        )
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = _TIMED_OUT
        out.seek(0)
        err.seek(0)
        return GitResult(code, out.read().decode(errors="replace"), err.read().decode(errors="replace"))


def git(
    repository: str | os.PathLike[str],
    *argv: str,
    seconds: float | None = None,
    env: Mapping[str, str] | None = None,
    stdin: str | None = None,
) -> GitResult:
    """git -C REPOSITORY ARGV; see ``run``."""
    command = ["git", "-C", os.fspath(repository), "-c", "gc.auto=0", "-c", "maintenance.auto=false", *argv]
    return run(command, seconds=seconds, env=env, stdin=stdin)


def classify(result: GitResult) -> str:
    """OK, RACE, REFUSED or NETWORK for a git command that talked to a remote."""
    if result.code == 0:
        return OK
    if result.code == _TIMED_OUT:
        return NETWORK
    text = result.stderr
    if _RACE_WORDS.search(text) and "[remote rejected]" not in text:
        return RACE
    if "[remote rejected]" in text and _RACE_WORDS.search(text.replace("[remote rejected]", "")):
        return RACE
    if _REFUSED_WORDS.search(text):
        return REFUSED
    if _NETWORK_WORDS.search(text):
        return NETWORK
    return NETWORK if result.code == 128 else REFUSED


def fetch_tip(repository: str | os.PathLike[str], branch: str, scope: str) -> tuple[str, str, str]:
    """(outcome, tip, what git said) of a fetch into the private ref of SCOPE."""
    ref = f"refs/dotsteward/{scope}/tip"
    result = git(
        repository,
        "fetch",
        "--quiet",
        "--no-tags",
        "--no-write-fetch-head",
        "--refmap=",
        "origin",
        f"+refs/heads/{branch}:{ref}",
        seconds=FETCH_SECONDS,
    )
    outcome = classify(result)
    if outcome != OK:
        return (NETWORK if outcome == RACE else outcome), "", result.stderr.strip()
    return OK, git(repository, "rev-parse", "--verify", f"{ref}^{{commit}}").stdout.strip(), ""


def is_ancestor(repository: str | os.PathLike[str], commit: str, of: str) -> bool:
    return git(repository, "merge-base", "--is-ancestor", commit, of).code == 0


def publish(
    repository: str | os.PathLike[str],
    branch: str,
    scope: str,
    build: Callable[[str], str | None],
    *,
    attempts: int = SKILL_ATTEMPTS,
) -> Published:
    """Publishes what BUILD makes on the tip of BRANCH; see the module documentation. BUILD
    is called once per attempt, on the tip of that attempt, and may raise."""
    tip = ""
    for attempt in range(1, attempts + 1):
        outcome, tip, detail = fetch_tip(repository, branch, scope)
        if outcome != OK:
            return Published(outcome, detail=detail)
        commit = build(tip)
        if commit is None or commit == tip:
            return Published(OK, tip=tip)
        pushed = git(repository, "push", "--quiet", "origin", f"{commit}:refs/heads/{branch}", seconds=PUSH_SECONDS)
        verdict = classify(pushed)
        if verdict == OK:
            return Published(OK, commit=commit, tip=tip)
        if verdict == RACE:
            time.sleep(random.uniform(0, 2**attempt))
            continue
        # The answer may be what got lost: the commit on the remote says it landed.
        again, current, _ = fetch_tip(repository, branch, scope)
        if again == OK and is_ancestor(repository, commit, current):
            return Published(OK, commit=commit, tip=tip)
        if again == OK or _REFUSED_WORDS.search(pushed.stderr):
            return Published(verdict, tip=tip, detail=pushed.stderr.strip())
        return Published(NETWORK, tip=tip, detail=pushed.stderr.strip())
    return Published(EXHAUSTED, tip=tip)
