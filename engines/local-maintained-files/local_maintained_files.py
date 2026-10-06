#!/usr/bin/env python3
"""Settings engine of dotsteward: the local-maintained-files logical buffer.

Applications write their own settings files while they run. The instance
does not own those files; it tracks only the entries registered in
``<settings.buffer_dir>/buffer.toml``. The "logical buffer" is the projection
of the live files onto those entries: it has no copy on disk and is computed
again on every run.

Each entry compares three values: L (the live file), R (the buffer in the
repository's working tree) and B (this machine's base: the last value it saw
published). The base advances only to values published at
``settings.published_ref``. The rules:

  L = R                     in-sync
  L != B, R = B             local-changed   (apply leaves it, flush writes it)
  L = B,  R != B            remote-changed  (apply writes it to the live file)
  L != B, R != B, L != R    conflict        (nobody writes; resolve decides)
  no B,   L != R            first-contact   (apply writes the repository value)

Absence is a value too: a tracked key deleted locally is "local-deleted" and
reaches the repository only when confirmed with ``resolve --local``.

Targets come from two sources: the components' settings targets, rendered
for the platform into the JSON file given with ``--targets-file`` (the
generation's ``local-maintained-files`` command passes its own; without the
flag the instance's ``.dotsteward/manifest.<system>.json`` mirror is used when
it exists), and ``[targets.<name>]`` in the buffer. A buffer target replaces
the component target of the same name entirely. A target's ``reload`` names a
hook of the targets file's reload registry or is an inline table.

Extension seams (modules next to this file, imported on first use):

- ``jsonc.strip(text) -> (json_text, changed)`` removes comments and trailing
  commas outside strings; ``changed`` tells whether there were any. A JSONC
  target whose file has comments or trailing commas is an error for every
  entry on it, so nothing is written to it.
- ``lmf_validate.main(context) -> exit status`` implements ``validate`` with
  the resolved ``Context`` (whose ``engine`` field is this module).

Exit status: 0 ok, 1 verify found entries that did not converge, 2 error
(nothing was written), 3 flush left entries that need a decision.
"""

from __future__ import annotations

import argparse
import collections.abc
import contextlib
import dataclasses
import datetime
import fcntl
import hashlib
import importlib
import json
import os
import platform as platform_module
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import tomlkit

try:
    from dotsteward_cli import config as ds_config
except ImportError:  # run as a plain script from a framework checkout
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "cli" / "python"))
    from dotsteward_cli import config as ds_config

SCHEMA_VERSION = 1
CONFIG_FILE = "workstation.toml"
DEFAULT_BUFFER_DIR = "local-maintained-files"
DEFAULT_PUBLISHED_REF = "origin/main"
DEFAULT_STATE_ROOT = "${XDG_STATE_HOME:-~/.local/state}/dotsteward"
STATE_SUBDIR = "local-maintained-files"
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
SOURCE_PATTERN = re.compile(r"^(?!\.{1,2}$)[A-Za-z0-9._-]+$")
MODE_PATTERN = re.compile(r"^0[0-7]{3}$")
SECRET_PATTERN = re.compile(
    r"(token|secret|password|passwd|credential|oauth|bearer|api[_-]?key|private[_-]?key)", re.IGNORECASE
)
TARGET_KEYS = {"path", "format", "create_if_missing", "create_mode", "backup", "reload"}
TARGET_FORMATS = ("json", "toml", "jsonc")
PLATFORMS = ("linux", "darwin")
RELOAD_KEYS = {"command", "timeout", "env", "unset_env", "require_command", "on_success", "on_failure"}
RELOAD_DEFAULT_TIMEOUT = 15
ENTRY_KEY_ORDER = ("id", "kind", "target", "path", "source", "mode", "key", "value", "absent", "note")
DECISION_STATES = {"conflict", "local-deleted"}
NOT_CONVERGED_STATES = {"conflict", "remote-changed", "first-contact"}
MAINTAIN_SKILL = "dotsteward-maintain"

EXIT_OK = 0
EXIT_VERIFY_FAILED = 1
EXIT_ERROR = 2
EXIT_PENDING_DECISION = 3

PREFIX = "[local-maintained-files]"


class LmfError(Exception):
    """A refusal; every message becomes one ERROR line and the exit status is 2."""

    def __init__(self, *messages: str) -> None:
        super().__init__("\n".join(messages))
        self.messages = list(messages)


class _Absent:
    def __repr__(self) -> str:
        return "<absent>"


ABSENT = _Absent()


def log(message: str) -> None:
    print(f"{PREFIX} {message}")


def warn(message: str) -> None:
    print(f"{PREFIX} WARNING: {message}", file=sys.stderr)


def report_error(message: str) -> None:
    print(f"{PREFIX} ERROR: {message}", file=sys.stderr)


# --- Values -------------------------------------------------------------------------------


def plain(value: Any) -> Any:
    """Turns tomlkit items into plain Python values."""
    if hasattr(value, "unwrap"):
        return value.unwrap()
    return value


def same(left: Any, right: Any) -> bool:
    """Typed equality: true differs from 1 and 50 from 50.0; mapping key order does not matter."""
    if left is ABSENT or right is ABSENT:
        return left is right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same(left[key], right[key]) for key in left)
    if isinstance(left, (list, tuple)):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right, strict=True))
    return left == right


def check_value(value: Any, where: str, home: str) -> None:
    """A tracked value holds only portable JSON/TOML types and never the absolute home path."""
    if isinstance(value, (bool, int, float)):
        return
    if isinstance(value, str):
        if home and (value == home or home + "/" in value):
            raise LmfError(f"{where}: the value contains the absolute home directory; use '~' to keep it portable")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            check_value(item, f"{where}[{index}]", home)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise LmfError(f"{where}: a key is not a string")
            if SECRET_PATTERN.search(key):
                raise LmfError(f"{where}.{key}: a key that may hold a secret cannot be tracked")
            check_value(item, f"{where}.{key}", home)
        return
    raise LmfError(f"{where}: unsupported value type {type(value).__name__}")


def describe(value: Any, limit: int = 60) -> str:
    if value is ABSENT:
        return "<absent>"
    if isinstance(value, tuple):
        return f"sha256:{value[0][:12]} mode:{value[1]}"
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def to_json(value: Any) -> dict[str, Any]:
    if value is ABSENT:
        return {"absent": True}
    if isinstance(value, tuple):
        return {"sha256": value[0], "mode": value[1]}
    return {"value": value}


def from_json(record: dict[str, Any]) -> Any:
    if record.get("absent"):
        return ABSENT
    if "sha256" in record:
        return (record["sha256"], record["mode"])
    return record["value"]


def valid_record(record: Any) -> bool:
    """A base record as to_json writes it."""
    if not isinstance(record, dict):
        return False
    if record.get("absent") is True:
        return set(record) == {"absent"}
    if "sha256" in record:
        return (
            set(record) == {"sha256", "mode"} and isinstance(record["sha256"], str) and isinstance(record["mode"], str)
        )
    return set(record) == {"value"}


# --- Run-time context ---------------------------------------------------------------------


@dataclasses.dataclass
class Context:
    """Everything a command needs besides the buffer: resolved paths, the
    instance's settings, the platform and the component targets."""

    repo: str
    home: str
    state_dir: str
    platform: str
    buffer_dir: str
    published_ref: str
    targets_file: str | None
    component_targets: dict[str, Target]
    reload_hooks: dict[str, ReloadHook]
    engine: Any = None

    @property
    def buffer_rel(self) -> str:
        return f"{self.buffer_dir}/buffer.toml"

    @property
    def files_rel(self) -> str:
        return f"{self.buffer_dir}/files"

    @property
    def buffer_path(self) -> str:
        return os.path.join(self.repo, self.buffer_rel)

    @property
    def files_dir(self) -> str:
        return os.path.join(self.repo, self.files_rel)


def _config_messages(error: ds_config.DotstewardError) -> list[str]:
    return [f"{error.prefix}{message}" for message in error.messages]


def _normalized_buffer_dir(value: str) -> str:
    normalized = posixpath.normpath(value)
    if posixpath.isabs(normalized) or normalized == ".." or normalized.startswith("../") or normalized == ".":
        raise LmfError(f"settings.buffer_dir must be a directory inside the instance: {value!r}")
    return normalized


def nix_system(platform_name: str) -> str:
    machine = platform_module.machine().lower()
    machine = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    return f"{machine}-{platform_name}"


def resolve_context(args: argparse.Namespace) -> Context:
    """The repository (--repo > DOTSTEWARD_INSTANCE > DOTFILES_ROOT with
    compat.legacy_env > the instance above the working directory), the
    instance's settings from its workstation.toml (defaults without one), the
    state directory (--state-dir > DOTSTEWARD_STATE_ROOT > DOTFILES_STATE_ROOT
    with compat.legacy_env > state.root, plus /local-maintained-files) and the
    component targets."""
    try:
        platform_name = ds_config.runtime_platform()
        repo = os.path.abspath(args.repo) if args.repo is not None else str(ds_config.discover_instance())
        state_root = None
        if os.path.isfile(os.path.join(repo, CONFIG_FILE)):
            instance = ds_config.load_instance(repo)
            settings = instance.config["settings"]
            buffer_dir = settings["buffer_dir"]
            published_ref = settings["published_ref"]
            if args.state_dir is None:
                state_root = ds_config.runtime_values(instance)["state_root"]
        else:
            buffer_dir = DEFAULT_BUFFER_DIR
            published_ref = DEFAULT_PUBLISHED_REF
            if args.state_dir is None:
                state_root = os.environ.get("DOTSTEWARD_STATE_ROOT") or ds_config.expand_path(
                    DEFAULT_STATE_ROOT, os.environ
                )
                if not os.path.isabs(state_root):
                    raise LmfError(f"the state root is not an absolute path: {state_root!r}")
    except ds_config.DotstewardError as error:
        raise LmfError(*_config_messages(error)) from error
    if args.state_dir is not None:
        state_dir = os.path.abspath(args.state_dir)
    else:
        state_dir = os.path.join(state_root, STATE_SUBDIR)

    targets_file = args.targets_file
    if targets_file is None:
        mirror = os.path.join(repo, ".dotsteward", f"manifest.{nix_system(platform_name)}.json")
        if os.path.isfile(mirror):
            targets_file = mirror
    component_targets: dict[str, Target] = {}
    reload_hooks: dict[str, ReloadHook] = {}
    if targets_file is not None:
        targets_file = os.path.abspath(targets_file)
        component_targets, reload_hooks = load_targets_file(targets_file, platform_name)

    return Context(
        repo=repo,
        home=os.path.abspath(args.home),
        state_dir=state_dir,
        platform=platform_name,
        buffer_dir=_normalized_buffer_dir(buffer_dir),
        published_ref=published_ref,
        targets_file=targets_file,
        component_targets=component_targets,
        reload_hooks=reload_hooks,
        engine=sys.modules[__name__],
    )


def _without_component(spec: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in spec.items() if key != "component"}


def load_targets_file(path: str, platform_name: str) -> tuple[dict[str, Target], dict[str, ReloadHook]]:
    """Component targets and the reload registry of a targets file: the
    generation's ({schema_version, targets, reload_hooks}) or a manifest
    ({schema_version, settings_targets, reload_hooks})."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        raise LmfError(f"cannot read the targets file {path}: {error.strerror}") from error
    except ValueError as error:
        raise LmfError(f"invalid targets file {path}: {error}") from error
    where = f"targets file {path}"
    if not isinstance(data, dict):
        raise LmfError(f"{where}: not a JSON object")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise LmfError(f"{where}: schema_version must be {SCHEMA_VERSION}")
    raw_targets = data["targets"] if "targets" in data else data.get("settings_targets", {})
    raw_hooks = data.get("reload_hooks", {})
    if not isinstance(raw_targets, dict) or not all(isinstance(spec, dict) for spec in raw_targets.values()):
        raise LmfError(f"{where}: the targets must be an object of objects")
    if not isinstance(raw_hooks, dict) or not all(isinstance(spec, dict) for spec in raw_hooks.values()):
        raise LmfError(f"{where}: reload_hooks must be an object of objects")
    try:
        # "component" names the declaring component; it is not part of the spec.
        hooks = {
            name: ReloadHook(name, _without_component(spec), f"reload_hooks.{name}") for name, spec in raw_hooks.items()
        }
        targets = {name: Target(name, _without_component(spec), platform_name) for name, spec in raw_targets.items()}
    except LmfError as error:
        raise LmfError(*(f"{where}: {message}" for message in error.messages)) from error
    return targets, hooks


# --- Registry (buffer.toml and component targets) -----------------------------------------


class ReloadHook:
    """A reload command run after a target was written."""

    def __init__(self, label: str, spec: dict[str, Any], where: str, key: Any = None) -> None:
        unknown = set(spec) - RELOAD_KEYS
        if unknown:
            raise LmfError(f"{where}: unknown fields {sorted(unknown)}")
        self.label = label
        command = spec.get("command")
        if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
            raise LmfError(f"{where}.command must be a non-empty list of non-empty strings")
        self.command = command
        timeout = spec.get("timeout", RELOAD_DEFAULT_TIMEOUT)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
            raise LmfError(f"{where}.timeout must be a positive integer (seconds)")
        self.timeout = timeout
        env = spec.get("env", {})
        if not isinstance(env, dict) or not all(isinstance(value, str) for value in env.values()):
            raise LmfError(f"{where}.env must be a table of strings")
        self.env = env
        unset_env = spec.get("unset_env", [])
        if not isinstance(unset_env, list) or not all(isinstance(name, str) and name for name in unset_env):
            raise LmfError(f"{where}.unset_env must be a list of variable names")
        self.unset_env = unset_env
        require_command = spec.get("require_command")
        if require_command is not None and (not isinstance(require_command, str) or not require_command):
            raise LmfError(f"{where}.require_command must be a command name")
        self.require_command = require_command
        self.on_success = spec.get("on_success", "silent")
        if self.on_success not in ("log", "silent"):
            raise LmfError(f"{where}.on_success must be log or silent")
        self.on_failure = spec.get("on_failure", "warn")
        if self.on_failure not in ("warn", "silent"):
            raise LmfError(f"{where}.on_failure must be warn or silent")
        self.key = key if key is not None else ("name", label)

    def run(self, home: str) -> None:
        if self.require_command is not None and shutil.which(self.require_command) is None:
            return
        argv = [part.replace("{home}", home) for part in self.command]
        environment = dict(os.environ)
        environment.update({name: value.replace("{home}", home) for name, value in self.env.items()})
        for name in self.unset_env:
            environment.pop(name, None)
        shown = " ".join(argv)
        try:
            # Its own session, so a timeout ends the hook and everything it
            # started; the output is not shown (as before).
            process = subprocess.Popen(
                argv,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            self._failed(f"cannot run {shown}: {error.strerror}")
            return
        try:
            status = process.wait(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            warn(
                f"reload hook {self.label} timed out after {self.timeout} s ({shown}); "
                "the application picks up the settings when it restarts"
            )
            return
        if status == 0:
            if self.on_success == "log":
                log(f"reload hook {self.label} ran: {shown}")
        else:
            self._failed(f"{shown} failed (exit {status})")

    def _failed(self, message: str) -> None:
        if self.on_failure == "warn":
            warn(f"reload hook {self.label}: {message}")


def select_path(name: str, path: Any, platform_name: str) -> tuple[str | None, str | None]:
    """The target path for the platform, or None with the reason when the
    target has no path there."""
    where = f"targets.{name}.path"
    if isinstance(path, str):
        if not path.startswith("~/"):
            raise LmfError(f"{where} must start with '~/'")
        return path, None
    if isinstance(path, dict) and path and set(path) <= set(PLATFORMS):
        for key, value in path.items():
            if not isinstance(value, str) or not value.startswith("~/"):
                raise LmfError(f"{where}.{key} must start with '~/'")
        if platform_name not in path:
            return None, f"{where} has no {platform_name} path"
        return path[platform_name], None
    raise LmfError(f"{where} must be a '~/' path or a table of them by platform ({', '.join(PLATFORMS)})")


class Target:
    def __init__(self, name: str, spec: dict[str, Any], platform_name: str) -> None:
        unknown = set(spec) - TARGET_KEYS
        if unknown:
            raise LmfError(f"targets.{name}: unknown fields {sorted(unknown)}")
        self.name = name
        self.path, self.unavailable = select_path(name, spec.get("path"), platform_name)
        self.format = spec.get("format")
        self.create_if_missing = spec.get("create_if_missing")
        self.create_mode = spec.get("create_mode", "0644")
        self.backup = spec.get("backup", True)
        self.reload: str | ReloadHook | None = None
        if self.format not in TARGET_FORMATS:
            raise LmfError(f"targets.{name}.format must be one of {', '.join(TARGET_FORMATS)}")
        if not isinstance(self.create_if_missing, bool):
            raise LmfError(f"targets.{name}.create_if_missing must be true or false")
        if not isinstance(self.create_mode, str) or not MODE_PATTERN.fullmatch(self.create_mode):
            raise LmfError(f"targets.{name}.create_mode must look like '0644'")
        if not isinstance(self.backup, bool):
            raise LmfError(f"targets.{name}.backup must be true or false")
        reload = spec.get("reload")
        if isinstance(reload, dict):
            canonical = json.dumps(reload, sort_keys=True)
            self.reload = ReloadHook(f"of target {name}", reload, f"targets.{name}.reload", ("inline", canonical))
        elif reload is not None:
            if not isinstance(reload, str) or not reload:
                raise LmfError(f"targets.{name}.reload must be a reload hook name or an inline table")
            self.reload = reload


class Entry:
    def __init__(self, item: Any, targets: dict[str, Target], home: str) -> None:
        self.item = item
        if not isinstance(item, collections.abc.Mapping):
            raise LmfError("entries must be an array of tables")
        self.id = plain(item.get("id"))
        unknown = set(item.keys()) - set(ENTRY_KEY_ORDER)
        if unknown:
            raise LmfError(f"{self.id}: unknown fields {sorted(unknown)}")
        self.kind = plain(item.get("kind", "key"))
        self.note = plain(item.get("note", ""))
        if not isinstance(self.id, str) or not ID_PATTERN.fullmatch(self.id):
            raise LmfError(f"invalid entry id: {self.id!r}")
        has_value = "value" in item
        absent = plain(item.get("absent", False))
        if absent is not True and absent is not False:
            raise LmfError(f"{self.id}: absent must be true or false")
        if self.kind == "key":
            self.target = targets.get(plain(item.get("target")))
            if self.target is None:
                raise LmfError(f"{self.id}: unknown target {plain(item.get('target'))!r}")
            key = plain(item.get("key"))
            if not isinstance(key, list) or not key or not all(isinstance(part, str) and part for part in key):
                raise LmfError(f"{self.id}: key must be a non-empty list of non-empty strings")
            self.key = key
            for part in key:
                if SECRET_PATTERN.search(part):
                    raise LmfError(f"{self.id}: a key that may hold a secret cannot be tracked: {'.'.join(key)}")
            if has_value == absent:
                raise LmfError(f"{self.id}: exactly one of value or absent = true is required")
            self.repo_value = ABSENT if absent else plain(item["value"])
            if self.repo_value is not ABSENT:
                check_value(self.repo_value, self.id, home)
            self.identity = f"{self.target.name}|{json.dumps(self.key)}"
            self.label = ".".join(key)
        elif self.kind == "file":
            self.target = None
            self.path = plain(item.get("path"))
            self.source = plain(item.get("source"))
            self.mode = plain(item.get("mode", "0644"))
            if not isinstance(self.path, str) or not self.path.startswith("~/"):
                raise LmfError(f"{self.id}: path must start with '~/'")
            if not isinstance(self.source, str) or not SOURCE_PATTERN.fullmatch(self.source):
                raise LmfError(f"{self.id}: source must be a plain file name below files/")
            if not isinstance(self.mode, str) or not MODE_PATTERN.fullmatch(self.mode):
                raise LmfError(f"{self.id}: mode must look like '0755'")
            if has_value:
                raise LmfError(f"{self.id}: a whole-file entry has no value")
            self.absent = absent
            self.identity = f"file|{self.path}"
            self.label = self.path
        else:
            raise LmfError(f"{self.id}: unknown kind {self.kind!r}")


def read_buffer_text(path: str) -> str:
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError as error:
        raise LmfError(f"buffer file not found: {path}") from error
    except OSError as error:
        raise LmfError(f"cannot read {path}: {error.strerror}") from error
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise LmfError(f"{path} is not UTF-8 text ({error.reason} at byte {error.start})") from error


def parse_toml(text: str, path: str) -> tomlkit.TOMLDocument:
    try:
        return tomlkit.parse(text)
    except ValueError as error:
        raise LmfError(f"cannot parse {path}: {error}") from error


class Buffer:
    def __init__(self, context: Context, validate: bool = True) -> None:
        self.context = context
        self.home = context.home
        self.path = context.buffer_path
        self.files_dir = context.files_dir
        text = read_buffer_text(self.path)
        marker = re.search(r"^\[\[entries\]\]", text, re.MULTILINE)
        # The header and the targets stay as written; the entries are rendered canonically on every save.
        self.prefix = text[: marker.start()] if marker else text.rstrip("\n") + "\n\n"
        self.doc = parse_toml(text, self.path)
        if "entries" not in self.doc:
            self.doc["entries"] = tomlkit.aot()
        if validate:
            self.targets, self.entries = parse_buffer(self.doc, context)

    def repo_file_value(self, entry: Entry) -> Any:
        if entry.absent:
            return ABSENT
        source = os.path.join(self.files_dir, entry.source)
        if not os.path.isfile(source):
            raise LmfError(f"{entry.id}: repository source missing: {self.context.files_rel}/{entry.source}")
        try:
            with open(source, "rb") as handle:
                data = handle.read()
        except OSError as error:
            raise LmfError(f"{entry.id}: cannot read {source}: {error.strerror}") from error
        check_file_content(data, entry.id, self.home)
        return (hashlib.sha256(data).hexdigest(), entry.mode)

    def save(self) -> None:
        text = self.prefix + render_entries(self.doc["entries"])
        tomlkit.parse(text)
        atomic_write(self.path, text.encode("utf-8"), 0o644)


def render_entries(items: Any) -> str:
    """Writes the entries in the fixed field order with one blank line between them; table values
    come last. Fields outside the order (only in an invalid buffer) follow in their own order."""
    blocks = []
    for item in items:
        data = plain(item)
        if not isinstance(data, dict):
            raise LmfError("entries must be an array of tables")
        keys = [key for key in ENTRY_KEY_ORDER if key in data] + [key for key in data if key not in ENTRY_KEY_ORDER]
        table = tomlkit.table()
        for key in keys:
            if not isinstance(data[key], dict):
                table.add(key, data[key])
        for key in keys:
            if isinstance(data[key], dict):
                table.add(key, toml_value(data[key]))
        document = tomlkit.document()
        array = tomlkit.aot()
        array.append(table)
        document.add("entries", array)
        blocks.append(tomlkit.dumps(document).strip("\n"))
    return "\n\n".join(blocks) + "\n"


def parse_buffer(doc: Any, context: Context) -> tuple[dict[str, Target], list[Entry]]:
    if plain(doc.get("schema_version")) != SCHEMA_VERSION:
        raise LmfError(f"schema_version must be {SCHEMA_VERSION}")
    raw_targets = plain(doc.get("targets")) or {}
    if not isinstance(raw_targets, dict) or not all(isinstance(spec, dict) for spec in raw_targets.values()):
        raise LmfError("targets must be tables")
    # A buffer target replaces the component target of the same name entirely.
    targets = dict(context.component_targets)
    for name, spec in raw_targets.items():
        targets[name] = Target(name, spec, context.platform)
    raw_entries = doc.get("entries") or []
    if not isinstance(raw_entries, list):
        raise LmfError("entries must be an array of tables")
    entries = []
    seen_ids = set()
    seen_identities = set()
    for item in raw_entries:
        entry = Entry(item, targets, context.home)
        if entry.id in seen_ids:
            raise LmfError(f"duplicate entry id: {entry.id}")
        if entry.identity in seen_identities:
            raise LmfError(f"the same target and key twice: {entry.label}")
        seen_ids.add(entry.id)
        seen_identities.add(entry.identity)
        entries.append(entry)
    key_entries = [entry for entry in entries if entry.kind == "key"]
    for first in key_entries:
        for second in key_entries:
            if first is not second and first.target is second.target and second.key[: len(first.key)] == first.key:
                raise LmfError(f"{second.id} lies inside {first.id}; a path cannot be tracked twice")
    return targets, entries


def check_file_content(data: bytes, where: str, home: str) -> None:
    if home and (home + "/").encode() in data:
        raise LmfError(f"{where}: the file content contains the absolute home directory; use $HOME to keep it portable")


# --- Live files ---------------------------------------------------------------------------


def expand(path: str, home: str) -> str:
    return os.path.join(home, path[2:])


_jsonc_module: Any = None


def jsonc_module() -> Any:
    """The JSONC reader next to this file, or None when it is not installed."""
    global _jsonc_module
    if _jsonc_module is None:
        try:
            _jsonc_module = importlib.import_module("jsonc")
        except ImportError:
            _jsonc_module = False
    return _jsonc_module or None


class LiveDocument:
    """A target file's live state: read once, changed entry by entry, written atomically."""

    def __init__(self, target: Target, home: str, problem: str | None = None) -> None:
        self.target = target
        self.path = expand(target.path, home) if target.path is not None else None
        self.exists = False
        self.error = None
        self.doc: Any = None
        self.trailing_newline = True
        self.mode = int(target.create_mode, 8)
        self.mtime = None
        self.dirty = False
        if problem is not None:
            self.error = problem
            return
        if os.path.islink(self.path):
            self.error = f"symbolic link; the engine never writes through it: {self.path}"
            return
        if not os.path.exists(self.path):
            if target.create_if_missing:
                self.doc = {} if target.format != "toml" else tomlkit.document()
            return
        if not os.path.isfile(self.path):
            self.error = f"not a regular file: {self.path}"
            return
        self.exists = True
        try:
            info = os.stat(self.path)
            with open(self.path, "rb") as handle:
                data = handle.read()
        except OSError as error:
            self.error = f"cannot read ({error.strerror}): {self.path}"
            return
        self.mode = stat.S_IMODE(info.st_mode)
        self.mtime = info.st_mtime
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            self.error = f"not UTF-8 text ({error.reason} at byte {error.start}): {self.path}"
            return
        self.trailing_newline = text.endswith("\n")
        try:
            if target.format == "toml":
                self.doc = tomlkit.parse(text)
            else:
                if target.format == "jsonc":
                    jsonc = jsonc_module()
                    if jsonc is None:
                        self.error = f"JSONC support is not installed (jsonc.py next to the engine): {self.path}"
                        return
                    text, commented = jsonc.strip(text)
                    if commented:
                        self.error = (
                            f"commented JSONC file; edit it in the application or remove the comments: {self.path}"
                        )
                        return
                self.doc = json.loads(text) if text.strip() else {}
                if not isinstance(self.doc, dict):
                    raise ValueError("the top level is not a JSON object")
        except ValueError as error:
            self.error = f"cannot parse ({error}): {self.path}"
            self.doc = None

    @property
    def deferred(self) -> bool:
        return not self.exists and not self.target.create_if_missing

    def get(self, key: list[str]) -> Any:
        node = self.doc
        for part in key:
            if not isinstance(node, collections.abc.Mapping) or part not in node:
                return ABSENT
            node = node[part]
        return plain(node)

    def set(self, key: list[str], value: Any) -> None:
        node = self.doc
        if value is ABSENT:
            for part in key[:-1]:
                if not isinstance(node, collections.abc.MutableMapping) or part not in node:
                    return
                node = node[part]
            if isinstance(node, collections.abc.MutableMapping) and key[-1] in node:
                del node[key[-1]]
                self.dirty = True
            return
        for part in key[:-1]:
            if part not in node:
                node[part] = tomlkit.table(True) if self.target.format == "toml" else {}
            node = node[part]
            if not isinstance(node, collections.abc.MutableMapping):
                raise LmfError(f"{self.path}: the path {'.'.join(key)} is blocked by a value that is not a table")
        last = key[-1]
        if (
            self.target.format == "toml"
            and isinstance(value, dict)
            and isinstance(node.get(last), collections.abc.MutableMapping)
        ):
            sync_table(node[last], value)
        else:
            node[last] = value
        self.dirty = True

    def render(self) -> bytes:
        if self.target.format == "toml":
            return tomlkit.dumps(self.doc).encode("utf-8")
        text = json.dumps(self.doc, indent=2, ensure_ascii=False)
        if self.trailing_newline:
            text += "\n"
        return text.encode("utf-8")


def sync_table(table: Any, value: dict[str, Any]) -> None:
    """Brings an existing TOML table to VALUE key by key; unchanged lines and comments stay."""
    for key in list(table.keys()):
        if key not in value:
            del table[key]
    for key, item in value.items():
        current = table.get(key)
        if current is not None and same(plain(current), item):
            continue
        if isinstance(item, dict) and isinstance(current, collections.abc.MutableMapping):
            sync_table(current, item)
        else:
            table[key] = item


def read_live_file(entry: Entry, home: str) -> tuple[Any, bytes | None, float | None]:
    path = expand(entry.path, home)
    if os.path.islink(path):
        raise LmfError(f"{entry.id}: symbolic link; the engine never writes through it: {path}")
    if not os.path.exists(path):
        return ABSENT, None, None
    if not os.path.isfile(path):
        raise LmfError(f"{entry.id}: not a regular file: {path}")
    try:
        with open(path, "rb") as handle:
            data = handle.read()
        info = os.stat(path)
    except OSError as error:
        raise LmfError(f"{entry.id}: cannot read ({error.strerror}): {path}") from error
    return (hashlib.sha256(data).hexdigest(), f"{stat.S_IMODE(info.st_mode):04o}"), data, info.st_mtime


def atomic_write(path: str, data: bytes, mode: int) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.lmf-", dir=directory)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


# --- Machine state (base, journal, backups, lock) ------------------------------------------


def acquire_lock(directory: str) -> Any:
    """Creates the state directory (0700) and blocks until this process holds its lock."""
    os.makedirs(directory, exist_ok=True)
    os.chmod(directory, 0o700)
    handle = open(os.path.join(directory, "lock"), "w")  # noqa: SIM115 # held until the command ends
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


class State:
    def __init__(self, directory: str) -> None:
        self.directory = directory
        self.lock_handle = acquire_lock(directory)
        self.base_path = os.path.join(directory, "base.json")
        self.journal_path = os.path.join(directory, "journal.jsonl")
        self.backup_root: str | None = None
        self.base = self._load_base()
        self.base_dirty = False

    def _load_base(self) -> dict[str, Any]:
        if not os.path.exists(self.base_path):
            return {}
        hint = "move it aside to start over (every entry is then a first contact)"
        try:
            with open(self.base_path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as error:
            raise LmfError(f"corrupt machine state {self.base_path} ({error}); {hint}") from error
        if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
            raise LmfError(f"corrupt machine state {self.base_path} (schema_version {SCHEMA_VERSION} expected); {hint}")
        entries = data.get("entries")
        if not isinstance(entries, dict):
            raise LmfError(f"corrupt machine state {self.base_path} (entries is not an object); {hint}")
        for identity, record in entries.items():
            if not valid_record(record):
                raise LmfError(f"corrupt machine state {self.base_path} (invalid record for {identity}); {hint}")
        return entries

    def base_value(self, entry: Entry) -> Any:
        record = self.base.get(entry.identity)
        return None if record is None else from_json(record)

    def set_base(self, entry: Entry, value: Any) -> None:
        record = to_json(value)
        if self.base.get(entry.identity) != record:
            self.base[entry.identity] = record
            self.base_dirty = True

    def prune(self, identities: set[str]) -> None:
        for identity in list(self.base):
            if identity not in identities:
                del self.base[identity]
                self.base_dirty = True

    def save(self) -> None:
        if self.base_dirty:
            payload = {"schema_version": SCHEMA_VERSION, "entries": self.base}
            text = json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
            atomic_write(self.base_path, text.encode(), 0o600)
            self.base_dirty = False

    def journal(self, command: str, entry: Entry, old: Any, new: Any) -> None:
        record = {
            "time": now_iso(),
            "command": command,
            "id": entry.id,
            "identity": entry.identity,
            "old": to_json(old),
            "new": to_json(new),
        }
        with open(self.journal_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        os.chmod(self.journal_path, 0o600)

    def backup(self, path: str) -> str | None:
        """Copies PATH below this run's backup root once; returns the copy, or None when PATH is
        not a regular file."""
        if not os.path.isfile(path):
            return None
        if self.backup_root is None:
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            self.backup_root = os.path.join(self.directory, "backups", stamp)
        destination = os.path.join(self.backup_root, path.lstrip("/"))
        if os.path.exists(destination):
            return destination
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        os.chmod(os.path.join(self.directory, "backups"), 0o700)
        shutil.copy2(path, destination)
        os.chmod(destination, 0o600)
        return destination


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- State computation --------------------------------------------------------------------


class Row:
    def __init__(self, entry: Entry) -> None:
        self.entry = entry
        self.live: Any = ABSENT
        self.repo: Any = ABSENT
        self.base: Any = None
        self.state: str | None = None
        self.error: str | None = None
        self.live_mtime: float | None = None
        self.live_data: bytes | None = None


class Session:
    def __init__(self, context: Context) -> None:
        self.context = context
        self.repo = context.repo
        self.home = context.home
        self.buffer = Buffer(context)
        self.state = State(context.state_dir)
        self.documents: dict[str, LiveDocument] = {}
        self.published = load_published(context)
        self.rows: list[Row] = []
        self.evaluate()

    def document(self, name: str) -> LiveDocument:
        """The live document of target NAME, read on first use."""
        document = self.documents.get(name)
        if document is None:
            target = self.buffer.targets[name]
            document = LiveDocument(target, self.home, self.target_problem(target))
            self.documents[name] = document
        return document

    def target_problem(self, target: Target) -> str | None:
        if target.unavailable is not None:
            return target.unavailable
        if isinstance(target.reload, str) and target.reload not in self.context.reload_hooks:
            source = self.context.targets_file or "no targets file"
            return f"targets.{target.name}: unknown reload hook {target.reload!r} (registry: {source})"
        return None

    def reload_hook(self, target: Target) -> ReloadHook | None:
        if isinstance(target.reload, str):
            return self.context.reload_hooks[target.reload]
        return target.reload

    def evaluate(self) -> None:
        self.rows = []
        for entry in self.buffer.entries:
            row = Row(entry)
            try:
                if entry.kind == "key":
                    document = self.document(entry.target.name)
                    if document.error:
                        raise LmfError(document.error)
                    row.repo = entry.repo_value
                    if document.deferred:
                        row.state = "deferred"
                        self.rows.append(row)
                        continue
                    row.live = document.get(entry.key)
                    row.live_mtime = document.mtime
                else:
                    row.repo = self.buffer.repo_file_value(entry)
                    row.live, row.live_data, row.live_mtime = read_live_file(entry, self.home)
            except LmfError as error:
                row.state = "error"
                row.error = str(error)
                self.rows.append(row)
                continue
            row.base = self.state.base_value(entry)
            row.state = classify(row.live, row.repo, row.base)
            self.rows.append(row)

    def reconcile(self) -> int:
        if self.published is None:
            return 0
        advanced = 0
        for row in self.rows:
            if row.state in ("error", "deferred"):
                continue
            published = self.published.get(row.entry.identity, _MISSING)
            if published is _MISSING:
                continue
            if same(row.live, published):
                if row.base is None or not same(row.base, published):
                    advanced += 1
                self.state.set_base(row.entry, published)
        self.state.prune({entry.identity for entry in self.buffer.entries})
        self.state.save()
        for row in self.rows:
            if row.state not in ("error", "deferred"):
                row.base = self.state.base_value(row.entry)
                row.state = classify(row.live, row.repo, row.base)
        return advanced

    def errors(self) -> list[Row]:
        return [row for row in self.rows if row.state == "error"]

    def write_live(self, row: Row, value: Any, command: str) -> str | None:
        """Writes VALUE to the live side of ROW (key entries when the documents are flushed); returns
        the backup taken for it, if any."""
        entry = row.entry
        backup = None
        if entry.kind == "key":
            document = self.document(entry.target.name)
            if document.exists and entry.target.backup:
                backup = self.state.backup(document.path)
            document.set(entry.key, value)
        else:
            path = expand(entry.path, self.home)
            if os.path.exists(path):
                backup = self.state.backup(path)
            if value is ABSENT:
                if os.path.exists(path):
                    os.unlink(path)
            else:
                with open(os.path.join(self.buffer.files_dir, entry.source), "rb") as handle:
                    data = handle.read()
                atomic_write(path, data, int(entry.mode, 8))
                written, _, _ = read_live_file(entry, self.home)
                if not same(written, value):
                    raise LmfError(f"{entry.id}: the written file does not read back: {path}")
        self.state.journal(command, entry, row.live, value)
        row.live = value
        return backup

    def flush_documents(self) -> None:
        """Writes the changed target files, reads them back, and runs each reload hook once."""
        reloaded = set()
        for name in self.buffer.targets:
            document = self.documents.get(name)
            if document is None or not document.dirty:
                continue
            atomic_write(document.path, document.render(), document.mode)
            document.dirty = False
            check = LiveDocument(document.target, self.home)
            if check.error:
                raise LmfError(check.error)
            for row in self.rows:
                entry = row.entry
                if entry.kind == "key" and entry.target.name == name and not same(check.get(entry.key), row.live):
                    raise LmfError(f"{entry.id}: the written value does not read back: {document.path}")
            hook = self.reload_hook(document.target)
            if hook is not None and hook.key not in reloaded:
                hook.run(self.home)
                reloaded.add(hook.key)

    def write_repo(self, row: Row, value: Any) -> None:
        entry = row.entry
        if entry.kind == "key":
            item = entry.item
            if value is ABSENT:
                if "value" in item:
                    del item["value"]
                item["absent"] = True
            else:
                check_value(value, entry.id, self.home)
                if "absent" in item:
                    del item["absent"]
                item["value"] = toml_value(value)
        else:
            source = os.path.join(self.buffer.files_dir, entry.source)
            if value is ABSENT:
                entry.item["absent"] = True
                if os.path.exists(source):
                    os.unlink(source)
            else:
                check_file_content(row.live_data, entry.id, self.home)
                atomic_write(source, row.live_data, int(value[1], 8))
                if "absent" in entry.item:
                    del entry.item["absent"]
                entry.item["mode"] = value[1]
        row.repo = value


_MISSING = object()


def classify(live: Any, repo: Any, base: Any) -> str:
    if base is None:
        return "in-sync" if same(live, repo) else "first-contact"
    if same(live, repo):
        return "in-sync"
    live_changed = not same(live, base)
    repo_changed = not same(repo, base)
    if live_changed and not repo_changed:
        return "local-deleted" if live is ABSENT else "local-changed"
    if repo_changed and not live_changed:
        return "remote-changed"
    return "conflict"


def toml_value(value: Any) -> Any:
    if isinstance(value, dict):
        table = tomlkit.table()
        for key, item in value.items():
            table[key] = toml_value(item)
        return table
    return value


def load_published(context: Context) -> dict[str, Any] | None:
    """The buffer at settings.published_ref; None when there is none (the base does not advance)."""
    ref = context.published_ref
    try:
        data = git(context.repo, "show", f"{ref}:{context.buffer_rel}", binary=True)
    except LmfError:
        return None
    try:
        text = data.decode("utf-8")
        doc = tomlkit.parse(text)
        _, entries = parse_buffer(doc, context)
    except (LmfError, ValueError) as error:
        warn(f"cannot read the published buffer at {ref}; the base does not advance: {error}")
        return None
    published: dict[str, Any] = {}
    for entry in entries:
        if entry.kind == "key":
            published[entry.identity] = entry.repo_value
        elif entry.absent:
            published[entry.identity] = ABSENT
        else:
            try:
                blob = git(context.repo, "show", f"{ref}:{context.files_rel}/{entry.source}", binary=True)
            except LmfError:
                continue
            published[entry.identity] = (hashlib.sha256(blob).hexdigest(), entry.mode)
    return published


def git(repo: str, *arguments: str, binary: bool = False) -> Any:
    try:
        completed = subprocess.run(["git", "-C", repo, *arguments], capture_output=True, check=False)
    except OSError as error:
        raise LmfError("git not found") from error
    if completed.returncode != 0:
        raise LmfError(completed.stderr.decode("utf-8", "replace").strip() or "git failed")
    return completed.stdout if binary else completed.stdout.decode("utf-8", "replace")


# --- Commands -----------------------------------------------------------------------------


def command_status(session: Session, args: argparse.Namespace) -> int:
    session.reconcile()
    if args.json:
        print(json.dumps(status_payload(session), ensure_ascii=False, indent=2, sort_keys=True))
        return EXIT_OK
    width = max((len(row.entry.id) for row in session.rows), default=2)
    for row in session.rows:
        entry = row.entry
        place = entry.target.name if entry.kind == "key" else "file"
        detail = row.error if row.state == "error" else f"local={describe(row.live)} repo={describe(row.repo)}"
        print(f"{entry.id:<{width}}  {row.state:<14} {place:<16} {entry.label}  {detail}")
    counts = collections.Counter(row.state for row in session.rows)
    print("summary: " + ", ".join(f"{state}={count}" for state, count in sorted(counts.items())))
    return EXIT_OK


def status_payload(session: Session) -> dict[str, Any]:
    last_change = None
    try:
        line = git(session.repo, "log", "-1", "--format=%H%x09%cI%x09%s", "--", session.context.buffer_rel).strip()
        if line:
            oid, date, subject = line.split("\t", 2)
            last_change = {"oid": oid, "date": date, "subject": subject}
    except LmfError:
        pass
    entries = []
    for row in session.rows:
        entry = row.entry
        modified = None
        if row.live_mtime is not None:
            moment = datetime.datetime.fromtimestamp(row.live_mtime, datetime.timezone.utc)
            modified = moment.strftime("%Y-%m-%dT%H:%M:%SZ")
        entries.append(
            {
                "id": entry.id,
                "kind": entry.kind,
                "target": entry.target.name if entry.kind == "key" else None,
                "path": entry.key if entry.kind == "key" else entry.path,
                "note": entry.note,
                "state": row.state,
                "needs_decision": row.state in DECISION_STATES,
                "error": row.error,
                "live": None if row.state in ("error", "deferred") else to_json(row.live),
                "repo": to_json(row.repo),
                "base": None if row.base is None else to_json(row.base),
                "live_modified": modified,
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "published_available": session.published is not None,
        "repo_last_change": last_change,
        "entries": entries,
    }


def require_no_errors(session: Session) -> None:
    errors = session.errors()
    for row in errors:
        report_error(f"{row.entry.id}: {row.error}")
    if errors:
        raise LmfError("no file is written until the errors above are fixed")


def command_apply(session: Session, args: argparse.Namespace) -> int:
    session.reconcile()
    require_no_errors(session)
    written = 0
    for row in session.rows:
        if row.state in ("remote-changed", "first-contact"):
            state, old = row.state, row.live
            backup = session.write_live(row, row.repo, "apply")
            if state == "first-contact" and old is not ABSENT:
                message = (
                    f"{row.entry.id}: first contact; the repository value {describe(row.repo)} "
                    f"replaces the local value {describe(old)}"
                )
                warn(message + (f" (backup: {backup})" if backup else ""))
            written += 1
    session.flush_documents()
    session.reconcile()
    for row in session.rows:
        if row.state in DECISION_STATES:
            warn(f"{row.entry.id}: {row.state}; decide with {MAINTAIN_SKILL} (resolve); left untouched")
        elif row.state == "deferred":
            log(f"{row.entry.id}: the target file does not exist yet; deferred")
    log(f"apply finished: {written} entries written to live files")
    return EXIT_OK


def command_flush(session: Session, args: argparse.Namespace) -> int:
    session.reconcile()
    require_no_errors(session)
    pending = []
    to_write = []
    for row in session.rows:
        if row.state == "local-changed":
            to_write.append(row)
        elif row.state in DECISION_STATES:
            pending.append(row)
        elif row.state in ("remote-changed", "first-contact"):
            log(f"{row.entry.id}: {row.state}; run apply (rebuild) on this machine first; skipped")
    for row in to_write:
        if row.entry.kind == "key":
            check_value(row.live, row.entry.id, session.home)
        else:
            check_file_content(row.live_data, row.entry.id, session.home)
    for row in to_write:
        old = row.repo
        session.write_repo(row, row.live)
        log(f"{row.entry.id}: repository {describe(old)} -> {describe(row.live)}")
    if to_write:
        session.buffer.save()
    for row in pending:
        base = describe(row.base) if row.base is not None else "<none>"
        warn(
            f"{row.entry.id}: {row.state}; local={describe(row.live)} repo={describe(row.repo)} base={base}; "
            f"decide with {MAINTAIN_SKILL} (resolve)"
        )
    log(f"flush finished: {len(to_write)} entries written to the repository, {len(pending)} waiting for a decision")
    return EXIT_PENDING_DECISION if pending else EXIT_OK


def command_resolve(session: Session, args: argparse.Namespace) -> int:
    session.reconcile()
    require_no_errors(session)
    row = find_row(session, args.id)
    if row.state not in DECISION_STATES:
        raise LmfError(f"{args.id}: does not need a decision ({row.state})")
    if args.local:
        session.write_repo(row, row.live)
        session.buffer.save()
        log(f"{args.id}: the local value was written to the repository: {describe(row.live)}")
    else:
        session.write_live(row, row.repo, "resolve")
        session.flush_documents()
        log(f"{args.id}: the repository value was written to the live file: {describe(row.repo)}")
    session.reconcile()
    return EXIT_OK


def command_reconcile(session: Session, args: argparse.Namespace) -> int:
    advanced = session.reconcile()
    if session.published is None:
        log(f"no published buffer at {session.context.published_ref}; the base was not advanced")
    else:
        log(f"base updated: {advanced} entries")
    return EXIT_OK


def command_verify(session: Session, args: argparse.Namespace) -> int:
    session.reconcile()
    failed = False
    for row in session.rows:
        if row.state == "error":
            report_error(f"{row.entry.id}: {row.error}")
            failed = True
        elif row.state in NOT_CONVERGED_STATES:
            report_error(f"{row.entry.id}: {row.state} (local={describe(row.live)} repo={describe(row.repo)})")
            failed = True
        elif row.state in ("local-changed", "local-deleted"):
            log(f"{row.entry.id}: {row.state}; waiting to be written to the repository with {MAINTAIN_SKILL}")
        elif row.state == "deferred":
            log(f"{row.entry.id}: the target file does not exist yet; deferred")
    if failed:
        return EXIT_VERIFY_FAILED
    log("verification succeeded")
    return EXIT_OK


def parse_key(args: argparse.Namespace) -> list[str]:
    if args.key_json is None:
        return args.key.split(".")
    try:
        key = json.loads(args.key_json)
    except ValueError as error:
        raise LmfError(f"--key-json is not valid JSON: {error}") from error
    if not isinstance(key, list) or not key or not all(isinstance(part, str) and part for part in key):
        raise LmfError("--key-json must be a non-empty JSON list of non-empty strings")
    return key


def command_track(session: Session, args: argparse.Namespace) -> int:
    if any(entry.id == args.id for entry in session.buffer.entries):
        raise LmfError(f"the id already exists: {args.id}")
    if not ID_PATTERN.fullmatch(args.id):
        raise LmfError(f"invalid id: {args.id}")
    target = session.buffer.targets.get(args.target)
    if target is None:
        raise LmfError(f"unknown target: {args.target}")
    key = parse_key(args)
    for part in key:
        if SECRET_PATTERN.search(part):
            raise LmfError(f"a key that may hold a secret cannot be tracked: {'.'.join(key)}")
    document = session.document(target.name)
    if document.error:
        raise LmfError(document.error)
    value = ABSENT if document.deferred else document.get(key)
    if value is not ABSENT:
        check_value(value, args.id, session.home)
    item = tomlkit.table()
    item["id"] = args.id
    item["target"] = target.name
    item["key"] = key
    if args.note:
        item["note"] = args.note
    if value is ABSENT:
        item["absent"] = True
    else:
        item["value"] = toml_value(value)
    session.buffer.doc["entries"].append(item)
    parse_buffer(session.buffer.doc, session.context)
    session.buffer.save()
    log(f"{args.id}: now tracked ({target.name} {'.'.join(key)} = {describe(value)})")
    return EXIT_OK


def command_track_file(session: Session, args: argparse.Namespace) -> int:
    if any(entry.id == args.id for entry in session.buffer.entries):
        raise LmfError(f"the id already exists: {args.id}")
    probe = tomlkit.table()
    probe["id"] = args.id
    probe["kind"] = "file"
    probe["path"] = args.path
    probe["source"] = args.source
    live_path = expand(args.path, session.home) if args.path.startswith("~/") else args.path
    if os.path.islink(live_path) or not os.path.isfile(live_path):
        raise LmfError(f"a regular live file is required: {live_path}")
    with open(live_path, "rb") as handle:
        data = handle.read()
    check_file_content(data, args.id, session.home)
    mode = args.mode or f"{stat.S_IMODE(os.stat(live_path).st_mode):04o}"
    probe["mode"] = mode
    session.buffer.doc["entries"].append(probe)
    parse_buffer(session.buffer.doc, session.context)
    atomic_write(os.path.join(session.buffer.files_dir, args.source), data, int(mode, 8))
    session.buffer.save()
    log(f"{args.id}: whole file now tracked ({args.path})")
    return EXIT_OK


def command_untrack(context: Context, args: argparse.Namespace) -> int:
    """Removes one entry without validating the rest of the buffer, so an invalid buffer can be
    repaired; the other entries are written back unchanged (in canonical layout)."""
    lock = acquire_lock(context.state_dir)
    try:
        buffer = Buffer(context, validate=False)
        entries = buffer.doc["entries"]
        if not isinstance(entries, list):
            raise LmfError("entries must be an array of tables")
        for index, item in enumerate(entries):
            if not isinstance(item, collections.abc.Mapping) or plain(item.get("id")) != args.id:
                continue
            source = plain(item.get("source"))
            is_file = plain(item.get("kind", "key")) == "file"
            if is_file and isinstance(source, str) and SOURCE_PATTERN.fullmatch(source):
                path = os.path.join(buffer.files_dir, source)
                if os.path.isfile(path) and not os.path.islink(path):
                    os.unlink(path)
            del entries[index]
            buffer.save()
            log(f"{args.id}: no longer tracked; the live file was not touched")
            return EXIT_OK
        raise LmfError(f"unknown id: {args.id}")
    finally:
        lock.close()


def command_validate(context: Context, args: argparse.Namespace) -> int:
    try:
        validator = importlib.import_module("lmf_validate")
    except ImportError as error:
        raise LmfError("validate is not installed (lmf_validate.py next to the engine)") from error
    return validator.main(context)


def find_row(session: Session, identifier: str) -> Row:
    for row in session.rows:
        if row.entry.id == identifier:
            return row
    raise LmfError(f"unknown id: {identifier}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="local-maintained-files",
        description="Sync tracked application settings with the instance's settings buffer.",
    )
    parser.add_argument("--repo", help="instance checkout (default: the discovered instance)")
    parser.add_argument("--home", default=os.path.expanduser("~"), help="home directory of the live files")
    parser.add_argument("--state-dir", help="machine state (default: <state root>/local-maintained-files)")
    parser.add_argument("--targets-file", help="component settings targets and reload hooks (JSON)")
    commands = parser.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status", help="show the state of every entry")
    status.add_argument("--json", action="store_true")
    commands.add_parser("apply", help="write remote changes and first contacts to the live files")
    commands.add_parser("flush", help="write local changes to the repository buffer")
    resolve = commands.add_parser("resolve", help="decide a conflict or a local deletion")
    resolve.add_argument("id")
    side = resolve.add_mutually_exclusive_group(required=True)
    side.add_argument("--local", action="store_true")
    side.add_argument("--remote", action="store_true")
    commands.add_parser("reconcile", help="advance the base to the published values")
    commands.add_parser("verify", help="check that this machine agrees with the repository")
    track = commands.add_parser("track", help="start tracking a key")
    track.add_argument("--id", required=True)
    track.add_argument("--target", required=True)
    key = track.add_mutually_exclusive_group(required=True)
    key.add_argument("--key")
    key.add_argument("--key-json")
    track.add_argument("--note")
    track_file = commands.add_parser("track-file", help="start tracking a whole file")
    track_file.add_argument("--id", required=True)
    track_file.add_argument("--path", required=True)
    track_file.add_argument("--source", required=True)
    track_file.add_argument("--mode")
    untrack = commands.add_parser("untrack", help="stop tracking an entry")
    untrack.add_argument("id")
    commands.add_parser("validate", help="check the buffer without touching any file")
    return parser.parse_args(argv)


COMMANDS = {
    "status": command_status,
    "apply": command_apply,
    "flush": command_flush,
    "resolve": command_resolve,
    "reconcile": command_reconcile,
    "verify": command_verify,
    "track": command_track,
    "track-file": command_track_file,
}

CONTEXT_COMMANDS = {
    "untrack": command_untrack,
    "validate": command_validate,
}


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        context = resolve_context(args)
        if args.command in CONTEXT_COMMANDS:
            return CONTEXT_COMMANDS[args.command](context, args)
        session = Session(context)
        return COMMANDS[args.command](session, args)
    except LmfError as error:
        for message in error.messages:
            report_error(message)
        return EXIT_ERROR
    except OSError as error:
        report_error(str(error))
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
