"""``dotsteward host``: the name of this machine and its host file.

``init`` names this machine in ``<state>/machine.json`` and writes nothing else, so
the checkout stays clean and no git identity is needed: it is the first step of a
bootstrap. ``publish`` brings ``hosts/<name>.toml`` to the remote without touching the
checkout: one commit on top of the fetched tip, pushed without force, again on top
of the new tip when another machine came first. No network or no login is no failure
of the machine: nothing is stored, the next ``publish`` works it out again.

``rename`` and ``producer`` change what all machines share, so they are maintain
commits in the checkout, published the way every maintain commit is. ``check`` holds
the tree to the rules of the machines.

Exit status: 0 done, 1 refusal, 2 usage error; ``publish`` 4 for a privacy finding
(nothing was published) and 6 without a network (nothing was published, run it again).
Messages go to standard error as ``[dotsteward] ERROR:`` lines.

Python API: ``publish``, ``host_text``, ``commit_identity``, ``commit_message`` and
``MACHINE_TRAILER``, for the commits other parts of the framework make for a machine.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import json
import os
import random
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, locks, machine, report, tomlfile

EXIT_REFUSAL = 1
EXIT_USAGE = 2
EXIT_PRIVACY = report.PRIVACY_STOP
EXIT_OFFLINE = report.PARTIAL

ASSUME_YES = "DOTSTEWARD_ASSUME_YES"
# 1: this machine is the reinstall of the machine whose name it takes, like --reuse, for
# ./bootstrap.sh, which takes no such option.
MACHINE_REUSE = "DOTSTEWARD_MACHINE_REUSE"
# A file with the machine id instead of /etc/machine-id, for the tests.
MACHINE_ID_FILE = "DOTSTEWARD_MACHINE_ID_FILE"

# The application id of the machine key: systemd-id128 machine-id --app-specific=<this>.
# The key says that two records come from one machine without showing its machine id.
_MACHINE_KEY_APP_ID = "5f2c8e9a41d7463fb0a6d3c17e8b9f24"

_TAG = re.compile(r"[a-z0-9][a-z0-9-]*", re.ASCII)

# A race ends in a new attempt on top of the new tip: at most this many.
PUBLISH_ATTEMPTS = 5
FETCH_SECONDS = 60
PUSH_SECONDS = 180

_PRIVATE_TIP = "refs/dotsteward/host/tip"
MACHINE_TRAILER = "Dotsteward-Machine"

# What git prints when the remote knows the login and says no: more tries change nothing.
# Any other failure of a fetch is the network or a login this machine does not have yet
# ("Permission denied (publickey)", "Repository not found"): the file waits for both.
_REFUSED = ("permission to", "[remote rejected]")
_RACE = ("[rejected]", "non-fast-forward", "fetch first")

_INIT_DESCRIPTION = (
    "Names this machine. Without a name on the command line it asks on a terminal; without a terminal the name "
    "comes from DOTSTEWARD_MACHINE, or with DOTSTEWARD_ASSUME_YES=1 from the cleaned host name, else it is a usage "
    "error. A name in hosts/ is the name of another machine, or of this one before a reinstall: a terminal asks, "
    "without a terminal it takes --reuse or DOTSTEWARD_MACHINE_REUSE=1. Only <state>/machine.json is written; the "
    "checkout stays as it is."
)


class UsageError(Exception):
    """A usage error: exit status 2."""


class Refusal(Exception):
    """A refusal: exit status 1."""


def _error(message: str) -> None:
    print(f"[dotsteward] ERROR: {message}", file=sys.stderr)


def _warn(message: str) -> None:
    print(f"[dotsteward] WARNING: {message}", file=sys.stderr)


def _log(message: str) -> None:
    print(f"[dotsteward] {message}", flush=True)


def _on_terminal() -> bool:
    return sys.stdin.isatty()


def _ask(prompt: str) -> str:
    """One line from the terminal, without its line end."""
    print(prompt, end="", file=sys.stderr, flush=True)
    line = sys.stdin.readline()
    if not line:
        raise UsageError("no answer: the terminal closed")
    return line.strip()


def _check_name(name: str) -> str:
    if not machine.valid_name(name):
        raise UsageError(f"invalid machine name {name!r}: expected ^[a-z0-9][a-z0-9-]{{0,31}}$")
    return name


# --- The facts of this machine ----------------------------------------------------------


def _machine_id(env: Mapping[str, str]) -> str | None:
    """The machine id this machine keeps across a reinstall of its home, or None."""
    source = env.get(MACHINE_ID_FILE) or "/etc/machine-id"
    try:
        text = Path(source).read_text(encoding="ascii").strip()
    except (OSError, ValueError):
        text = ""
    if text:
        return text
    if config.runtime_platform(env) != "darwin":
        return None
    try:
        output = subprocess.run(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, timeout=30, check=False
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    found = re.search(r'"IOPlatformUUID" = "([0-9A-Fa-f-]+)"', output)
    return found.group(1) if found else None


def _machine_key(env: Mapping[str, str]) -> str:
    """`systemd-id128 machine-id --app-specific`: an HMAC of the machine id, cut to a
    version 4 UUID. Without a machine id (a container, say) it is random; the record
    keeps it."""
    machine_id = _machine_id(env)
    if machine_id is None:
        return secrets.token_hex(16)
    try:
        key = bytes.fromhex(machine_id.replace("-", ""))
    except ValueError:
        key = machine_id.encode()
    digest = bytearray(hmac.new(key, bytes.fromhex(_MACHINE_KEY_APP_ID), hashlib.sha256).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    return digest.hex()


def _os_release(env: Mapping[str, str]) -> dict[str, str]:
    path = env.get("DOTSTEWARD_OS_RELEASE") or "/etc/os-release"
    values: dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return values
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip().strip("\"'")
    return values


def _platform(env: Mapping[str, str]) -> str:
    """The operating system and its version: ubuntu-24.04, macos-15."""
    if config.runtime_platform(env) == "darwin":
        command = env.get("DOTSTEWARD_SW_VERS") or "sw_vers"
        try:
            version = subprocess.run(
                [command, "-productVersion"], capture_output=True, text=True, timeout=30, check=False
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            version = ""
        text = f"macos-{version.split('.')[0]}" if version else "macos"
    else:
        release = _os_release(env)
        text = "-".join(part for part in (release.get("ID"), release.get("VERSION_ID")) if part) or "linux"
    return re.sub(r"[^a-z0-9.-]+", "-", text.lower()).strip("-.") or "unknown"


def _suggested_name() -> str:
    """The cleaned host name, always a valid machine name."""
    try:
        text = subprocess.run(
            ["hostname", "-s"], capture_output=True, text=True, timeout=10, check=False
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        text = ""
    text = (text or socket.gethostname()).split(".")[0].lower()
    cleaned = re.sub(r"[^a-z0-9-]+", "-", text).strip("-")[:32].strip("-")
    return cleaned if machine.valid_name(cleaned) else "machine"


# --- host init --------------------------------------------------------------------------


def _ask_name(registered: Sequence[str], suggestion: str) -> str:
    """Asks on the terminal until the answer is a valid name (three times at most)."""
    if registered:
        print(f"Machines of this instance: {', '.join(registered)}.", file=sys.stderr)
        print("Is this machine a reinstall of one of them, or a new machine?", file=sys.stderr)
        prompt = f"Type its name, or a new name [{suggestion}]: "
    else:
        prompt = f"Name of this machine [{suggestion}]: "
    for _ in range(3):
        answer = _ask(prompt) or suggestion
        if machine.valid_name(answer):
            return answer
        print(f"invalid machine name {answer!r}: use a-z, 0-9 and -, at most 32 characters", file=sys.stderr)
    raise Refusal("no valid machine name")


def _chosen_name(args: argparse.Namespace, registered: Sequence[str], env: Mapping[str, str]) -> str:
    """The name for a machine without a record. Taking over a registered name takes
    an answer on a terminal or --reuse."""
    asked = args.name or env.get(machine.MACHINE_ENV) or None
    if asked is not None:
        name = _check_name(asked)
    elif env.get(ASSUME_YES) == "1":
        name = _suggested_name()
    elif _on_terminal():
        return _ask_name(registered, _suggested_name())
    else:
        raise UsageError(
            "this machine has no name yet: pass --name NAME or set DOTSTEWARD_MACHINE "
            "(DOTSTEWARD_ASSUME_YES=1 takes the host name)"
        )
    if name in registered and not args.reuse and env.get(MACHINE_REUSE) != "1":
        taken = f"{machine.HOSTS_DIR}/{name}.toml exists: it is another machine, or this one before a reinstall"
        if asked is not None and _on_terminal():
            if _ask(f"{taken}. Is this machine a reinstall of {name}? [y/N] ").lower() not in ("y", "yes"):
                raise Refusal(f"{name} stays with the machine it belongs to; pass another name")
        else:
            raise Refusal(
                f"{taken}; pass --reuse if this machine is its reinstall ({MACHINE_REUSE}=1 through ./bootstrap.sh)"
            )
    return name


def _tags(value: str | None) -> list[str] | None:
    if value is None:
        return None
    tags = [tag.strip() for tag in value.split(",") if tag.strip()]
    for tag in tags:
        if _TAG.fullmatch(tag) is None:
            raise UsageError(f"invalid tag {tag!r}: expected ^[a-z0-9][a-z0-9-]*$")
    return list(dict.fromkeys(tags))


def cmd_init(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    tags = _tags(args.tags)
    if args.name is not None:
        _check_name(args.name)
    profiles = instance.config["profiles"]["names"]
    if args.profile is not None and args.profile not in profiles:
        raise Refusal(f"{args.profile} is not a profile of this instance ({', '.join(profiles)})")
    state = config.state_root(instance, env)
    try:
        record = machine.read_machine(state)
    except config.DotstewardError as error:
        _warn(f"{error.messages[0]}; writing it again")
        record = None
    registered = machine.known_names(instance.root)
    if record is not None:
        name = str(record["name"])
        asked = args.name or env.get(machine.MACHINE_ENV) or None
        if asked is not None and asked != name:
            _check_name(asked)
            raise Refusal(f"this machine is {name}; 'dotsteward host rename {asked}' renames it")
    else:
        name = _chosen_name(args, registered, env)
    host_file = machine.read_host(instance.root, name) or {}
    kept = (record or {}).get("host")
    kept = kept if isinstance(kept, dict) else {}
    profile = (
        args.profile or machine.recorded_profile(state, instance) or kept.get("profile") or host_file.get("profile")
    )
    machine.write_machine(
        state,
        {
            "schema_version": 1,
            "name": name,
            "machine_key": (record or {}).get("machine_key") or _machine_key(env),
            "named_at": (record or {}).get("named_at")
            or datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "host": {
                "system": machine.nix_system(instance, env),
                "profile": profile,
                "platform": _platform(env),
                "tags": tags if tags is not None else kept.get("tags", host_file.get("tags", [])),
            },
        },
    )
    if name in registered:
        _log(f"this machine is {name}; {machine.HOSTS_DIR}/{name}.toml says what it declined")
    else:
        _log(f"this machine is {name}; 'dotsteward host publish' brings {machine.HOSTS_DIR}/{name}.toml to the remote")
    return 0


# --- host show, host list -----------------------------------------------------------------


def cmd_show(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    state = config.state_root(instance, env)
    record = machine.read_machine(state)
    name = machine.current_name(record, env)
    if name is None:
        if args.json:
            print(json.dumps({"name": None}))
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    recorded = record if record is not None and record.get("name") == name else {}
    document = {
        "name": name,
        "named_at": recorded.get("named_at"),
        "host": recorded.get("host"),
        "file": f"{machine.HOSTS_DIR}/{name}.toml",
        "registered": name in machine.known_names(instance.root),
        "producer": instance.config["hosts"]["producer"] == name,
    }
    if args.json:
        print(json.dumps(document, indent=2, ensure_ascii=False))
        return 0
    print(f"machine: {name}")
    host = document["host"] or {}
    for key in ("system", "profile", "platform"):
        print(f"{key}: {host.get(key) or '(none)'}")
    print(f"tags: {', '.join(host.get('tags') or []) or '(none)'}")
    print(f"file: {document['file']} ({'in this checkout' if document['registered'] else 'not in this checkout'})")
    print(f"producer: {'yes' if document['producer'] else 'no'}")
    return 0


def cmd_list(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    this = machine.current_name(machine.read_machine(config.state_root(instance, env)), env)
    producer = instance.config["hosts"]["producer"]
    machines = []
    for name in machine.known_names(instance.root):
        host = machine.read_host(instance.root, name) or {}
        machines.append(
            {
                "name": name,
                "system": host.get("system"),
                "profile": host.get("profile"),
                "platform": host.get("platform"),
                "tags": host.get("tags", []),
                "this": name == this,
                "producer": name == producer,
            }
        )
    if args.json:
        print(json.dumps({"this": this, "producer": producer, "machines": machines}, indent=2, ensure_ascii=False))
        return 0
    for entry in machines:
        marks = [mark for mark, on in (("this machine", entry["this"]), ("producer", entry["producer"])) if on]
        facts = [entry["system"], entry["profile"], entry["platform"], ",".join(entry["tags"])]
        line = " ".join(str(fact) for fact in facts if fact)
        print(f"{entry['name']}: {line or '(no facts)'}{' (' + ', '.join(marks) + ')' if marks else ''}")
    if not machines:
        print("no machine is registered in this checkout")
    return 0


# --- Git ------------------------------------------------------------------------------------


def _git(
    root: Path,
    *arguments: str,
    env: Mapping[str, str] | None = None,
    text: str | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        capture_output=True,
        text=True,
        input=text,
        timeout=timeout,
        check=False,
        env=None if env is None else {**os.environ, **env},
    )


def _git_output(root: Path, *arguments: str, env: Mapping[str, str] | None = None, text: str | None = None) -> str:
    result = _git(root, *arguments, env=env, text=text)
    if result.returncode != 0:
        raise Refusal(f"git {' '.join(arguments[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _git_net(root: Path, seconds: int, *arguments: str) -> subprocess.CompletedProcess[str] | None:
    """A git command that talks to the remote: batch mode, no prompt, a time limit
    (git_net of lib.sh). None when the time ran out."""
    environment = {
        "GIT_SSH_COMMAND": os.environ.get("GIT_SSH_COMMAND") or "ssh -o BatchMode=yes -o ConnectTimeout=15",
        "GIT_TERMINAL_PROMPT": "0",
    }
    try:
        return _git(root, *arguments, env=environment, timeout=seconds)
    except subprocess.TimeoutExpired:
        return None


def _refused(stderr: str) -> bool:
    lowered = stderr.lower()
    return any(needle in lowered for needle in _REFUSED)


def _raced(stderr: str) -> bool:
    return any(needle in stderr for needle in _RACE)


def commit_identity(root: Path, tip: str) -> list[str]:
    """`-c` options for a commit: nothing with a configured identity, else the author
    of the tip, the owner of the repository. Nothing is written to any configuration."""
    configured = [_git(root, "config", key).stdout.strip() for key in ("user.name", "user.email")]
    if all(configured):
        return []
    author, _, email = _git_output(root, "log", "-1", "--format=%an%x00%ae", tip).partition("\0")
    return ["-c", f"user.name={author}", "-c", f"user.email={email}"]


def commit_message(subject: str, name: str | None) -> str:
    """The message of a commit of the instance: the trailer says which machine made it."""
    return f"{subject}\n\n{MACHINE_TRAILER}: {name}\n" if name else f"{subject}\n"


# --- host publish ---------------------------------------------------------------------------


def _tomlkit() -> Any:
    try:
        import tomlkit
    except ImportError as error:
        raise Refusal("this command needs tomlkit; run it with the framework's own python3") from error
    return tomlkit


def host_text(current: str | None, facts: Mapping[str, Any]) -> str:
    """The text of the host file: what this machine knows about itself over CURRENT,
    whose other keys and comments stay."""
    tomlkit = _tomlkit()
    try:
        document = tomlkit.parse(current) if current is not None else tomlkit.document()
    except Exception as problem:  # tomlkit raises its own parse errors
        raise Refusal(f"the host file of this machine on the remote is not TOML: {problem}") from problem
    if "schema_version" not in document:
        document["schema_version"] = 1
    for key in ("system", "profile", "platform"):
        if facts.get(key):
            document[key] = facts[key]
    if facts.get("tags"):
        document["tags"] = list(facts["tags"])
    text: str = tomlkit.dumps(document)
    return text


def _scan_file(instance: config.Instance, path: str, text: str, env: Mapping[str, str]) -> int:
    """The privacy scan of the file a commit brings, as `dotsteward static` scans the
    content of an instance: its policy, its denylist. The public policy of the framework
    does not apply to a private instance, and the identity of the commit is no content."""
    arguments = ["--instance", str(instance.root), "scan", "--tree", "--instance-policy", "--redact"]
    denylist = config.runtime_values(instance, env)["denylist"]
    if denylist is not None:
        if not os.path.isfile(denylist):
            raise Refusal(f"the denylist file is missing or unreadable: {denylist}")
        arguments += ["--denylist", denylist]
    with tempfile.TemporaryDirectory(prefix="dotsteward-host-") as scratch:
        atomic.atomic_write(Path(scratch) / path, text, parents=True)
        result = subprocess.run(
            [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), *arguments],
            cwd=scratch,
            # A plain directory, also below the work tree of another repository.
            env={**os.environ, "GIT_CEILING_DIRECTORIES": os.path.dirname(scratch)},
            capture_output=True,
            text=True,
            check=False,
        )
    if result.returncode != 0:
        for stream, output in ((sys.stdout, result.stdout), (sys.stderr, result.stderr)):
            print(output, end="", file=stream)
    return result.returncode


def _commit_on_tip(instance: config.Instance, tip: str, name: str, text: str) -> str:
    """One commit on TIP that writes hosts/NAME.toml. Git builds it from objects alone,
    so the checkout and its index never change, and a killed run leaves nothing."""
    root = instance.root
    blob = _git_output(root, "hash-object", "-w", "--stdin", text=text)
    with tempfile.TemporaryDirectory(prefix="dotsteward-host-") as scratch:
        index = {"GIT_INDEX_FILE": os.path.join(scratch, "index")}
        _git_output(root, "read-tree", tip, env=index)
        path = f"{machine.HOSTS_DIR}/{name}.toml"
        _git_output(root, "update-index", "--add", "--cacheinfo", f"100644,{blob},{path}", env=index)
        tree = _git_output(root, "write-tree", env=index)
    return _git_output(
        root,
        *commit_identity(root, tip),
        "commit-tree",
        tree,
        "-p",
        tip,
        "-F",
        "-",
        text=commit_message(f"chore(hosts): publish {name}", name),
    )


def _fetch_tip(instance: config.Instance) -> subprocess.CompletedProcess[str] | None:
    """Fetches the branch of the instance into a private ref, without the remote-tracking
    ref of the configured refspec: concurrent fetches of that ref fail on its lock."""
    branch = instance.config["instance"]["branch"]
    return _git_net(
        instance.root,
        FETCH_SECONDS,
        "fetch",
        "--quiet",
        "--no-tags",
        "--refmap=",
        "origin",
        f"+refs/heads/{branch}:{_PRIVATE_TIP}",
    )


def cmd_publish(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    return publish(instance, env)


def publish(instance: config.Instance, env: Mapping[str, str] | None = None) -> int:
    """Brings hosts/<name>.toml of this machine to the remote: the exit status of
    ``host publish`` (OK, PARTIAL without a network, PRIVACY_STOP); Refusal when the
    remote says no."""
    env = os.environ if env is None else env
    root = instance.root
    state = config.state_root(instance, env)
    record = machine.read_machine(state)
    name = machine.current_name(record, env)
    if name is None:
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    recorded = record if record is not None and record.get("name") == name else {}
    facts: dict[str, Any] = recorded["host"] if isinstance(recorded.get("host"), dict) else {}
    branch = instance.config["instance"]["branch"]
    path = f"{machine.HOSTS_DIR}/{name}.toml"
    pushed: tuple[str, str] | None = None
    for attempt in range(1, PUBLISH_ATTEMPTS + 1):
        fetched = _fetch_tip(instance)
        if fetched is None or fetched.returncode != 0:
            detail = "" if fetched is None else fetched.stderr.strip()
            if fetched is not None and _refused(detail):
                raise Refusal(f"the remote refused the fetch: {detail}")
            print(f"[dotsteward] {path} waits: no network or no login ({detail or 'timeout'})", file=sys.stderr)
            return EXIT_OFFLINE
        tip = _git_output(root, "rev-parse", "--verify", f"{_PRIVATE_TIP}^{{commit}}")
        if pushed is not None:
            # The remote answers again. Either the answer to the push was lost, and the
            # commit is there, or the push failed for a reason of its own (a pre-push
            # hook, for example), and another try says the same.
            if _git(root, "merge-base", "--is-ancestor", pushed[0], tip).returncode == 0:
                _log(f"published {path}; 'git pull --ff-only' brings it to this checkout")
                return 0
            raise Refusal(f"the push of {path} failed: {pushed[1]}")
        shown = _git(root, "show", f"{tip}:{path}")
        current = shown.stdout if shown.returncode == 0 else None
        text = host_text(current, facts)
        if current is not None and tomlfile.loads(current) == tomlfile.loads(text):
            _log(f"{path} is on the remote; nothing to publish")
            return 0
        machine.parse_host(text, path, root)
        commit = _commit_on_tip(instance, tip, name, text)
        if _scan_file(instance, path, text, env) != 0:
            _error(f"the privacy scan found something in {path}; nothing was published")
            return EXIT_PRIVACY
        result = _git_net(root, PUSH_SECONDS, "push", "--quiet", "origin", f"{commit}:refs/heads/{branch}")
        if result is not None and result.returncode == 0:
            _log(f"published {path}; 'git pull --ff-only' brings it to this checkout")
            return 0
        detail = "timeout" if result is None else result.stderr.strip()
        if _refused(detail):
            raise Refusal(f"the remote refused the push of {path}: {detail}")
        if _raced(detail):
            time.sleep(random.uniform(0, 2**attempt) / 4)
        else:
            pushed = (commit, detail)
    reason = "no network" if pushed is not None else "other machines kept pushing"
    print(f"[dotsteward] {path} waits: {reason}", file=sys.stderr)
    return EXIT_OFFLINE


# --- host rename, host producer ---------------------------------------------------------------


def _refuse_behind(instance: config.Instance) -> None:
    """A commit on a checkout behind the remote could not be published, and what the
    checkout does not hold yet (the host file another run published) would stay as it
    is. Without a network the publish finds out."""
    root = instance.root
    fetched = _fetch_tip(instance)
    if fetched is None or fetched.returncode != 0:
        return
    if (
        _git(root, "rev-parse", "HEAD").stdout.strip() != _git(root, "rev-parse", _PRIVATE_TIP).stdout.strip()
        and _git(root, "merge-base", "--is-ancestor", "HEAD", _PRIVATE_TIP).returncode == 0
    ):
        raise Refusal("the checkout is behind the remote; 'git pull --ff-only' first")


def _require_clean_checkout(instance: config.Instance) -> None:
    root = instance.root
    branch = instance.config["instance"]["branch"]
    if _git(root, "symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip() != branch:
        raise Refusal(f"this needs the checkout on {branch}: {root}")
    if _git(root, "status", "--porcelain", "--untracked-files=normal").stdout.strip():
        raise Refusal(f"this commits to the checkout, which is not clean: {root}")


def _restore_checkout(root: Path) -> None:
    """Back to HEAD: the checkout was clean before this command changed it."""
    _git(root, "reset", "--quiet", "HEAD")
    _git(root, "checkout", "--quiet", "--", ".")
    _git(root, "clean", "-fdq", "--", machine.HOSTS_DIR, ".dotsteward")


def _edit_workstation(instance: config.Instance, edit: Any) -> None:
    """Applies EDIT to the document of workstation.toml, comments kept."""
    tomlkit = _tomlkit()
    document = tomlkit.parse(instance.file.read_text(encoding="utf-8"))
    edit(document)
    atomic.atomic_write(instance.file, tomlkit.dumps(document))


def _generate(instance: config.Instance) -> None:
    status = subprocess.run(
        [str(config.FRAMEWORK_ROOT / "cli" / "dotsteward"), "--instance", str(instance.root), "generate"], check=False
    ).returncode
    if status != 0:
        raise Refusal(f"dotsteward generate failed (exit {status})")


def _commit_maintain(instance: config.Instance, subject: str, name: str | None) -> None:
    """The change as one commit, its mirrors regenerated, and what publishes it."""
    root = instance.root
    _generate(instance)
    _git_output(root, "add", "-A")
    head = _git_output(root, "rev-parse", "HEAD")
    _git_output(root, *commit_identity(root, head), "commit", "--quiet", "-F", "-", text=commit_message(subject, name))
    _log(f"committed: {subject}")
    _log("publish it: 'dotsteward gate --scope maintain', then 'dotsteward txn publish --scope maintain'")


def cmd_producer(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    name = _check_name(args.name)
    state = config.state_root(instance, env)
    this = machine.current_name(machine.read_machine(state), env)
    if name != this and name not in machine.known_names(instance.root):
        raise Refusal(f"{name} is neither this machine nor in {machine.HOSTS_DIR}/")
    if instance.config["hosts"]["producer"] == name:
        _log(f"{name} is the producer already")
        return 0

    def edit(document: Any) -> None:
        if "hosts" not in document:
            document["hosts"] = _tomlkit().table()
        document["hosts"]["producer"] = name

    with locks.instance_lock("host", state_root=state):
        _refuse_behind(instance)
        _require_clean_checkout(instance)
        try:
            _edit_workstation(instance, edit)
            _commit_maintain(instance, f"chore(hosts): make {name} the producer", this)
        except (Refusal, config.DotstewardError):
            _restore_checkout(instance.root)
            raise
    return 0


def _rename_in_list(names: list[Any], old: str, new: str) -> list[Any]:
    return [new if item == old else item for item in names]


def _rename_references(instance: config.Instance, old: str, new: str) -> None:
    """Everything the tree says about the name: the machines of the lock and of the
    plugin tables, and the producer. A later release moves the state branch here too."""

    def edit(document: Any) -> None:
        hosts = document.get("hosts")
        if hosts is not None and hosts.get("producer") == old:
            hosts["producer"] = new
        for table in document.get("components", {}).values():
            options = table.get("options") if hasattr(table, "get") else None
            for plugin in (options.get("plugins") or []) if options is not None else []:
                if hasattr(plugin, "get") and isinstance(plugin.get("machines"), list):
                    plugin["machines"] = _rename_in_list(list(plugin["machines"]), old, new)

    _edit_workstation(instance, edit)
    lock_path = instance.root / instance.config["skills"]["lock"]
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    changed = False
    for key in ("skills", "own_plugins"):
        for entry in lock.get(key) or [] if isinstance(lock, dict) else []:
            if isinstance(entry, dict) and old in (entry.get("machines") or []):
                entry["machines"] = _rename_in_list(entry["machines"], old, new)
                changed = True
    if changed:
        atomic.atomic_write(lock_path, json.dumps(lock, indent=2, ensure_ascii=False) + "\n")


def _tree_mentions(instance: config.Instance, name: str) -> bool:
    """Whether the checkout says anything about NAME."""
    if name in machine.known_names(instance.root) or instance.config["hosts"]["producer"] == name:
        return True
    return any(
        name in (entry.get("machines") or [])
        for entry in machine.scoped_entries(instance)
        if isinstance(entry.get("machines"), list)
    )


def cmd_rename(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    new = _check_name(args.name)
    state = config.state_root(instance, env)
    record = machine.read_machine(state)
    if record is None:
        raise Refusal("this machine has no name yet: 'dotsteward host init' names it")
    old = str(record["name"])
    if new == old:
        _log(f"this machine is {old} already")
        return 0
    if new in machine.known_names(instance.root):
        raise Refusal(f"{machine.HOSTS_DIR}/{new}.toml exists: that name belongs to another machine")
    with locks.instance_lock("host", state_root=state):
        _refuse_behind(instance)
        if _tree_mentions(instance, old):
            _require_clean_checkout(instance)
            try:
                if old in machine.known_names(instance.root):
                    _git_output(
                        instance.root,
                        "mv",
                        f"{machine.HOSTS_DIR}/{old}.toml",
                        f"{machine.HOSTS_DIR}/{new}.toml",
                    )
                _rename_references(instance, old, new)
                _commit_maintain(instance, f"chore(hosts): rename {old} to {new}", new)
            except (Refusal, config.DotstewardError):
                _restore_checkout(instance.root)
                raise
        machine.write_machine(state, {**record, "name": new})
    _log(f"this machine is {new}")
    return 0


# --- host check ---------------------------------------------------------------------------------


def cmd_check(args: argparse.Namespace, instance: config.Instance, env: Mapping[str, str]) -> int:
    problems = machine.check_problems(instance)
    for problem in problems:
        _error(problem)
    if problems:
        return EXIT_REFUSAL
    _log(f"machines: {len(machine.known_names(instance.root))} registered, no problem")
    return 0


# --- Command line ---------------------------------------------------------------------------------


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dotsteward host",
        description="The name of this machine and its host file hosts/<name>.toml.",
        epilog=(
            "Exit status: 0 done, 1 refusal, 2 usage error; host publish: 4 a privacy finding, "
            "6 no network or no login. Both publish nothing, and 6 asks to run it again."
        ),
        allow_abbrev=False,
    )
    commands = parser.add_subparsers(dest="subcommand", required=True, metavar="SUBCOMMAND")
    init = commands.add_parser("init", help="name this machine", description=_INIT_DESCRIPTION, allow_abbrev=False)
    init.add_argument("--name", metavar="NAME", help="the name of this machine: ^[a-z0-9][a-z0-9-]{0,31}$")
    init.add_argument(
        "--profile",
        metavar="PROFILE",
        help="the profile this machine runs (default: the one of its last rebuild, never a default of the instance)",
    )
    init.add_argument("--tags", metavar="TAG,TAG", help="the tags of this machine")
    init.add_argument(
        "--reuse", action="store_true", help="this machine is the reinstall of a machine whose name is in hosts/"
    )
    init.set_defaults(handler=cmd_init)
    publish = commands.add_parser(
        "publish",
        help="bring hosts/<name>.toml to the remote",
        description=(
            "Writes hosts/<name>.toml on the remote branch in one commit without force, and leaves the checkout as "
            "it is. The other keys of the file stay. Without a network or a login it exits 6 and nothing is lost: "
            "it works out the same again next time."
        ),
        allow_abbrev=False,
    )
    publish.set_defaults(handler=cmd_publish)
    show = commands.add_parser(
        "show", help="print this machine", description="Prints this machine.", allow_abbrev=False
    )
    show.add_argument("--json", action="store_true", help="print one JSON document")
    show.set_defaults(handler=cmd_show)
    listing = commands.add_parser(
        "list",
        help="print the machines of this checkout",
        description="Prints the machines hosts/ of this checkout registers.",
        allow_abbrev=False,
    )
    listing.add_argument("--json", action="store_true", help="print one JSON document")
    listing.set_defaults(handler=cmd_list)
    rename = commands.add_parser(
        "rename",
        help="give this machine another name",
        description=(
            "Gives this machine another name: its host file, the machines lists that name it and the producer move in "
            "one commit of the checkout, which needs to be clean. Publish that commit like any maintain commit."
        ),
        allow_abbrev=False,
    )
    rename.add_argument("name", metavar="NEW", help="the new name")
    rename.set_defaults(handler=cmd_rename)
    producer = commands.add_parser(
        "producer",
        help="name the machine that moves the upstream values",
        description=(
            "Writes [hosts] producer: the machine that moves flake.lock, the pins and the third-party skills, in one "
            "commit of the checkout, which needs to be clean. Publish that commit like any maintain commit."
        ),
        allow_abbrev=False,
    )
    producer.add_argument("name", metavar="NAME", help="this machine, or a machine in hosts/")
    producer.set_defaults(handler=cmd_producer)
    check = commands.add_parser(
        "check",
        help="check the host files and the machines lists of the tree",
        description=(
            "Checks every hosts/<name>.toml against schema/host.schema.json and nix.systems and profiles.names, and "
            "every machines list of the skills lock and of the plugin tables: not empty, and only names in hosts/."
        ),
        allow_abbrev=False,
    )
    check.set_defaults(handler=cmd_check)
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
    except (Refusal, locks.LockBusy) as refusal:
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
