"""A new dotsteward instance from the framework template: ``dotsteward init``.

Command line (used by ``cli/commands/init.sh``)::

    python3 -m dotsteward_cli.init --dir DIR --remote URL [OPTION]...

The steps, all or nothing (the instance is composed and checked in a
temporary directory, moved into ``--dir`` only when every step passed and
committed there; a failed commit puts ``--dir`` back as it was):

1. The target: a missing or empty ``--dir`` gets a copy of the framework's
   ``template/``; a directory that ``nix flake init -t`` filled (its
   ``workstation.toml`` holds the ``# dotsteward:template`` line) is filled
   in place, unless it is a git repository kept elsewhere (a ``.git`` file
   or symbolic link, or ``core.worktree``), and the files executable in the
   framework template get the executable bits ``nix flake init`` drops;
   anything else is refused.
2. The check identity from ``--username`` and ``--home``, else ``$USER``
   and ``$HOME``, through ``require_safe_identity`` (``cli/lib/lib.sh``).
3. ``workstation.toml``, edited with tomlkit so the template's comments
   stay: identity, instance, systems, the two profiles (the first adopts,
   the second is fresh; ``default`` and ``check`` are the first,
   ``bootstrap`` the second), the components with their methods and the
   contribution mode. It must pass the configuration reader's validation.
4. The locks: ``versions.lock.json`` and ``agent/skills.lock.json`` are the
   template's with the chosen components' seeds
   (``modules/components/<name>/seed.json``) deep-merged in, refusing a leaf
   two sources set differently; the seeds' flake inputs go between the
   ``# dotsteward:inputs:begin`` and ``# dotsteward:inputs:end`` lines of
   ``flake.nix``, whose dotsteward input gets ``--framework-ref`` or
   ``--framework-url``.
5. ``nix flake lock``, ``dotsteward sync --nix`` and ``dotsteward pins check
   --nix`` on the composed instance.
6. The instance moves into ``--dir``. Unless ``--no-git``, in ``--dir``
   itself (so git uses the identity, signing and hooks it chooses for that
   location, as for the user's own commits): ``git init -b main`` (kept
   when the directory is a repository already), ``git add -A`` and the
   commit ``chore: initialize dotsteward instance``.
7. The next steps are printed (``--json``: one JSON document on standard
   output, and the output of the steps goes to standard error): the remote,
   the gate, the first push (the order of the instance's ``AGENTS.md``),
   then the bootstrap or the rebuild.

``init`` never prompts and never writes outside ``--dir`` (the temporary
directory below ``TMPDIR`` is removed on every exit). Exit status 0, 1 for
a refusal or a failed step (``--dir`` is left as it was), 2 for a usage
error. Messages go to standard error as ``[dotsteward] ERROR:`` lines.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime
import errno
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import tomllib
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType
from typing import Any, NoReturn, TypeVar

from dotsteward_cli import config

PREFIX = "[dotsteward]"
EXIT_REFUSAL = 1
EXIT_USAGE = 2

T = TypeVar("T")

FRAMEWORK_ROOT = config.FRAMEWORK_ROOT

TEMPLATE_MARKER = "# dotsteward:template"
INPUTS_BEGIN = "# dotsteward:inputs:begin"
INPUTS_END = "# dotsteward:inputs:end"
COMMIT_SUBJECT = "chore: initialize dotsteward instance"
BRANCH = "main"

CONFIG_FILE = "workstation.toml"
VERSIONS_LOCK = "versions.lock.json"
SKILLS_LOCK = "agent/skills.lock.json"
FLAKE_FILE = "flake.nix"

SYSTEMS = ("x86_64-linux", "aarch64-darwin")
PLATFORMS = ("linux", "darwin")
DEFAULT_PROFILES = ("workstation", "fresh")
CONTRIBUTE_MODES = ("fork", "owner")
# Flake inputs a seed may not declare: the instance's own inputs.
RESERVED_INPUTS = ("self", "nixpkgs", "home-manager", "dotsteward")
NIX_FEATURES = ("--extra-experimental-features", "nix-command flakes")
# Variables the steps must not inherit: they name another instance, CLI or
# framework than the one init composes.
STEP_ENV_REMOVED = ("DOTSTEWARD_INSTANCE", "DOTSTEWARD_CLI", "DOTSTEWARD_FRAMEWORK_OVERRIDE")
# Variables that point git at another repository than the one it finds from
# its working directory (`git rev-parse --local-env-vars` without the
# GIT_CONFIG* carriers of the identity, plus GIT_NAMESPACE). A git hook,
# `git rebase -x` or a tool may export them; init removes them so every git
# call and every step works on the target or the staged repository only.
GIT_REPOSITORY_ENV = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_PREFIX",
    "GIT_NAMESPACE",
    "GIT_SHALLOW_FILE",
    "GIT_GRAFT_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
)
# Seconds a step's processes get to exit after SIGTERM when init stops.
STOP_GRACE_SECONDS = 5
# The directory inside a non-empty target that holds its previous entries
# until the instance is in place and committed.
PREVIOUS_PREFIX = ".dotsteward-init-previous."
# Where a daemon or single-user Nix installation puts nix when PATH lacks it.
NIX_PROFILE_DIRS = ("/nix/var/nix/profiles/default/bin", "~/.nix-profile/bin")

CONFIG_HEADER = """\
# The instance configuration (schema 1), written by `dotsteward init`. The
# framework documents every key in docs/workstation-toml.md and
# schema/workstation.schema.json of its repository.
"""

FRAMEWORK_REF = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
# A flake reference or git remote written into flake.nix or workstation.toml:
# printable, without whitespace, quotes, backslashes or dollar signs.
PLAIN_REFERENCE = re.compile(r"[^\s\"'\\$\x00-\x1f\x7f]+")
INPUT_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
GITHUB_REFERENCE = re.compile(r"(github:[^/]+/[^/]+)/[^/?#]+")

USAGE = "Usage: dotsteward init --dir DIR --remote URL [OPTION]..."


class UsageError(Exception):
    """A usage error: exit 2."""


class Refusal(Exception):
    """A refusal or a failed step: exit 1, nothing written to --dir."""


class Interrupted(BaseException):
    """A termination signal; unwinds like KeyboardInterrupt."""

    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


# --- Output -----------------------------------------------------------------------


def _write(text: str, stream: Any) -> None:
    """Writes one line as UTF-8 whatever the locale (paths keep their bytes)."""
    stream.flush()
    stream.buffer.write((text + "\n").encode("utf-8", "surrogateescape"))
    stream.buffer.flush()


def log(text: str, json_mode: bool) -> None:
    """A progress line: standard output, or standard error with --json."""
    _write(f"{PREFIX} {text}", sys.stderr if json_mode else sys.stdout)


def error(text: str) -> None:
    _write(f"{PREFIX} ERROR: {text}", sys.stderr)


# --- Command line -------------------------------------------------------------------


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:  # type: ignore[override]
        raise UsageError(message)


def _parser() -> _Parser:
    parser = _Parser(
        prog="dotsteward init",
        usage="dotsteward init --dir DIR --remote URL [OPTION]...",
        description=(
            "Create a dotsteward instance from the framework template in DIR (missing, empty, or "
            "filled by `nix flake init -t`), lock it, sync its mirrors, check its pins and commit it. "
            "All or nothing: on a refusal or a failed step DIR is left as it was."
        ),
        epilog="Exit status: 0 success, 1 refusal or failed step, 2 usage error.",
        allow_abbrev=False,
    )
    parser.add_argument("--dir", required=True, metavar="DIR", help="the instance directory")
    parser.add_argument(
        "--remote",
        required=True,
        metavar="URL",
        help="instance.remote: exactly what `git remote get-url origin` will print",
    )
    parser.add_argument("--username", metavar="U", help="check identity user name (default: $USER)")
    parser.add_argument("--home", metavar="H", help="check identity home directory (default: $HOME)")
    parser.add_argument("--name", metavar="N", help="instance.name (default: the name of DIR)")
    parser.add_argument(
        "--checkout",
        metavar="PATH",
        help="instance.checkout, the canonical clone (default: DIR, as ~/... when it is below $HOME)",
    )
    parser.add_argument(
        "--components",
        metavar="LIST",
        default="",
        help="comma-separated catalog components to enable (default: none)",
    )
    parser.add_argument(
        "--method",
        action="append",
        default=[],
        metavar="COMPONENT=METHOD",
        help="the install method of a chosen component (repeatable)",
    )
    parser.add_argument(
        "--method-platform",
        action="append",
        default=[],
        metavar="COMPONENT=linux:METHOD,darwin:METHOD",
        help="per-platform install methods of a chosen component (repeatable)",
    )
    parser.add_argument(
        "--systems",
        metavar="LIST",
        default=SYSTEMS[0],
        help=f"nix.systems, the first one primary (from {', '.join(SYSTEMS)}; default: {SYSTEMS[0]})",
    )
    parser.add_argument(
        "--profiles",
        metavar="ADOPT_NAME,FRESH_NAME",
        default=",".join(DEFAULT_PROFILES),
        help=(
            "the adopt profile (default and check) and the fresh profile (bootstrap) "
            f"(default: {','.join(DEFAULT_PROFILES)})"
        ),
    )
    parser.add_argument("--allow-unfree", action="store_true", help="nix.allow_unfree = true")
    parser.add_argument(
        "--contribute", choices=CONTRIBUTE_MODES, default="fork", help="upstream.contribute (default: fork)"
    )
    framework = parser.add_mutually_exclusive_group()
    framework.add_argument(
        "--framework-ref", metavar="vX.Y.Z", help="the framework release tag the dotsteward input pins"
    )
    framework.add_argument("--framework-url", metavar="URL", help="the whole flake reference of the dotsteward input")
    parser.add_argument("--no-git", action="store_true", help="neither initialize git nor commit")
    parser.add_argument(
        "--non-interactive", action="store_true", help="never prompt (init never prompts; accepted for scripts)"
    )
    parser.add_argument("--json", action="store_true", help="print the result as one JSON document")
    return parser


@dataclass
class Options:
    dir: Path
    remote: str
    username: str | None
    home: str | None
    name: str | None
    checkout: str | None
    components: list[str]
    methods: dict[str, str]
    method_platforms: dict[str, dict[str, str]]
    systems: list[str]
    adopt_profile: str
    fresh_profile: str
    allow_unfree: bool
    contribute: str
    framework_ref: str | None
    framework_url: str | None
    git: bool
    json: bool


def _split_list(value: str, label: str) -> list[str]:
    items = [item.strip() for item in value.split(",")]
    items = [item for item in items if item]
    duplicates = sorted({item for item in items if items.count(item) > 1})
    if duplicates:
        raise UsageError(f"{label}: {', '.join(duplicates)} given more than once")
    return items


def _plain(value: str, label: str) -> str:
    if not PLAIN_REFERENCE.fullmatch(value):
        raise UsageError(f"{label} must be non-empty, without whitespace, quotes, backslashes or $: {value!r}")
    return value


def _component_pair(value: str, label: str, components: Sequence[str]) -> tuple[str, str]:
    name, sep, rest = value.partition("=")
    if not sep or not name or not rest:
        raise UsageError(f"{label} expects COMPONENT=VALUE, got {value!r}")
    if name not in components:
        raise UsageError(f"{label} {value}: {name} is not among the chosen components")
    return name, rest


def parse_options(argv: Sequence[str], catalog: Sequence[str]) -> Options:
    args = _parser().parse_args(argv)

    components = _split_list(args.components, "--components")
    unknown = [name for name in components if name not in catalog]
    if unknown:
        raise UsageError(f"unknown component: {', '.join(unknown)} (the catalog: {', '.join(catalog)})")
    components = [name for name in catalog if name in components]

    methods: dict[str, str] = {}
    for value in args.method:
        name, method = _component_pair(value, "--method", components)
        if name in methods:
            raise UsageError(f"--method: {name} given more than once")
        methods[name] = method

    method_platforms: dict[str, dict[str, str]] = {}
    for value in args.method_platform:
        name, rest = _component_pair(value, "--method-platform", components)
        if name in method_platforms:
            raise UsageError(f"--method-platform: {name} given more than once")
        by_platform: dict[str, str] = {}
        for pair in rest.split(","):
            platform_name, sep, method = pair.partition(":")
            if not sep or platform_name not in PLATFORMS or not method:
                raise UsageError(f"--method-platform {value}: expected PLATFORM:METHOD pairs, PLATFORM linux or darwin")
            if platform_name in by_platform:
                raise UsageError(f"--method-platform {value}: {platform_name} given more than once")
            by_platform[platform_name] = method
        method_platforms[name] = by_platform

    systems = _split_list(args.systems, "--systems")
    if not systems:
        raise UsageError("--systems: at least one system is required")
    for system in systems:
        if system not in SYSTEMS:
            raise UsageError(f"--systems: unsupported system {system} (supported: {', '.join(SYSTEMS)})")

    profiles = [item.strip() for item in args.profiles.split(",")]
    if len(profiles) != 2 or not all(profiles) or profiles[0] == profiles[1]:
        raise UsageError(f"--profiles expects two different names ADOPT_NAME,FRESH_NAME, got {args.profiles!r}")
    for profile in profiles:
        if profile in config.PROFILE_KEYS:
            raise UsageError(f"--profiles: {profile} is a key of [profiles], not a profile name")

    if args.framework_ref is not None and not FRAMEWORK_REF.fullmatch(args.framework_ref):
        raise UsageError(f"--framework-ref expects a release tag vX.Y.Z, got {args.framework_ref!r}")
    if args.framework_url is not None:
        _plain(args.framework_url, "--framework-url")
    if not args.dir:
        raise UsageError("--dir must not be empty")

    return Options(
        dir=Path(os.path.abspath(args.dir)),
        remote=_plain(args.remote, "--remote"),
        username=args.username,
        home=args.home,
        name=args.name,
        checkout=args.checkout,
        components=components,
        methods=methods,
        method_platforms=method_platforms,
        systems=systems,
        adopt_profile=profiles[0],
        fresh_profile=profiles[1],
        allow_unfree=args.allow_unfree,
        contribute=args.contribute,
        framework_ref=args.framework_ref,
        framework_url=args.framework_url,
        git=not args.no_git,
        json=args.json,
    )


# --- The target ---------------------------------------------------------------------


def is_template_dir(directory: Path) -> bool:
    """Whether a directory holds the template as `nix flake init -t` leaves
    it: its workstation.toml has the template marker line."""
    try:
        text = (directory / CONFIG_FILE).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    return any(line.strip() == TEMPLATE_MARKER for line in text.splitlines())


STANDALONE_HINT = "run init in a standalone repository or a new directory"


def require_standalone_repository(directory: Path, env: Mapping[str, str]) -> None:
    """A template directory that is a git repository must hold the whole
    repository in its own .git directory: init copies it into a temporary
    directory and runs git there, so a .git file (a linked worktree, a
    submodule or a --separate-git-dir checkout), a .git symbolic link or a
    core.worktree setting would point those git calls at another
    repository's git directory or work tree."""
    git_entry = directory / ".git"
    if git_entry.is_symlink():
        raise Refusal(f"{git_entry} is a symbolic link to another directory; {STANDALONE_HINT}")
    if not git_entry.exists():
        return
    if not git_entry.is_dir():
        raise Refusal(
            f"{directory} is a linked git worktree or a submodule (its .git is a file that points at "
            f"another repository's git directory); {STANDALONE_HINT}"
        )
    try:
        result = subprocess.run(
            ["git", "config", "--includes", "--file", str(git_entry / "config"), "--get", "core.worktree"],
            env=dict(env),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as problem:
        raise Refusal(f"{directory} is a git repository and git could not run: {problem.strerror}") from problem
    worktree = result.stdout.strip()
    if result.returncode == 0 and worktree:
        raise Refusal(
            f"{git_entry / 'config'} sets core.worktree ({worktree}), so git works on another directory; "
            f"{STANDALONE_HINT}"
        )


def classify_target(directory: Path, env: Mapping[str, str]) -> str:
    """missing, empty or template; anything else is refused."""
    if not directory.exists() and not directory.is_symlink():
        parent = directory.parent
        if not parent.is_dir():
            raise Refusal(f"the parent directory of --dir does not exist: {parent}")
        return "missing"
    if not directory.is_dir():
        raise Refusal(f"--dir is not a directory: {directory}")
    try:
        entries = os.listdir(directory)
    except OSError as problem:
        raise Refusal(f"cannot read --dir {directory}: {problem.strerror}") from problem
    if not entries:
        return "empty"
    if is_template_dir(directory):
        require_standalone_repository(directory, env)
        return "template"
    raise Refusal(
        f"{directory} is not empty and is not a dotsteward template "
        f'(no "{TEMPLATE_MARKER}" line in its {CONFIG_FILE}); choose a new or empty directory'
    )


# --- Identity -----------------------------------------------------------------------


@dataclass
class Identity:
    username: str
    home: str
    platform: str

    @property
    def home_key(self) -> str:
        """The [identity] key of the check home on this platform."""
        return "darwin_home" if self.platform == "darwin" else "home"

    @property
    def default_home(self) -> str:
        return f"/Users/{self.username}" if self.platform == "darwin" else f"/home/{self.username}"


def resolve_identity(options: Options, env: Mapping[str, str]) -> Identity:
    """The check identity (flags, else USER and HOME), accepted by
    require_safe_identity of cli/lib/lib.sh on this machine."""
    username = options.username if options.username is not None else env.get("USER", "")
    home = options.home if options.home is not None else env.get("HOME", "")
    try:
        platform_name = config.runtime_platform(env)
    except config.DotstewardError as problem:
        raise Refusal(str(problem)) from problem
    bash = shutil.which("bash", path=env.get("PATH"))
    if bash is None:
        raise Refusal("bash is required on PATH")
    guard_env = {**env, "USER": username, "HOME": home}
    result = subprocess.run(
        [bash, "-c", 'source "$1" && require_safe_identity', "bash", str(FRAMEWORK_ROOT / "cli" / "lib" / "lib.sh")],
        env=guard_env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        message = lines[-1] if lines else f"the identity guard failed (exit {result.returncode})"
        message = message.removeprefix(f"{PREFIX} ERROR: ")
        raise Refusal(f"{message} (identity {username!r}, home {home!r})")
    return Identity(username=username, home=home, platform=platform_name)


def _git_succeeds(argv: Sequence[str], cwd: Path, env: Mapping[str, str]) -> bool:
    try:
        result = subprocess.run(
            ["git", *argv], cwd=cwd, env=dict(env), stdin=subprocess.DEVNULL, capture_output=True, check=False
        )
    except OSError as problem:
        raise Refusal(f"git could not run: {problem.strerror}; install git, or pass --no-git") from problem
    return result.returncode == 0


def require_git_identity(directory: Path, env: Mapping[str, str]) -> None:
    """Refuses before any write or Nix step when the commit in --dir would
    have no identity. The commit itself runs in --dir, where git chooses the
    identity by the repository's location, so this check is exact only for
    a directory that is a repository already. Before `git init` creates one
    an includeIf rule (or a template directory's config) may still supply
    the identity, so then it refuses only when no such configuration
    exists; otherwise the commit decides, and its failure leaves --dir as it
    was."""
    repository = (directory / ".git").is_dir()
    cwd = directory if directory.is_dir() else directory.parent
    if all(
        _git_succeeds(["-c", "user.useConfigOnly=true", "var", variable], cwd, env)
        for variable in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT")
    ):
        return
    if not repository and (
        env.get("GIT_TEMPLATE_DIR")
        or _git_succeeds(["config", "--includes", "--get-regexp", r"^(includeif\.|init\.templatedir$)"], cwd, env)
    ):
        return
    raise Refusal(
        "git has no identity for the commit; set user.name and user.email (git config --global), or pass --no-git"
    )


def find_nix(env: dict[str, str]) -> None:
    """Puts a Nix installation on PATH (the daemon profile when PATH lacks
    it, like source_nix_daemon of cli/lib/lib.sh), or refuses."""
    if shutil.which("nix", path=env.get("PATH")) is not None:
        return
    for directory in NIX_PROFILE_DIRS:
        expanded = os.path.join(env.get("HOME", ""), directory[2:]) if directory.startswith("~/") else directory
        if os.access(os.path.join(expanded, "nix"), os.X_OK):
            env["PATH"] = f"{expanded}{os.pathsep}{env.get('PATH', '')}"
            return
    raise Refusal("Nix is required; run the framework's template/bootstrap.sh --install-nix-only first")


# --- Seeds and lock composition -------------------------------------------------------


@dataclass
class Seed:
    component: str
    flake_inputs: dict[str, dict[str, Any]]
    versions_lock: dict[str, Any]
    skills_lock: dict[str, Any]


def load_seeds(components: Sequence[str]) -> list[Seed]:
    schema_path = FRAMEWORK_ROOT / "schema" / "seed.schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as problem:
        raise Refusal(f"cannot read the seed schema {schema_path}: {problem}") from problem
    validator = config._Validator(schema)
    seeds = []
    for name in components:
        relative = f"modules/components/{name}/seed.json"
        path = FRAMEWORK_ROOT / relative
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError as problem:
            raise Refusal(f"component {name} has no seed ({relative})") from problem
        except (OSError, ValueError) as problem:
            raise Refusal(f"cannot read the seed {relative}: {problem}") from problem
        messages = validator.validate([], schema, document)
        if not messages and document["component"] != name:
            messages.append(f"component {document['component']!r} does not match its directory {name}")
        if messages:
            raise Refusal(f"invalid seed {relative}: {'; '.join(messages)}")
        inputs = document["flake_inputs"]
        locked = document["versions_lock"].get("flake_inputs", {})
        for input_name in inputs:
            if input_name in RESERVED_INPUTS:
                raise Refusal(f"invalid seed {relative}: the flake input {input_name} belongs to the instance")
            if input_name not in locked:
                raise Refusal(
                    f"invalid seed {relative}: flake input {input_name} has no versions_lock.flake_inputs entry"
                )
        seeds.append(
            Seed(
                component=name,
                flake_inputs=inputs,
                versions_lock=document["versions_lock"],
                skills_lock=document.get("skills_lock", {}),
            )
        )
    return seeds


def _path_text(path: Sequence[str]) -> str:
    return ".".join(path)


def deep_merge(
    target: dict[str, Any],
    fragment: Mapping[str, Any],
    origin: str,
    owners: dict[tuple[str, ...], str],
    label: str,
    path: tuple[str, ...] = (),
) -> None:
    """Merges ``fragment`` into ``target`` (objects recursively; any other
    value is a leaf that must equal what is there). ``owners`` maps the
    paths merged so far to their origin, for the conflict message."""
    for key, value in fragment.items():
        here = (*path, key)
        if key not in target:
            target[key] = copy.deepcopy(value)
            owners[here] = origin
            continue
        current = target[key]
        if isinstance(current, dict) and isinstance(value, dict):
            deep_merge(current, value, origin, owners, label, here)
            continue
        if current == value and type(current) is type(value):
            continue
        owner = next((owners[here[:size]] for size in range(len(here), 0, -1) if here[:size] in owners), "the template")
        raise Refusal(
            f"the seeds conflict in {label} at {_path_text(here)}: {owner} sets {json.dumps(current)}, "
            f"{origin} sets {json.dumps(value)}"
        )


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as problem:
        raise Refusal(f"cannot read {label}: {problem}") from problem
    if not isinstance(document, dict):
        raise Refusal(f"{label} is not a JSON object")
    return document


def dump_lock(document: Mapping[str, Any]) -> str:
    """The pins engine's lock serialization."""
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def compose_lock(
    base: dict[str, Any], fragments: Sequence[tuple[str, Mapping[str, Any]]], label: str, timestamp: str
) -> str:
    """The lock ``base`` with every (origin, fragment) merged in; its
    generated_at becomes ``timestamp`` when the content changed."""
    composed = copy.deepcopy(base)
    owners: dict[tuple[str, ...], str] = {}
    for origin, fragment in fragments:
        deep_merge(composed, fragment, f"the seed of {origin}", owners, label)
    if composed != base and "generated_at" in composed:
        composed["generated_at"] = timestamp
    return dump_lock(composed)


# --- flake.nix ----------------------------------------------------------------------


def nix_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
    escaped = escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return f'"{escaped}"'


def collect_inputs(seeds: Sequence[Seed]) -> dict[str, dict[str, Any]]:
    inputs: dict[str, dict[str, Any]] = {}
    origins: dict[str, str] = {}
    for seed in seeds:
        for name, spec in seed.flake_inputs.items():
            if name in inputs and inputs[name] != spec:
                raise Refusal(
                    f"the seeds of {origins[name]} and {seed.component} declare the flake input {name} differently"
                )
            inputs.setdefault(name, spec)
            origins.setdefault(name, seed.component)
    return inputs


def render_inputs(inputs: Mapping[str, Mapping[str, Any]], indent: str) -> list[str]:
    lines = []
    for name, spec in inputs.items():
        if not INPUT_NAME.fullmatch(name):
            raise Refusal(f"invalid flake input name: {name!r}")
        lines.append(f"{indent}{name}.url = {nix_string(spec['url'])};")
        if spec.get("flake") is False:
            lines.append(f"{indent}{name}.flake = false;")
        for follower, target in spec.get("inputs", {}).items():
            if not INPUT_NAME.fullmatch(follower):
                raise Refusal(f"invalid input name {follower!r} in the follows of {name}")
            lines.append(f"{indent}{name}.inputs.{follower}.follows = {nix_string(target['follows'])};")
    return lines


def _marker_line(lines: Sequence[str], marker: str) -> int:
    found = [index for index, line in enumerate(lines) if line.strip() == marker]
    if len(found) != 1:
        raise Refusal(f"{FLAKE_FILE} must hold the line {marker!r} exactly once (found {len(found)})")
    return found[0]


DOTSTEWARD_BLOCK = re.compile(r"\s*dotsteward\s*=\s*\{\s*")
DOTSTEWARD_URL_LINE = re.compile(r'(\s*dotsteward\.url\s*=\s*)"([^"]*)"(\s*;\s*)')
URL_LINE = re.compile(r'(\s*url\s*=\s*)"([^"]*)"(\s*;\s*)')


def _dotsteward_url_line(lines: Sequence[str]) -> tuple[int, re.Match[str]]:
    for index, line in enumerate(lines):
        match = DOTSTEWARD_URL_LINE.fullmatch(line)
        if match:
            return index, match
        if DOTSTEWARD_BLOCK.fullmatch(line):
            for inner in range(index + 1, len(lines)):
                if lines[inner].strip().startswith("}"):
                    break
                match = URL_LINE.fullmatch(lines[inner])
                if match:
                    return inner, match
    raise Refusal(f"{FLAKE_FILE} has no dotsteward input url")


def compose_flake(text: str, inputs: Mapping[str, Mapping[str, Any]], options: Options) -> tuple[str, str]:
    """flake.nix with the seeds' inputs between the markers and the
    framework reference set; returns the text and the framework URL."""
    lines = text.split("\n")
    begin = _marker_line(lines, INPUTS_BEGIN)
    end = _marker_line(lines, INPUTS_END)
    if end < begin:
        raise Refusal(f"{FLAKE_FILE}: {INPUTS_END!r} comes before {INPUTS_BEGIN!r}")
    indent = lines[begin][: len(lines[begin]) - len(lines[begin].lstrip())]
    lines = [*lines[: begin + 1], *render_inputs(inputs, indent), *lines[end:]]

    index, match = _dotsteward_url_line(lines)
    url = match.group(2)
    if options.framework_url is not None:
        url = options.framework_url
    elif options.framework_ref is not None:
        github = GITHUB_REFERENCE.fullmatch(url)
        if github is None:
            raise Refusal(f"--framework-ref needs a github:<owner>/<repo>/<tag> dotsteward input, found {url!r}")
        url = f"{github.group(1)}/{options.framework_ref}"
    lines[index] = f"{match.group(1)}{nix_string(url)}{match.group(3)}"
    return "\n".join(lines), url


# --- workstation.toml ---------------------------------------------------------------


def _tomlkit() -> Any:
    try:
        import tomlkit
    except ModuleNotFoundError as problem:
        raise Refusal("init needs the Python package tomlkit (the framework's python has it)") from problem
    return tomlkit


def _without_header(text: str) -> str:
    """The template text without its leading comment block (which holds the
    template marker); the comments further down stay."""
    lines = text.splitlines(keepends=True)
    start = 0
    while start < len(lines) and (lines[start].lstrip().startswith("#") or not lines[start].strip()):
        start += 1
    return "".join(lines[start:])


def _split_trailer(text: str) -> tuple[str, str]:
    """The text and its trailing comment block (comment lines after a blank
    line at the end, which introduce the tables init appends), apart."""
    lines = text.rstrip("\n").split("\n")
    start = len(lines)
    while start > 0 and lines[start - 1].lstrip().startswith("#"):
        start -= 1
    if start == len(lines) or (start > 0 and lines[start - 1].strip()):
        return text, ""
    return "\n".join(lines[:start]).rstrip("\n") + "\n", "\n".join(lines[start:]) + "\n"


def _inline_table(values: Mapping[str, str]) -> Any:
    """An inline table rendered { key = "value", ... }."""
    tomlkit = _tomlkit()
    pairs = ", ".join(f"{key} = {json.dumps(value)}" for key, value in values.items())
    return tomlkit.parse(f"value = {{ {pairs} }}\n")["value"]


def _table(document: Any, key: str) -> Any:
    tomlkit = _tomlkit()
    if key not in document:
        document[key] = tomlkit.table()
    return document[key]


def default_checkout(directory: Path, home: str) -> str:
    try:
        relative = directory.relative_to(Path(os.path.abspath(home)))
    except ValueError:
        return str(directory)
    return "~" if str(relative) == "." else f"~/{relative.as_posix()}"


def compose_config(text: str, options: Options, identity: Identity, env: Mapping[str, str]) -> str:
    tomlkit = _tomlkit()
    try:
        body, trailer = _split_trailer(_without_header(text))
        document = tomlkit.parse(body)
    except Exception as problem:  # tomlkit raises its own parse errors
        raise Refusal(f"cannot parse the template {CONFIG_FILE}: {problem}") from problem

    identity_table = _table(document, "identity")
    identity_table["username"] = identity.username
    for key in ("home", "darwin_home"):
        if key in identity_table:
            del identity_table[key]
    if identity.home != identity.default_home:
        identity_table[identity.home_key] = identity.home

    instance = _table(document, "instance")
    instance["name"] = options.name if options.name is not None else options.dir.name
    instance["remote"] = options.remote
    instance["checkout"] = (
        options.checkout if options.checkout is not None else default_checkout(options.dir, env.get("HOME", ""))
    )

    nix = _table(document, "nix")
    nix["systems"] = list(options.systems)
    nix["allow_unfree"] = options.allow_unfree

    profiles = _table(document, "profiles")
    names = [options.adopt_profile, options.fresh_profile]
    profiles["names"] = names
    profiles["default"] = options.adopt_profile
    profiles["check"] = options.adopt_profile
    profiles["bootstrap"] = options.fresh_profile
    for key in [key for key in profiles if key not in config.PROFILE_KEYS and key not in names]:
        del profiles[key]
    for name, mode in ((options.adopt_profile, "adopt"), (options.fresh_profile, "fresh")):
        if name in profiles:
            profiles[name]["mode"] = mode
        else:
            table = tomlkit.table()
            table["mode"] = mode
            profiles[name] = table

    # The tables init appends follow the template's trailing comment.
    for key in ("components", "upstream"):
        if key in document:
            del document[key]
    upstream = tomlkit.document()
    upstream["upstream"] = {"contribute": options.contribute}
    upstream_text = tomlkit.dumps(upstream).strip("\n") + "\n"

    parts = [CONFIG_HEADER, tomlkit.dumps(document).rstrip("\n") + "\n", "\n"]
    if options.components:
        components = tomlkit.document()
        table = tomlkit.table(is_super_table=False)
        table["order"] = list(options.components)
        for name in options.components:
            entry = tomlkit.table()
            entry["enable"] = True
            if name in options.methods:
                entry["method"] = options.methods[name]
            if name in options.method_platforms:
                entry["method_by_platform"] = _inline_table(options.method_platforms[name])
            table[name] = entry
        components["components"] = table
        # The template's trailing comment introduces the components.
        parts += [trailer, tomlkit.dumps(components).strip("\n") + "\n", "\n", upstream_text]
    else:
        parts.append(upstream_text)
        if trailer:
            parts += ["\n", trailer]
    composed = "".join(parts)
    raw = tomllib.loads(composed)
    problems = config.errors(raw)
    if problems:
        raise UsageError(f"the options make an invalid {CONFIG_FILE}: {'; '.join(problems)}")
    return composed


# --- Steps --------------------------------------------------------------------------


def run_step(
    label: str,
    argv: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    json_mode: bool,
    own_session: bool = True,
) -> None:
    """Runs one step; its standard output goes to ours, or to standard
    error with --json. A failure is a refusal naming the step. A step in
    its own session (the Nix steps) is stopped with every process it
    started when init is interrupted or terminated meanwhile; the commit
    stays in init's session, so a signing program can reach the terminal."""
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=cwd,
            env=dict(env),
            stdin=subprocess.DEVNULL,
            stdout=sys.stderr if json_mode else None,
            start_new_session=own_session,
        )
    except OSError as problem:
        raise Refusal(f"{label} could not run: {problem.strerror}") from problem
    try:
        returncode = process.wait()
    except BaseException:
        stop_step(process, own_session)
        raise
    if returncode != 0:
        raise Refusal(f"{label} failed (exit {returncode})")


def stop_step(process: subprocess.Popen[bytes], own_session: bool) -> None:
    """SIGTERM to a step (to its whole process group when it has its own
    session), SIGKILL after the grace period, then waits for it."""

    def send(signum: int) -> None:
        with contextlib.suppress(ProcessLookupError):
            if own_session:
                os.killpg(process.pid, signum)
            else:
                process.send_signal(signum)

    for signum in (signal.SIGTERM, signal.SIGKILL):
        send(signum)
        try:
            process.wait(timeout=STOP_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            continue
        if own_session:
            # The leader is gone; the rest of its group may still run.
            send(signal.SIGKILL)
        return


def git_output(argv: Sequence[str], cwd: Path, env: Mapping[str, str]) -> str:
    result = subprocess.run(
        ["git", *argv], cwd=cwd, env=dict(env), stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise Refusal(f"git {' '.join(argv)} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def make_writable(root: Path) -> None:
    """Adds the user write bit (u+w) everywhere below root (a template copied
    from the Nix store is read-only)."""
    for directory, dirnames, filenames in os.walk(root):
        for name in [*dirnames, *filenames, ""]:
            path = os.path.join(directory, name) if name else directory
            if os.path.islink(path):
                continue
            mode = os.lstat(path).st_mode
            if not mode & stat.S_IWUSR:
                os.chmod(path, stat.S_IMODE(mode) | stat.S_IWUSR)


def restore_executable_bits(root: Path, template: Path) -> None:
    """Gives every file below root that is executable in the framework
    template its executable bits back (`nix flake init` drops them)."""
    for directory, _dirnames, filenames in os.walk(template):
        for name in filenames:
            source = os.path.join(directory, name)
            if os.path.islink(source):
                continue
            bits = stat.S_IMODE(os.lstat(source).st_mode) & 0o111
            target = root / os.path.relpath(source, template)
            if not bits or target.is_symlink() or not target.is_file():
                continue
            mode = stat.S_IMODE(os.lstat(target).st_mode)
            if mode & bits != bits:
                os.chmod(target, mode | bits)


def temp_root() -> Path:
    return Path(tempfile.gettempdir()).resolve()


def remove_temp_dir(path: Path) -> None:
    """Removes a temporary directory of init, only below the physical
    TMPDIR with the dotsteward- prefix (cleanup_temp_dir of lib.sh)."""
    if path.is_symlink() or not path.is_dir():
        return
    physical = path.resolve()
    if physical.parent == temp_root() and physical.name.startswith("dotsteward-"):
        shutil.rmtree(physical, ignore_errors=True)
    else:
        error(f"unsafe temporary directory not removed: {physical}")


def _remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def place(stage: Path, target: Path, kind: str, finish: Callable[[Path | None], T]) -> T:
    """Moves the composed instance into the target (a rename when the
    target is missing and on the same file system, else entry by entry with
    the previous entries kept aside inside the target), then runs finish in
    the target with the directory holding the previous entries (None when
    there were none). The previous entries are removed only when finish
    returned; any failure or interruption before, in finish too, restores
    the target as it was."""
    created = renamed = False
    if kind == "missing":
        try:
            os.rename(stage, target)
            renamed = True
        except OSError as problem:
            if problem.errno != errno.EXDEV:
                raise
            os.mkdir(target)
        created = True
    previous: Path | None = None
    moved: list[Path] = []
    finishing = False
    try:
        if not renamed:
            existing = sorted(target.iterdir())
            if existing:
                previous = Path(tempfile.mkdtemp(prefix=PREVIOUS_PREFIX, dir=target))
                for entry in existing:
                    os.rename(entry, previous / entry.name)
            for entry in sorted(stage.iterdir()):
                destination = target / entry.name
                moved.append(destination)
                shutil.move(entry, destination)
        finishing = True
        result = finish(previous)
    except BaseException:
        if created:
            shutil.rmtree(target, ignore_errors=True)
            raise
        # Once every entry is in place, everything in the target but the
        # previous entries is init's (finish may add more, such as .git).
        leftovers = [entry for entry in target.iterdir() if entry != previous] if finishing else moved
        for destination in leftovers:
            _remove(destination)
        if previous is not None:
            for entry in previous.iterdir():
                os.rename(entry, target / entry.name)
            previous.rmdir()
        raise
    if previous is not None:
        shutil.rmtree(previous)
    return result


# --- Main ---------------------------------------------------------------------------


@dataclass
class Result:
    options: Options
    framework_url: str
    commit: str | None
    next_steps: list[dict[str, str]] = field(default_factory=list)


def next_steps(options: Options, commit: str | None) -> list[dict[str, str]]:
    """The commands that follow init, ready to run in a shell."""
    directory = shlex.quote(str(options.dir))
    steps = []
    if commit is None:
        steps.append(
            {
                "description": "Commit the instance",
                "command": f"git -C {directory} init -b {BRANCH} && git -C {directory} add -A && "
                f"git -C {directory} commit -m {shlex.quote(COMMIT_SUBJECT)}",
            }
        )
    steps.append(
        {
            "description": "Add the remote of the private repository (create it on GitHub without pushing)",
            "command": f"git -C {directory} remote add origin {shlex.quote(options.remote)}",
        }
    )
    steps.append(
        {
            "description": "Validate the instance with the gate before the first push (AGENTS.md)",
            "command": f"cd {directory} && ./.dotsteward/cli.sh gate --scope maintain",
        }
    )
    steps.append(
        {
            "description": "Publish the validated instance",
            "command": f"git -C {directory} push -u origin {BRANCH}",
        }
    )
    steps.append(
        {
            "description": "On a new machine: install everything with the fresh profile (bootstrap ends with e2e)",
            "command": f"cd {directory} && ./bootstrap.sh --profile {options.fresh_profile}",
        }
    )
    steps.append(
        {
            "description": "On a machine that is already set up: adopt it, then check it end to end",
            "command": f"cd {directory} && ./rebuild.sh --profile {options.adopt_profile} --switch && "
            f"./.dotsteward/cli.sh e2e --profile {options.adopt_profile}",
        }
    )
    return steps


def initialize(options: Options, env: dict[str, str]) -> Result:
    env = {key: value for key, value in env.items() if key not in GIT_REPOSITORY_ENV}
    kind = classify_target(options.dir, env)
    identity = resolve_identity(options, env)

    source = options.dir if kind == "template" else FRAMEWORK_ROOT / "template"
    if not (source / CONFIG_FILE).is_file():
        raise Refusal(f"the framework template is missing: {source / CONFIG_FILE}")
    try:
        config_text = (source / CONFIG_FILE).read_text(encoding="utf-8")
        flake_text = (source / FLAKE_FILE).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as problem:
        raise Refusal(f"cannot read the template: {problem}") from problem
    versions_base = read_json(source / VERSIONS_LOCK, f"the template {VERSIONS_LOCK}")
    skills_base = read_json(source / SKILLS_LOCK, f"the template {SKILLS_LOCK}")

    composed_config = compose_config(config_text, options, identity, env)
    seeds = load_seeds(options.components)
    now = datetime.datetime.now(datetime.UTC).replace(microsecond=0)
    versions_text = compose_lock(
        versions_base,
        [(seed.component, seed.versions_lock) for seed in seeds],
        VERSIONS_LOCK,
        now.isoformat(),
    )
    skills_text = compose_lock(
        skills_base,
        [(seed.component, seed.skills_lock) for seed in seeds],
        SKILLS_LOCK,
        now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    composed_flake, framework_url = compose_flake(flake_text, collect_inputs(seeds), options)

    if options.git:
        require_git_identity(options.dir, env)
    find_nix(env)

    files = {
        CONFIG_FILE: composed_config,
        VERSIONS_LOCK: versions_text,
        SKILLS_LOCK: skills_text,
        FLAKE_FILE: composed_flake,
    }
    try:
        commit = build_and_place(options, kind, source, files, env)
    except Refusal as problem:
        raise Refusal(f"{problem}; {options.dir} was left as it was") from problem
    except OSError as problem:
        raise Refusal(f"{problem}; {options.dir} was left as it was") from problem
    return Result(options=options, framework_url=framework_url, commit=commit, next_steps=next_steps(options, commit))


def build_and_place(
    options: Options, kind: str, source: Path, files: Mapping[str, str], env: Mapping[str, str]
) -> str | None:
    """Steps 5 and 6: the composed instance is locked, synced and checked
    in a temporary directory, then moved into --dir and committed there; a
    failed commit puts --dir back as it was. Returns the commit (None with
    --no-git)."""
    temp = Path(tempfile.mkdtemp(prefix="dotsteward-init.", dir=temp_root()))
    try:
        stage = temp / "instance"
        shutil.copytree(source, stage, symlinks=True)
        make_writable(stage)
        restore_executable_bits(stage, FRAMEWORK_ROOT / "template")
        for relative, text in files.items():
            (stage / relative).write_text(text, encoding="utf-8")

        dir_env = {key: value for key, value in env.items() if key not in STEP_ENV_REMOVED}
        # git never looks above the temporary directory for a repository.
        step_env = {**dir_env, "GIT_CEILING_DIRECTORIES": str(temp)}
        is_repository = (stage / ".git").exists()
        if is_repository:
            # In a repository Nix sees only the files git knows.
            git_output(["add", "-A"], stage, step_env)
        cli = str(FRAMEWORK_ROOT / "cli" / "dotsteward")
        log("Locking the flake inputs, syncing the mirrors and checking the pins", options.json)
        run_step("nix flake lock", ["nix", *NIX_FEATURES, "flake", "lock", str(stage)], stage, step_env, options.json)
        if is_repository:
            # The new flake.lock too: sync refuses files Nix would not see.
            git_output(["add", "-A"], stage, step_env)
        run_step(
            "dotsteward sync --nix", [cli, "--instance", str(stage), "sync", "--nix"], stage, step_env, options.json
        )
        run_step(
            "dotsteward pins check --nix",
            [cli, "--instance", str(stage), "pins", "check", "--nix"],
            stage,
            step_env,
            options.json,
        )

        def commit_in_place(previous: Path | None) -> str | None:
            # In --dir itself: git chooses the identity, signing and hooks
            # by the repository's location, as for the user's own commits.
            if not options.git:
                return None
            if not is_repository:
                git_output(["init", "-q", "-b", BRANCH], options.dir, dir_env)
            pathspec = ["--", "."]
            if previous is not None:
                pathspec.append(f":(exclude,literal){previous.name}")
            git_output(["add", "-A", *pathspec], options.dir, dir_env)
            run_step(
                "git commit",
                ["git", "-c", "user.useConfigOnly=true", "commit", "-q", "-m", COMMIT_SUBJECT],
                options.dir,
                dir_env,
                options.json,
                own_session=False,
            )
            return git_output(["rev-parse", "HEAD"], options.dir, dir_env)

        return place(stage, options.dir, kind, commit_in_place)
    finally:
        remove_temp_dir(temp)


def report(result: Result) -> None:
    options = result.options
    if options.json:
        document = {
            "schema_version": 1,
            "dir": str(options.dir),
            "remote": options.remote,
            "components": options.components,
            "systems": options.systems,
            "profiles": {
                "names": [options.adopt_profile, options.fresh_profile],
                "check": options.adopt_profile,
                "bootstrap": options.fresh_profile,
            },
            "framework_url": result.framework_url,
            "commit": result.commit,
            "next_steps": result.next_steps,
        }
        _write(json.dumps(document, indent=2, ensure_ascii=False), sys.stdout)
        return
    log(f"Initialized the dotsteward instance in {options.dir}", False)
    log(f"Components: {', '.join(options.components) if options.components else 'none'}", False)
    if result.commit is not None:
        log(f"Committed {result.commit[:12]} {COMMIT_SUBJECT}", False)
    log("Next steps:", False)
    for number, step in enumerate(result.next_steps, start=1):
        log(f"  {number}. {step['description']}:", False)
        log(f"     {step['command']}", False)


def _on_signal(signum: int, frame: FrameType | None) -> None:
    raise Interrupted(signum)


def main(argv: Sequence[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, _on_signal)
    env = dict(os.environ)
    try:
        catalog = config._order_catalog(config.framework_catalog())
        options = parse_options(argv, catalog)
        result = initialize(options, env)
    except UsageError as problem:
        error(str(problem))
        _write(USAGE, sys.stderr)
        _write("Run 'dotsteward init --help' for the options.", sys.stderr)
        return EXIT_USAGE
    except Refusal as problem:
        error(str(problem))
        return EXIT_REFUSAL
    except config.DotstewardError as problem:
        error(str(problem))
        return EXIT_REFUSAL
    except KeyboardInterrupt:
        error("interrupted; nothing was written to --dir")
        return 130
    except Interrupted as problem:
        error("terminated; nothing was written to --dir")
        return 128 + problem.signum
    report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
