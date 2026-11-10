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
moved between the fetch and the push. A skill and a host file publish through here with
``publish``; ``txn publish`` pushes a maintain or an update transaction with ``push``, once:
``apply`` and ``upgrade`` move their commits onto the new tip after a lost race, prove them again
and push again, at most ``ATTEMPTS`` times with ``backoff`` in between.

``stamp`` is the one place that names the machine on what `txn publish` sends: an agent's plain
`git commit` and the writer of `upgrade` do not have to know about it. A commit that already
names a machine keeps its name; a commit that gets the line keeps its tree, author and dates, and
is signed again when it was signed or the checkout signs its commits.

Command line::

    python3 -m dotsteward_cli.publish stamp REPOSITORY BASE MACHINE
    python3 -m dotsteward_cli.publish push REPOSITORY BRANCH BASE [MACHINE]

``push`` prints one JSON object {outcome, head, tip, detail}: ``ok``, ``already`` (the remote has
HEAD), ``race`` (the remote is not at BASE), ``network``, ``refused`` or ``unverified`` (the
remote took the push and then holds neither HEAD nor a commit after it).
"""

from __future__ import annotations

import contextlib
import json
import os
import random
import re
import signal
import subprocess
import sys
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
# The pushes of a maintain or an update transaction: each lost one costs a gate, a rebuild and E2E.
ATTEMPTS = 3
ALREADY = "already"
UNVERIFIED = "unverified"
# The private ref of the fetches of txn publish.
TXN_SCOPE = "txn"
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
MACHINE_TRAILER = "Dotsteward-Machine"
_NAMED = re.compile(rf"^{MACHINE_TRAILER}:", re.MULTILINE)
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
    are read, nothing may ask a person, and a commit has UTC dates (docs/privacy.md)."""
    env = {key: value for key, value in os.environ.items() if key not in _REPOSITORY_VARIABLES}
    env["LC_ALL"] = "C"
    env["TZ"] = "UTC"
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
        except BaseException:
            # The caller ends (a signal, Ctrl-C): what it started in its own group ends too.
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
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


def rewrite(
    repository: str | os.PathLike[str],
    commit: str,
    *,
    parent: str | None = None,
    tree: str | None = None,
    message: str | None = None,
) -> str:
    """A new commit like COMMIT, with another PARENT, TREE or MESSAGE: the same author, committer
    and dates, and signed when COMMIT was signed or the checkout signs its commits. No hook runs:
    nothing a person wrote changes."""
    fields = git(repository, "log", "-1", "--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%T%x00%P", commit).stdout
    author, email, date, committer, committer_email, committer_date, old_tree, parents = fields.rstrip("\n").split("\0")
    if message is None:
        message = git(repository, "log", "-1", "--format=%B", commit).stdout.rstrip("\n") + "\n"
    old_parents = parents.split()
    new_parents = ([parent] if parent is not None else old_parents[:1]) + old_parents[1:]
    signing = git(repository, "config", "--bool", "commit.gpgsign").stdout.strip() == "true"
    # A signed commit stays signed: the key of this checkout signs the new one, as it signed the old.
    signed = signing or "\ngpgsig " in git(repository, "cat-file", "commit", commit).stdout
    made = git(
        repository,
        "commit-tree",
        *(["-S"] if signed else []),
        tree or old_tree,
        *[word for each in new_parents for word in ("-p", each)],
        "-F",
        "-",
        stdin=message,
        env={
            "GIT_AUTHOR_NAME": author,
            "GIT_AUTHOR_EMAIL": email,
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_NAME": committer,
            "GIT_COMMITTER_EMAIL": committer_email,
            "GIT_COMMITTER_DATE": committer_date,
        },
    )
    if made.code != 0:
        raise OSError(f"git commit-tree failed: {made.stderr.strip()}")
    return made.stdout.strip()


def stamp(repository: str | os.PathLike[str], base: str, machine: str) -> str:
    """HEAD after every commit of BASE..HEAD names a machine: MACHINE where none is named. Only the
    messages change, so the checkout stays clean. A history with a merge stays as it is."""
    head = git(repository, "rev-parse", "HEAD").stdout.strip()
    rows = git(repository, "rev-list", "--reverse", "--topo-order", "--parents", f"{base}..HEAD").stdout.splitlines()
    commits = [row.split() for row in rows]
    if any(len(row) != 2 for row in commits):
        return head
    parent = base
    for commit, old_parent in commits:
        message = git(repository, "log", "-1", "--format=%B", commit).stdout.rstrip("\n")
        named = _NAMED.search(message) is not None
        if named and old_parent == parent:
            parent = commit
            continue
        if not named:
            message = f"{message}\n\n{MACHINE_TRAILER}: {machine}"
        parent = rewrite(repository, commit, parent=parent, message=message + "\n")
    if parent != head:
        moved = git(repository, "update-ref", "-m", "dotsteward: name the machine", "HEAD", parent, head)
        if moved.code != 0:
            raise OSError(f"git update-ref failed: {moved.stderr.strip()}")
    return parent


def is_ancestor(repository: str | os.PathLike[str], commit: str, of: str) -> bool:
    return git(repository, "merge-base", "--is-ancestor", commit, of).code == 0


def backoff(attempt: int) -> None:
    """The pause after the lost race of ATTEMPT: random, so that two machines do not meet again."""
    time.sleep(random.uniform(0, 2**attempt))


def track(repository: str | os.PathLike[str], branch: str, commit: str) -> None:
    """The remote-tracking ref of BRANCH says what the remote has; a busy lock of it is no failure."""
    git(repository, "update-ref", f"refs/remotes/origin/{branch}", commit)


def push(repository: str | os.PathLike[str], branch: str, base: str, machine: str | None) -> tuple[Published, str]:
    """One push of HEAD for ``txn publish``, which checked everything else: (what became of it, the
    HEAD that went or would have gone). The remote must be at BASE; on a named MACHINE every
    commit after BASE names a machine first. A zero status of the push is the answer; a fetch
    afterwards only makes sure that the remote holds HEAD or a commit after it."""
    head = git(repository, "rev-parse", "HEAD").stdout.strip()
    outcome, tip, detail = fetch_tip(repository, branch, TXN_SCOPE)
    if outcome != OK:
        return Published(outcome, detail=detail), head
    track(repository, branch, tip)
    if tip == head:
        return Published(ALREADY, tip=tip), head
    if tip != base:
        return Published(RACE, tip=tip), head
    if machine:
        head = stamp(repository, base, machine)
    # Not quiet: what git says about the update of the branch is what the person reads.
    pushed = git(repository, "push", "origin", f"HEAD:refs/heads/{branch}", seconds=PUSH_SECONDS)
    verdict = classify(pushed)
    if verdict == RACE:
        return Published(RACE, tip=tip, detail=pushed.stderr.strip()), head
    again, current, _ = fetch_tip(repository, branch, TXN_SCOPE)
    if again == OK:
        track(repository, branch, current)
    if verdict == OK:
        if again == OK and not is_ancestor(repository, head, current):
            return Published(UNVERIFIED, tip=current, detail=pushed.stderr.strip()), head
        return Published(OK, commit=head, tip=tip, detail=pushed.stderr.strip()), head
    # The answer may be what got lost: the commit on the remote says it landed.
    if again == OK and is_ancestor(repository, head, current):
        return Published(OK, commit=head, tip=tip), head
    if again == OK or _REFUSED_WORDS.search(pushed.stderr):
        return Published(verdict, tip=tip, detail=pushed.stderr.strip()), head
    return Published(NETWORK, tip=tip, detail=pushed.stderr.strip()), head


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
            backoff(attempt)
            continue
        # The answer may be what got lost: the commit on the remote says it landed.
        again, current, _ = fetch_tip(repository, branch, scope)
        if again == OK and is_ancestor(repository, commit, current):
            return Published(OK, commit=commit, tip=tip)
        if again == OK or _REFUSED_WORDS.search(pushed.stderr):
            return Published(verdict, tip=tip, detail=pushed.stderr.strip())
        return Published(NETWORK, tip=tip, detail=pushed.stderr.strip())
    return Published(EXHAUSTED, tip=tip)


_USAGE = (
    "usage: python3 -m dotsteward_cli.publish stamp REPOSITORY BASE MACHINE\n"
    "       python3 -m dotsteward_cli.publish push REPOSITORY BRANCH BASE [MACHINE]"
)


def main(argv: Sequence[str]) -> int:
    try:
        if len(argv) == 4 and argv[0] == "stamp":
            print(stamp(argv[1], argv[2], argv[3]))
            return 0
        if len(argv) in (4, 5) and argv[0] == "push":
            published, head = push(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else None)
            answer = {
                "outcome": published.outcome,
                "head": head,
                "tip": published.tip or "",
                "detail": published.detail,
            }
            print(json.dumps(answer))
            return 0
    except OSError as error:
        print(f"[dotsteward] ERROR: {error}", file=sys.stderr)
        return 1
    print(_USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
