"""``dotsteward state``: the state each machine observes, on a branch of its own.

The state of the machine NAME is ``state.json`` on ``refs/heads/state/NAME`` of the
instance remote: an orphan history whose commits hold that one file. Only NAME writes it.
Git builds every commit from objects alone (``hash-object``, ``mktree``, ``commit-tree``,
``update-ref``), so HEAD, the index and the work tree never change: the checkout stays
clean, and the checks of the checkout and the gate never see the branch.

``record`` observes this machine, holds the document to ``schema/state.schema.json`` and
to the intent (only the enabled components that apply here, only the packages a component
installs or follows), scans it with the privacy policy of the instance and commits it on
the last record. A finding writes nothing. A record equal to the last one, apart from its
time, is no commit. Then it pushes, unless ``[policy] observed_state_push = false`` keeps
the branch on this machine.

``push`` is a plain fast-forward push, never forced. When the remote branch moved on: the
records there come from this machine (its machine key), so a second checkout of this
machine recorded too, and this record becomes one commit on the tip of the remote; or they
come from another machine key, two machines use one name, and the push stops until this
machine takes another name or, as the reinstall of that machine, pushes ``--take-over``.
Without a network the record waits on this machine: the local branch ahead of the remote
one is the queue, and the next ``record`` or ``push`` sends it.

``fetch`` brings the branches of every machine to ``refs/remotes/origin/state/*``; ``show``
prints the state of this machine (its local branch) or of another (what the last fetch
brought).

Exit status: 0 done, 1 refusal, 2 usage error, 4 the record breaks its schema or the
privacy scan found something (nothing was recorded), 6 no network or no login (what was
recorded waits; run it again).

Python API for the commands that record a state: ``observe``, ``record``, ``push``,
``read``.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import config, host, locks, machine, platforms, report
from dotsteward_cli import publish as publishing
from dotsteward_cli.upgrade import facts

EXIT_REFUSAL = 1
EXIT_USAGE = 2
EXIT_PRIVACY = report.PRIVACY_STOP
EXIT_OFFLINE = report.PARTIAL

SCHEMA_VERSION = 1
FILE = "state.json"
BRANCH_PREFIX = "state/"
RECORDERS = ("state", "upgrade", "observe", "apply", "bootstrap")
PUBLISH_SCOPE = "state"
_ZERO = "0" * 40
_PRIVATE_TIP = f"refs/dotsteward/{PUBLISH_SCOPE}/tip"

_INSTANT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", re.ASCII)
_KERNEL = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)-[a-z]+", re.ASCII)
_STORE_PATH = re.compile(r"/nix/store/([0-9a-df-np-sv-z]{32})-[^/]*", re.ASCII)
_HEX40 = re.compile(r"[0-9a-f]{40}", re.ASCII)
_MISSING_REF = re.compile(r"couldn't find remote ref", re.IGNORECASE)
_UPDATERS = ("apt", "nix", "dotsteward", "self", "none")
_DEB = "deb"


class Refusal(Exception):
    """A refusal: exit status 1."""


class UsageError(Exception):
    """A usage error: exit status 2."""


class Finding(Exception):
    """The record breaks its schema or the privacy scan found something: exit status 4."""


def _log(message: str) -> None:
    print(f"[dotsteward] {message}", flush=True)


def _error(message: str) -> None:
    print(f"[dotsteward] ERROR: {message}", file=sys.stderr)


def _wait(message: str) -> None:
    print(f"[dotsteward] {message}", file=sys.stderr)


def branch(name: str) -> str:
    """The branch of the machine NAME on the remote: state/NAME."""
    return f"{BRANCH_PREFIX}{name}"


def local_ref(name: str) -> str:
    return f"refs/heads/{branch(name)}"


def remote_ref(name: str) -> str:
    return f"refs/remotes/origin/{branch(name)}"


# --- The document ---------------------------------------------------------------------------


def schema(root: Path = config.FRAMEWORK_ROOT) -> dict[str, Any]:
    """The parsed schema/state.schema.json of the framework."""
    with open(root / "schema" / "state.schema.json", encoding="utf-8") as handle:
        document: dict[str, Any] = json.load(handle)
    return document


def schema_problems(document: Mapping[str, Any]) -> list[str]:
    """What breaks the schema in DOCUMENT; nothing when it is a state."""
    if not isinstance(document, dict):
        return ["(root): expected a table"]
    return config.schema_errors(schema(), document)


def _settings(instance: config.Instance, name: str) -> Mapping[str, Any]:
    found = instance.config.get("components", {}).get(name)
    return found if isinstance(found, Mapping) else {}


def _installs(component: Mapping[str, Any]) -> list[str]:
    install = component.get("install") or {}
    return [str(name) for name in [*(install.get("packageNames") or ()), *(install.get("apt") or ())]]


def _followed(instance: config.Instance, component: Mapping[str, Any]) -> list[str]:
    return [str(name) for name in _settings(instance, str(component["name"])).get("track") or ()]


def _apt_driven(instance: config.Instance, component: Mapping[str, Any]) -> bool:
    updater = _settings(instance, str(component["name"])).get("updater")
    return component.get("method") == _DEB and updater in (None, "apt")


def _active(instance: config.Instance, env: Mapping[str, str]) -> list[dict[str, Any]]:
    state = config.state_root(instance, env)
    name = machine.current_name(machine.read_machine(state), env)
    profile = machine.machine_profile(instance, state, name, env)
    return facts.active_components(instance, profile, env)


def intent_problems(instance: config.Instance, document: Mapping[str, Any], env: Mapping[str, str]) -> list[str]:
    """What the schema cannot say: a component outside the enabled components that apply
    here, a package its component neither installs nor follows."""
    active = {str(component["name"]): component for component in _active(instance, env)}
    problems = []
    components = document.get("components")
    for name, entry in (components if isinstance(components, Mapping) else {}).items():
        component = active.get(name)
        if component is None:
            problems.append(f"components.{name}: not an enabled component of the intent that applies here")
            continue
        allowed = {*_installs(component), *_followed(instance, component)}
        packages = entry.get("packages") if isinstance(entry, Mapping) else None
        for package in packages if isinstance(packages, Mapping) else {}:
            if package not in allowed:
                problems.append(f"components.{name}.packages.{package}: not a package of the component")
    return problems


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


def _platform(instance: config.Instance, env: Mapping[str, str]) -> dict[str, str]:
    found: dict[str, str] = {}
    if platforms.is_darwin(platforms.platform_id(env)):
        found["os"] = "macos"
        version = platforms.platform_id(env).partition("-")[2]
        if version:
            found["version"] = version
    else:
        release = platforms.os_release(env)
        found.update(
            {
                key: release[field].lower() if key != "version" else release[field]
                for key, field in (("os", "ID"), ("version", "VERSION_ID"), ("codename", "VERSION_CODENAME"))
                if release.get(field)
            }
        )
    found["arch"] = machine.nix_system(instance, env).partition("-")[0]
    return found


def _kernel_order(release: str) -> tuple[int, ...]:
    matched = _KERNEL.fullmatch(release)
    return tuple(int(part) for part in matched.groups()) if matched else ()


def _kernel() -> dict[str, str]:
    """The release that runs and the newest one in /boot, each when it has the form of an
    Ubuntu kernel release."""
    found: dict[str, str] = {}
    running = os.uname().release
    if _KERNEL.fullmatch(running):
        found["running"] = running
    try:
        names = os.listdir("/boot")
    except OSError:
        names = []
    installed = [name.removeprefix("vmlinuz-") for name in names if name.startswith("vmlinuz-")]
    installed = [release for release in installed if _KERNEL.fullmatch(release)]
    if installed:
        found["newest"] = max(installed, key=_kernel_order)
    return found


def _generation(state: str) -> dict[str, str]:
    """The active generation, and the result of the last E2E run when it ran on that one."""
    activation = _read_json(Path(state) / "current" / "activation.json")
    path = activation.get("generation")
    matched = _STORE_PATH.fullmatch(path) if isinstance(path, str) else None
    if matched is None:
        return {}
    found = {"home_manager": matched.group(1)}
    e2e = _read_json(Path(state) / "update" / "e2e.json")
    result = {"passed": "pass", "failed": "fail"}.get(str(e2e.get("result")))
    if result is not None and e2e.get("generation") == path:
        found["e2e"] = result
        at = e2e.get("recorded_at")
        if isinstance(at, str) and _INSTANT.fullmatch(at):
            found["at"] = at
    return found


def _installed_versions(packages: Sequence[str]) -> dict[str, str] | None:
    """The installed version of each of PACKAGES that dpkg has; None without dpkg."""
    if not packages or shutil.which("dpkg-query") is None:
        return None if packages else {}
    done = subprocess.run(
        ["dpkg-query", "-W", "-f", "${Package}\t${db:Status-Status}\t${Version}\n", *packages],
        capture_output=True,
        text=True,
        check=False,
        stdin=subprocess.DEVNULL,
    )
    found = {}
    for line in done.stdout.splitlines():
        package, _, rest = line.partition("\t")
        status, _, version = rest.partition("\t")
        if status == "installed" and version:
            found[package] = version
    return found


def _components(instance: config.Instance, env: Mapping[str, str]) -> dict[str, dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    for component in _active(instance, env):
        name = str(component["name"])
        entry: dict[str, Any] = {}
        updater = _settings(instance, name).get("updater")
        if updater in _UPDATERS:
            entry["updater"] = updater
        if _apt_driven(instance, component):
            installs = _installs(component)
            wanted = sorted({*installs, *_followed(instance, component)})
            versions = _installed_versions(wanted)
            if versions is not None:
                entry["status"] = "installed" if all(package in versions for package in installs) else "missing"
                entry["packages"] = dict(sorted(versions.items()))
        found[name] = entry
    return dict(sorted(found.items()))


def _intent_commit(instance: config.Instance) -> str | None:
    head = publishing.git(instance.root, "rev-parse", "--verify", "--quiet", "HEAD").stdout.strip()
    return head if _HEX40.fullmatch(head) else None


def _framework_version() -> str | None:
    try:
        return (config.FRAMEWORK_ROOT / "VERSION").read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def _this_machine(instance: config.Instance, env: Mapping[str, str]) -> tuple[str, str]:
    """The name and the machine key of this machine."""
    record = machine.read_machine(config.state_root(instance, env))
    name = machine.current_name(record, env)
    if name is None:
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    if record is None or record.get("name") != name:
        raise Refusal(f"this machine has no machine key as {name}: 'dotsteward host init' names it")
    return name, str(record.get("machine_key"))


def observe(instance: config.Instance, env: Mapping[str, str] | None = None, *, by: str = "state") -> dict[str, Any]:
    """The state this machine observes now: the document a record writes."""
    env = os.environ if env is None else env
    if by not in RECORDERS:
        raise ValueError(f"unknown recorder {by!r}")
    name, key = _this_machine(instance, env)
    state = config.state_root(instance, env)
    document: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "host": name,
        "machine_key": key,
        "recorded_at": _now(),
        "recorded_by": by,
    }
    optional = {
        "framework_version": _framework_version(),
        "intent_commit": _intent_commit(instance),
        "platform": _platform(instance, env),
        "kernel": _kernel() if config.runtime_platform(env) == "linux" else {},
        "generation": _generation(state),
    }
    document.update({key: value for key, value in optional.items() if value})
    document["components"] = _components(instance, env)
    return document


def _same(first: Mapping[str, Any] | None, second: Mapping[str, Any] | None) -> bool:
    """Whether two records say the same, whenever each was recorded."""
    if first is None or second is None:
        return False
    return {k: v for k, v in first.items() if k != "recorded_at"} == {
        k: v for k, v in second.items() if k != "recorded_at"
    }


# --- Git ------------------------------------------------------------------------------------------


def _git(instance: config.Instance, *arguments: str, stdin: str | None = None) -> publishing.GitResult:
    return publishing.git(instance.root, *arguments, stdin=stdin)


def _out(instance: config.Instance, *arguments: str, stdin: str | None = None) -> str:
    result = _git(instance, *arguments, stdin=stdin)
    if result.code != 0:
        raise Refusal(f"git {' '.join(arguments[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _tip(instance: config.Instance, ref: str) -> str | None:
    found = _git(instance, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").stdout.strip()
    return found or None


def _document_at(instance: config.Instance, commit: str) -> dict[str, Any] | None:
    shown = _git(instance, "cat-file", "blob", f"{commit}:{FILE}")
    if shown.code != 0:
        return None
    try:
        document = json.loads(shown.stdout)
    except ValueError:
        return None
    return document if isinstance(document, dict) else None


def _ancestor(instance: config.Instance, commit: str, of: str) -> bool:
    return publishing.is_ancestor(instance.root, commit, of)


class Busy(Exception):
    """Another run moved the branch at the same time, twice: exit status 6, run it again."""


def _checked_out_in(instance: config.Instance, name: str) -> str | None:
    """The work tree where refs/heads/state/NAME is checked out, None when it is nowhere."""
    listing = _git(instance, "worktree", "list", "--porcelain").stdout
    path = None
    for line in listing.splitlines():
        if line.startswith("worktree "):
            path = line.removeprefix("worktree ")
        elif line == f"branch {local_ref(name)}":
            return path
    return None


def _move(instance: config.Instance, name: str, new: str, old: str | None, why: str) -> bool:
    """refs/heads/state/NAME from OLD (None: no branch yet) to NEW; False when another run
    moved it in between. A branch checked out in a work tree is never moved under it."""
    where = _checked_out_in(instance, name)
    if where is not None:
        raise Refusal(f"{branch(name)} is checked out in {where}; 'git worktree remove' it first")
    moved = _git(instance, "update-ref", "-m", f"dotsteward: {why}", local_ref(name), new, old or _ZERO)
    return moved.code == 0


def _move_or_busy(instance: config.Instance, name: str, new: str, old: str | None, why: str) -> None:
    if not _move(instance, name, new, old, why):
        raise Busy(f"another run moved {branch(name)} at the same time; run it again")


def _commit_parents(instance: config.Instance, name: str, tree: str, parents: Sequence[str]) -> str:
    arguments = [part for parent in parents for part in ("-p", parent)]
    return _out(
        instance,
        *host.commit_identity(instance.root, "HEAD"),
        "commit-tree",
        tree,
        *arguments,
        "-F",
        "-",
        stdin=host.commit_message(f"chore(state): record {name}", name),
    )


def _commit(instance: config.Instance, name: str, text: str, parent: str | None) -> str:
    blob = _out(instance, "hash-object", "-w", "--stdin", stdin=text)
    tree = _out(instance, "mktree", stdin=f"100644 blob {blob}\t{FILE}\n")
    return _commit_tree(instance, name, tree, parent)


def _commit_tree(instance: config.Instance, name: str, tree: str, parent: str | None) -> str:
    return _commit_parents(instance, name, tree, [parent] if parent else [])


def _fetch_remote(instance: config.Instance, name: str) -> tuple[str, str | None, str]:
    """(outcome, the tip of state/NAME on the remote or None when it has none, what git said)."""
    fetched = publishing.git(
        instance.root,
        "fetch",
        "--quiet",
        "--no-tags",
        "--no-write-fetch-head",
        "--refmap=",
        "origin",
        f"+{local_ref(name)}:{_PRIVATE_TIP}",
        seconds=publishing.FETCH_SECONDS,
    )
    if fetched.code != 0 and _MISSING_REF.search(fetched.stderr):
        return publishing.OK, None, ""
    outcome = publishing.classify(fetched)
    if outcome != publishing.OK:
        return (publishing.NETWORK if outcome == publishing.RACE else outcome), None, fetched.stderr.strip()
    return publishing.OK, _tip(instance, _PRIVATE_TIP), ""


# --- record and push ---------------------------------------------------------------------------------


def _check(instance: config.Instance, document: Mapping[str, Any], env: Mapping[str, str]) -> str:
    """The text of DOCUMENT once it passed its schema, the intent and the privacy scan."""
    problems = schema_problems(document) or intent_problems(instance, document, env)
    if problems:
        raise Finding(
            f"the state of {document.get('host')} breaks its schema: {'; '.join(problems)}; nothing was recorded"
        )
    text = json.dumps(document, indent=2, ensure_ascii=True) + "\n"
    if host.scan_file(instance, FILE, text, env) != 0:
        raise Finding(f"the privacy scan found something in {FILE}; nothing was recorded")
    return text


def _push_allowed(instance: config.Instance) -> bool:
    return instance.config.get("policy", {}).get("observed_state_push", True) is not False


# A record whose machine key is not the one of the branch takes the branch over only on the
# reinstall of the machine (`host init --reuse` writes reused into machine.json).
def _may_take_over(instance: config.Instance, env: Mapping[str, str], name: str) -> None:
    record_ = machine.read_machine(config.state_root(instance, env)) or {}
    if record_.get("reused") is not True:
        raise Refusal(
            f"only the reinstall of {name} takes over {branch(name)}: this machine was not named with "
            f"'dotsteward host init --reuse'; 'dotsteward host rename NEW' gives it a name of its own"
        )


def _key_at(instance: config.Instance, commit: str) -> str | None:
    document = _document_at(instance, commit)
    key = document.get("machine_key") if document is not None else None
    return key if isinstance(key, str) else None


def _when(instance: config.Instance, commit: str) -> str:
    document = _document_at(instance, commit) or {}
    return str(document.get("recorded_at") or "")


def _integrate(
    instance: config.Instance, name: str, key: str, mine: str | None, theirs: str | None, *, take_over: bool
) -> str | None:
    """The local branch once it holds THEIRS, the tip of the remote: the newest record is the
    tip, and every record of both stays in the history (a merge when they diverged). Records of
    another machine key are two machines with one name, unless this one takes over."""
    shown = branch(name)
    if theirs is None or theirs == mine:
        return mine
    if mine is not None and _key_at(instance, mine) != key:
        raise _two_machines(name)
    if _key_at(instance, theirs) != key:
        if not take_over:
            raise _two_machines(name)
        if mine is None:
            raise Refusal(f"nothing recorded for {name} yet; 'dotsteward state record --no-push' records it first")
        taken = _commit_tree(instance, name, _out(instance, "rev-parse", f"{mine}^{{tree}}"), theirs)
        _move_or_busy(instance, name, taken, mine, f"take over {shown}")
        return taken
    if mine is None or _ancestor(instance, mine, theirs):
        _move_or_busy(instance, name, theirs, mine, f"take {shown} of the remote")
        return theirs
    if _ancestor(instance, theirs, mine):
        return mine
    # Two checkouts of this machine recorded apart: the newer record is the tip (the remote one
    # on a tie), and both histories stay, so no record that waited is lost.
    newest = mine if _when(instance, mine) > _when(instance, theirs) else theirs
    merged = _commit_parents(instance, name, _out(instance, "rev-parse", f"{newest}^{{tree}}"), [theirs, mine])
    _move_or_busy(instance, name, merged, mine, f"join the records of {shown}")
    return merged


def record(
    instance: config.Instance,
    env: Mapping[str, str] | None = None,
    *,
    document: Mapping[str, Any] | None = None,
    by: str = "state",
    push_after: bool = True,
) -> int:
    """Records DOCUMENT (default: what ``observe`` sees) on the state branch of this machine
    and pushes it: the exit status of ``state record``. Raises Finding, Refusal, Busy."""
    env = os.environ if env is None else env
    name, key = _this_machine(instance, env)
    document = dict(document) if document is not None else observe(instance, env, by=by)
    if document.get("host") != name:
        raise Refusal(f"a record of {document.get('host')} is no record of this machine, {name}")
    text = _check(instance, document, env)
    pushing = push_after and _push_allowed(instance)
    if pushing:
        # What the other checkouts of this machine published comes first: a record is the
        # newest, and the same state as the last record anywhere is no new commit.
        outcome, theirs, _ = _fetch_remote(instance, name)
        if outcome == publishing.OK and theirs is not None and _key_at(instance, theirs) == key:
            _integrate(instance, name, key, _tip(instance, local_ref(name)), theirs, take_over=False)
    for attempt in (1, 2):
        tip = _tip(instance, local_ref(name))
        if tip is not None and _key_at(instance, tip) != key:
            raise _two_machines(name)
        if tip is not None and _same(_document_at(instance, tip), document):
            _log(f"the state of {name} is as recorded on {branch(name)}")
            break
        if _move(instance, name, _commit(instance, name, text, tip), tip, f"record the state of {name}"):
            _log(f"recorded the state of {name} on {branch(name)}")
            break
        if attempt == 2:
            raise Busy(f"other runs kept recording on {branch(name)} at the same time; run it again")
    if not push_after:
        return 0
    return push(instance, env)


def _two_machines(name: str) -> Refusal:
    return Refusal(
        f"{branch(name)} on the remote belongs to another machine (another machine key): two machines use the "
        f"name {name}. 'dotsteward host rename NEW' gives this machine a name of its own; when this machine is the "
        f"reinstall of {name} (named with 'dotsteward host init --reuse'), 'dotsteward state push --take-over' "
        f"continues its records"
    )


def push(instance: config.Instance, env: Mapping[str, str] | None = None, *, take_over: bool = False) -> int:
    """Sends what this machine recorded and the remote does not have: the exit status of
    ``state push``. Raises Refusal, Busy."""
    env = os.environ if env is None else env
    name, key = _this_machine(instance, env)
    shown = branch(name)
    if not _push_allowed(instance):
        _log(f"[policy] observed_state_push = false: {shown} stays on this machine")
        return 0
    if take_over:
        _may_take_over(instance, env, name)
    for attempt in range(1, publishing.SKILL_ATTEMPTS + 1):
        mine = _tip(instance, local_ref(name))
        if mine is None:
            _log(f"nothing recorded for {name} yet; 'dotsteward state record' records it")
            return 0
        outcome, theirs, detail = _fetch_remote(instance, name)
        if outcome != publishing.OK:
            if outcome == publishing.REFUSED and host.refused(detail):
                raise Refusal(f"the remote refused the fetch of {shown}: {detail}")
            _wait(f"{shown} waits: no network or no login ({detail or 'timeout'})")
            return EXIT_OFFLINE
        sending = _integrate(instance, name, key, mine, theirs, take_over=take_over)
        assert sending is not None
        if sending == theirs:
            _git(instance, "update-ref", remote_ref(name), theirs)
            _log(f"{shown} is on the remote; nothing to publish")
            return 0
        pushed = publishing.git(
            instance.root, "push", "--quiet", "origin", f"{sending}:{local_ref(name)}", seconds=publishing.PUSH_SECONDS
        )
        verdict = publishing.classify(pushed)
        if verdict == publishing.RACE:
            time.sleep(random.uniform(0, 2**attempt))
            continue
        if verdict != publishing.OK:
            # The answer may be what got lost: the commit on the remote says it landed.
            again, current, _ = _fetch_remote(instance, name)
            if not (again == publishing.OK and current is not None and _ancestor(instance, sending, current)):
                if verdict == publishing.REFUSED and (again == publishing.OK or host.refused(pushed.stderr)):
                    raise Refusal(f"the remote refused the push of {shown}: {pushed.stderr.strip()}")
                _wait(f"{shown} waits: no network or no login ({pushed.stderr.strip() or 'timeout'})")
                return EXIT_OFFLINE
        _git(instance, "update-ref", remote_ref(name), sending)
        _log(f"published {shown}")
        return 0
    _wait(f"{shown} waits: other checkouts of this machine kept pushing")
    return EXIT_OFFLINE


# --- fetch and show ---------------------------------------------------------------------------------


def fetch(instance: config.Instance) -> int:
    """Brings state/* of the remote to refs/remotes/origin/state/*: the exit status of ``state fetch``."""
    fetched = publishing.git(
        instance.root,
        "fetch",
        "--quiet",
        "--no-tags",
        "--prune",
        "--no-write-fetch-head",
        "origin",
        f"+refs/heads/{BRANCH_PREFIX}*:refs/remotes/origin/{BRANCH_PREFIX}*",
        seconds=publishing.FETCH_SECONDS,
    )
    outcome = publishing.classify(fetched)
    if outcome == publishing.REFUSED and host.refused(fetched.stderr):
        raise Refusal(f"the remote refused the fetch: {fetched.stderr.strip()}")
    if outcome != publishing.OK:
        _wait(f"the state of the machines waits: no network or no login ({fetched.stderr.strip() or 'timeout'})")
        return EXIT_OFFLINE
    names = _out(instance, "for-each-ref", "--format=%(refname)", f"refs/remotes/origin/{BRANCH_PREFIX}").split()
    count = len(names)
    _log(f"fetched the state of {count} machine{'' if count == 1 else 's'}")
    return 0


def read(instance: config.Instance, name: str, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """{host, this_machine, source, queued, state} of the machine NAME: its local branch on this
    machine, else what the last fetch brought. Raises Refusal."""
    env = os.environ if env is None else env
    record_name = machine.current_name(machine.read_machine(config.state_root(instance, env)), env)
    this = name == record_name
    local = _tip(instance, local_ref(name)) if this else None
    fetched = _tip(instance, remote_ref(name))
    commit = local or fetched
    if commit is None:
        raise Refusal(f"no recorded state of {name} here: 'dotsteward state fetch' brings it")
    document = _document_at(instance, commit)
    if document is None:
        raise Refusal(f"{branch(name)} holds no {FILE} that can be read")
    problems = schema_problems(document)
    if problems:
        raise Refusal(f"{branch(name)}: {FILE} breaks its schema: {'; '.join(problems)}")
    queued = None
    if this and local is not None:
        queued = fetched is None or not (local == fetched or _ancestor(instance, local, fetched))
    return {
        "host": name,
        "this_machine": this,
        "source": "local" if local is not None else "remote",
        "queued": queued,
        "state": document,
    }


def _human(shown: Mapping[str, Any]) -> list[str]:
    document = shown["state"]
    lines = [f"machine: {shown['host']}{' (this machine)' if shown['this_machine'] else ''}"]
    framework = document.get("framework_version")
    lines.append(
        f"recorded: {document['recorded_at']} by {document['recorded_by']}"
        + (f", framework {framework}" if framework else "")
    )
    if shown["queued"] is not None:
        lines.append(f"queued: {'yes (not on the remote yet)' if shown['queued'] else 'no'}")
    platform = document.get("platform") or {}
    if platform:
        parts = (platform.get(key) for key in ("os", "version", "codename", "arch"))
        lines.append(f"platform: {' '.join(part for part in parts if part)}")
    kernel = document.get("kernel") or {}
    if kernel:
        lines.append(f"kernel: running {kernel.get('running', '?')}, newest {kernel.get('newest', '?')}")
    generation = document.get("generation") or {}
    if generation:
        result = f", e2e {generation['e2e']}" if generation.get("e2e") else ""
        lines.append(f"generation: {generation.get('home_manager')}{result}")
    components = document.get("components") or {}
    lines.append(f"components: {len(components)}")
    for component, entry in components.items():
        packages = ", ".join(f"{package} {version}" for package, version in (entry.get("packages") or {}).items())
        status = entry.get("status") or "recorded"
        lines.append(f"  {component}: {status}{f' ({packages})' if packages else ''}")
    return lines


# --- Command line -----------------------------------------------------------------------------------


def cmd_record(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    return record(instance, env, push_after=not args.no_push)


def cmd_push(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    return push(instance, env, take_over=args.take_over)


def cmd_fetch(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    return fetch(instance)


def cmd_show(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    if args.name is not None and not machine.valid_name(args.name):
        raise UsageError(f"invalid machine name {args.name!r}: expected ^[a-z0-9][a-z0-9-]{{0,31}}$")
    name = args.name or _this_machine(instance, env)[0]
    shown = read(instance, name, env)
    if args.json:
        print(json.dumps(shown, indent=2, ensure_ascii=False))
    else:
        print("\n".join(_human(shown)))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward state",
        description="The state each machine observes, on the branch state/<name> of the instance remote.",
        epilog=(
            "Exit status: 0 done, 1 refusal, 2 usage error, 4 the record breaks its schema or the privacy scan found "
            "something (nothing was recorded), 6 no network or no login (the record waits; run it again)."
        ),
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="subcommand", required=True, metavar="SUBCOMMAND")
    recording = commands.add_parser(
        "record",
        help="record the state of this machine on its state branch and push it",
        description=(
            "Observes this machine (platform, kernel, active generation and its last E2E run, the enabled components "
            "of the intent that apply here, the installed versions of the packages a deb component installs or "
            "follows), holds the document to schema/state.schema.json and the intent, scans it with the privacy "
            "policy of the instance and commits state.json on refs/heads/state/<name> without touching the checkout. "
            "A record equal to the last one is no commit. Then it pushes like state push."
        ),
        allow_abbrev=False,
    )
    recording.add_argument("--no-push", action="store_true", help="record on this machine only")
    recording.set_defaults(handler=cmd_record)
    pushing = commands.add_parser(
        "push",
        help="send the records of this machine that the remote does not have",
        description=(
            "Pushes state/<name> without force. When the remote branch moved on and its records come from this "
            "machine, the record becomes one commit on its tip; when they come from another machine, the push stops. "
            "[policy] observed_state_push = false keeps the branch on this machine."
        ),
        allow_abbrev=False,
    )
    pushing.add_argument(
        "--take-over",
        action="store_true",
        help="this machine is the reinstall of the machine whose name it has: continue the records of its branch",
    )
    pushing.set_defaults(handler=cmd_push)
    fetching = commands.add_parser(
        "fetch",
        help="bring the state branches of every machine",
        description="Fetches refs/heads/state/* of the remote to refs/remotes/origin/state/*.",
        allow_abbrev=False,
    )
    fetching.set_defaults(handler=cmd_fetch)
    show = commands.add_parser(
        "show",
        help="print the recorded state of a machine",
        description=(
            "Prints the recorded state of NAME (default: this machine): the local branch of this machine, what the "
            "last state fetch brought for another. --json prints {host, this_machine, source, queued, state}."
        ),
        allow_abbrev=False,
    )
    show.add_argument("name", nargs="?", metavar="NAME", help="a machine name")
    show.add_argument("--json", action="store_true", help="print one JSON document")
    show.set_defaults(handler=cmd_show)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    env = os.environ
    try:
        instance = config.load_instance()
        code: int = args.handler(args, instance, env)
    except UsageError as usage:
        _error(str(usage))
        return EXIT_USAGE
    except Finding as finding:
        _error(str(finding))
        return EXIT_PRIVACY
    except Busy as busy:
        _wait(str(busy))
        return EXIT_OFFLINE
    except (Refusal, host.Refusal, locks.LockBusy) as refusal:
        _error(str(refusal))
        return EXIT_REFUSAL
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return EXIT_REFUSAL
    except OSError as error:
        _error(str(error))
        return EXIT_REFUSAL
    except KeyboardInterrupt:
        return 130
    return code


if __name__ == "__main__":
    sys.exit(main())
