"""Health checks of an instance on this machine: ``dotsteward doctor``
(SPEC 6.2, 6.5).

doctor builds the context (``context.py``) and adds read-only checks, in
this order:

- ``config``: workstation.toml and the environment are valid and the context
  sources can be read (otherwise the checks below that need the context are
  skipped and the context is null);
- ``identity``: USER and HOME are safe for the generated host flake (the
  rules of ``require_safe_identity``, SPEC 4.4), and whether they match the
  check identity (informational: a different user needs no file edit);
- ``nix``: a ``nix`` command on PATH, else in the Nix daemon profile or
  ~/.nix-profile, and its version;
- ``launcher-cache``: ``<state root>/cli/<sha256 of flake.lock>/bin/dotsteward``
  exists, so ``.dotsteward/cli.sh`` runs without building (SPEC 6.3);
- ``mirrors``: for every system of nix.systems, ``.dotsteward/manifest.<system>.json``
  and ``.dotsteward/stage0.<platform>.env`` exist, and the manifest holds the
  current configuration and framework version. This is a quick consistency
  check without Nix; ``checks.<system>.dotsteward-manifest`` compares the
  mirrors with the evaluated values;
- ``generation``: the generation recorded by the last rebuild
  (``<state root>/current/last-built-activation``) has its dotsteward manifest;
- ``gate-memo``: the age of the last passed gate (``validation.json``).

Each check has a status: ``ok``, ``warn`` (works, but needs attention),
``fail`` (the next rebuild or gate cannot work) or ``skip``. The overall
status is the worst one; the exit status is 1 when a check failed, else 0.

``--redact`` makes the report shareable: home directories (runtime and
check), the runtime and check usernames, the hostname, the remote and its
owner and repository become ``<redacted>`` wherever they appear (homes and
the remote as substrings, the other terms as whole words), and so do the
settings entry ids and target names, the names, targets and commands of
instance components, and the instance skill names. Settings values are never
read.

JSON document (one, on stdout)::

    {"schema_version": 1, "status": "ok|warn|fail", "redacted": bool,
     "host": {"hostname": str},
     "checks": [{"id", "status", "message", "details": {...}}, ...],
     "context": <context document> | null}

Command line (used by ``cli/commands/doctor.sh``)::

    python3 -m dotsteward_cli.doctor [--json] [--redact]
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import config, context

SCHEMA_VERSION = 1
REDACTED = "<redacted>"
CHECK_IDS = ("config", "identity", "nix", "launcher-cache", "mirrors", "generation", "gate-memo")
STATUS_ORDER = ("ok", "skip", "warn", "fail")

# Where a Nix installation puts nix when it is not on PATH (the launcher
# looks in the same places, SPEC 6.3).
NIX_FALLBACKS = ("/nix/var/nix/profiles/default/bin/nix", "~/.nix-profile/bin/nix")
NIX_VERSION_TIMEOUT = 20

LINUX_USER = re.compile(r"^[a-z_][a-z0-9_-]*$")
DARWIN_USER = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
UNSAFE_HOME = re.compile(r"[\s\"'$\\]")


def _check(check_id: str, status: str, message: str, **details: Any) -> dict[str, Any]:
    return {"id": check_id, "status": status, "message": message, "details": details}


def _plural(count: int, word: str, plural: str | None = None) -> str:
    return f"{count} {word if count == 1 else plural or word + 's'}"


# --- Checks ---------------------------------------------------------------------------


def check_identity(env: Mapping[str, str], platform_name: str, document: Mapping[str, Any] | None) -> dict[str, Any]:
    user = env.get("USER", "")
    home = env.get("HOME", "")
    pattern = DARWIN_USER if platform_name == "darwin" else LINUX_USER
    if not pattern.fullmatch(user):
        system = "macOS" if platform_name == "darwin" else "Linux"
        return _check(
            "identity", "fail", f"unsafe user name {user!r}: {system} user names must match {pattern.pattern}"
        )
    if not home.startswith("/") or UNSAFE_HOME.search(home) or not os.path.isdir(home):
        return _check(
            "identity",
            "fail",
            f"unsafe HOME {home!r}: it must be an absolute path of an existing directory "
            "without whitespace, quotes, $ or backslash",
        )
    if document is None:
        return _check("identity", "ok", f"runtime identity {user} with home {home}")
    identity = document["identity"]
    if identity["runtime_matches_check"]:
        return _check("identity", "ok", f"runtime identity {user} with home {home} is the check identity")
    return _check(
        "identity",
        "ok",
        f"runtime identity {user} with home {home} differs from the check identity "
        f"{identity['check_username']} with home {identity['check_home']}; [identity] is only used for "
        "checks, so no file edit is needed",
    )


def find_nix(env: Mapping[str, str], fallbacks: Iterable[str] = NIX_FALLBACKS) -> str | None:
    """nix on PATH, else the first executable fallback (~ is HOME)."""
    found = shutil.which("nix", path=env.get("PATH", ""))
    if found is not None:
        return found
    home = env.get("HOME", "")
    for candidate in fallbacks:
        path = home + candidate[1:] if candidate.startswith("~/") and home else candidate
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def check_nix(env: Mapping[str, str], fallbacks: Iterable[str] = NIX_FALLBACKS) -> dict[str, Any]:
    path = find_nix(env, fallbacks)
    if path is None:
        return _check("nix", "fail", "Nix not found on PATH or in the default profiles; run ./bootstrap.sh first")
    try:
        result = subprocess.run(
            [path, "--version"],
            capture_output=True,
            text=True,
            timeout=NIX_VERSION_TIMEOUT,
            check=False,
            env=dict(env),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return _check("nix", "fail", f"{path} --version failed: {error}", path=path)
    lines = result.stdout.strip().splitlines()
    if result.returncode != 0 or not lines:
        return _check("nix", "fail", f"{path} --version exited {result.returncode}", path=path)
    return _check("nix", "ok", f"{lines[0]} at {path}", path=path, version=lines[0])


def check_launcher_cache(instance: config.Instance, document: Mapping[str, Any]) -> dict[str, Any]:
    lock = instance.root / context.FLAKE_LOCK
    try:
        key = hashlib.sha256(lock.read_bytes()).hexdigest()
    except FileNotFoundError:
        return _check("launcher-cache", "warn", "no flake.lock: the launcher cannot pin the CLI")
    except OSError as error:
        return _check("launcher-cache", "warn", f"cannot read flake.lock: {error.strerror}")
    entry = os.path.join(document["state"]["root"], "cli", key)
    binary = os.path.join(entry, "bin", "dotsteward")
    if os.path.isfile(binary) and os.access(binary, os.X_OK):
        return _check("launcher-cache", "ok", f"the CLI for this flake.lock is cached: {entry}", path=entry, key=key)
    return _check(
        "launcher-cache",
        "warn",
        f"no cached CLI for this flake.lock (key {key}); the next .dotsteward/cli.sh run builds it",
        path=entry,
        key=key,
    )


def mirror_problems(instance: config.Instance) -> list[str]:
    """Why the .dotsteward mirrors are not current, as far as it can be told
    without evaluating the instance."""
    problems: list[str] = []
    expected = config.resolve(config.read_toml(instance.file), config.framework_catalog(), None)
    version = context.framework_version()["version"]
    directory = instance.root / context.MIRROR_DIR
    for system in instance.config["nix"]["systems"]:
        platform_name = system.split("-", 1)[1]
        stage0 = f"stage0.{platform_name}.env"
        if not (directory / stage0).is_file():
            problems.append(f"{context.MIRROR_DIR}/{stage0} is missing")
        name = f"{context.MIRROR_DIR}/manifest.{system}.json"
        try:
            mirror = context.read_json(directory / f"manifest.{system}.json")
        except (OSError, ValueError) as error:
            problems.append(f"{name} cannot be read: {error}")
            continue
        if mirror is None:
            problems.append(f"{name} is missing")
            continue
        if not isinstance(mirror, dict) or mirror.get("schema_version") != 1 or mirror.get("system") != system:
            problems.append(f"{name} is not a schema version 1 manifest of {system}")
            continue
        if not config.nix_equal(mirror.get("config"), expected):
            problems.append(f"{name} does not hold the current workstation.toml")
        framework = mirror.get("framework")
        mirror_version = framework.get("version") if isinstance(framework, dict) else None
        if mirror_version != version:
            problems.append(f"{name} was written by framework {mirror_version}, this is {version}")
    return problems


def check_mirrors(instance: config.Instance) -> dict[str, Any]:
    problems = mirror_problems(instance)
    systems = ", ".join(instance.config["nix"]["systems"])
    if problems:
        return _check(
            "mirrors",
            "warn",
            "; ".join(problems) + "; run `dotsteward sync`",
            problems=problems,
        )
    return _check(
        "mirrors",
        "ok",
        f"the mirrors of {systems} hold the current configuration and framework version "
        "(checks.<system>.dotsteward-manifest compares them fully)",
        problems=[],
    )


def check_generation(document: Mapping[str, Any]) -> dict[str, Any]:
    record = Path(document["state"]["root"]) / "current" / "last-built-activation"
    try:
        generation = record.read_text(encoding="utf-8", errors="surrogateescape").strip()
    except FileNotFoundError:
        return _check("generation", "warn", "no generation recorded yet; run `dotsteward rebuild`")
    except OSError as error:
        return _check("generation", "warn", f"cannot read {record}: {error.strerror}")
    if not generation:
        return _check("generation", "warn", f"{record} is empty; run `dotsteward rebuild`")
    manifest = Path(generation) / "home-path" / "share" / "dotsteward" / "manifest.json"
    if manifest.is_file():
        return _check("generation", "ok", f"the last built generation has its manifest: {generation}", path=generation)
    return _check(
        "generation",
        "warn",
        f"the last built generation {generation} has no dotsteward manifest (built before dotsteward, "
        "or garbage-collected); run `dotsteward rebuild`",
        path=generation,
    )


def _parse_utc(value: Any) -> datetime.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=datetime.UTC)


def check_gate_memo(document: Mapping[str, Any], now: datetime.datetime | None = None) -> dict[str, Any]:
    path = document["state"]["memo"]
    try:
        record = context.read_json(Path(path))
    except (OSError, ValueError) as error:
        return _check("gate-memo", "warn", f"cannot read {path}: {error}", path=path)
    if record is None:
        return _check("gate-memo", "warn", "no passed gate recorded yet", path=path)
    if not isinstance(record, dict):
        return _check("gate-memo", "warn", f"{path} is not a validation record", path=path)
    validated_at = record.get("validated_at")
    moment = _parse_utc(validated_at)
    if record.get("result") != "passed" or moment is None:
        return _check("gate-memo", "warn", f"{path} is not a passed validation record", path=path)
    now = now or datetime.datetime.now(datetime.UTC)
    age = max(0, int((now - moment).total_seconds()))
    days = age // 86400
    return _check(
        "gate-memo",
        "ok",
        f"the last gate passed {_plural(days, 'day')} ago ({validated_at}, scope {record.get('scope')})",
        path=path,
        validated_at=validated_at,
        age_seconds=age,
        tree_oid=record.get("tree_oid"),
    )


# --- Report ---------------------------------------------------------------------------


def run(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The doctor document (not redacted)."""
    env = os.environ if env is None else env
    try:
        platform_name = config.runtime_platform(env)
    except config.DotstewardError:
        platform_name = "linux"
    instance: config.Instance | None = None
    document: dict[str, Any] | None = None
    try:
        instance = config.load_instance(env=env)
        document = context.build_context(instance, env)
        config_check = _check("config", "ok", f"{instance.file} is valid", path=str(instance.file))
    except config.DotstewardError as error:
        messages = [f"{error.prefix}{message}" for message in error.messages]
        config_check = _check("config", "fail", "; ".join(messages), problems=messages)

    checks = [config_check, check_identity(env, platform_name, document), check_nix(env)]
    if instance is not None and document is not None:
        checks += [
            check_launcher_cache(instance, document),
            check_mirrors(instance),
            check_generation(document),
            check_gate_memo(document),
        ]
    else:
        checks += [
            _check(check_id, "skip", "needs a valid configuration")
            for check_id in ("launcher-cache", "mirrors", "generation", "gate-memo")
        ]
    status = max((check["status"] for check in checks), key=STATUS_ORDER.index)
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok" if status == "skip" else status,
        "redacted": False,
        "host": {"hostname": socket.gethostname()},
        "checks": checks,
        "context": document,
    }


# --- Redaction ------------------------------------------------------------------------

_REMOTE = re.compile(r"(?:^[^@/]+@[^:/]+:|^[a-z][a-z0-9+.-]*://[^/]+/)(?P<path>.+?)(?:\.git)?/?$")


def remote_parts(remote: str) -> list[str]:
    """The owner (or group path) and repository of a git remote URL."""
    match = _REMOTE.match(remote)
    if match is None:
        return []
    parts = [part for part in match.group("path").split("/") if part]
    return parts[-2:]


def _terms(report: Mapping[str, Any], env: Mapping[str, str]) -> tuple[list[str], list[str]]:
    """(substring terms, word terms) to redact."""
    substrings = [env.get("HOME", "").rstrip("/")]
    words = [env.get("USER", ""), report["host"]["hostname"], report["host"]["hostname"].split(".")[0]]
    document = report["context"]
    if document is not None:
        identity = document["identity"]
        instance = document["instance"]
        substrings += [identity["check_home"], identity["runtime_home"] or "", instance["remote"]]
        words += [identity["check_username"], identity["runtime_user"] or "", *remote_parts(instance["remote"])]
    # A one-character home (/) would redact every path separator.
    substrings = [term for term in substrings if term and len(term) > 1]
    words = [term for term in words if term]
    return sorted(set(substrings), key=len, reverse=True), sorted(set(words), key=len, reverse=True)


def _replacer(substrings: Sequence[str], words: Sequence[str]) -> Callable[[str], str]:
    alternatives = [re.escape(term) for term in substrings]
    alternatives += [rf"(?<![A-Za-z0-9]){re.escape(term)}(?![A-Za-z0-9])" for term in words]
    if not alternatives:
        return lambda text: text
    pattern = re.compile("|".join(alternatives))
    return lambda text: pattern.sub(REDACTED, text)


def _map_strings(value: Any, replace: Callable[[str], str]) -> Any:
    if isinstance(value, str):
        return replace(value)
    if isinstance(value, list):
        return [_map_strings(item, replace) for item in value]
    if isinstance(value, dict):
        return {replace(key): _map_strings(item, replace) for key, item in value.items()}
    return value


def redact(report: Mapping[str, Any], env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """A copy of report with the private terms replaced (see the module
    documentation). Check ids and statuses are kept."""
    env = os.environ if env is None else env
    replace = _replacer(*_terms(report, env))
    result = json.loads(json.dumps(report))
    document = result["context"]
    if document is not None:
        settings = document["settings"]
        settings["entry_ids"] = [REDACTED for _ in settings["entry_ids"]]
        settings["target_names"] = [REDACTED for _ in settings["target_names"]]
        for component in document["components"]:
            component["settings_targets"] = [REDACTED for _ in component["settings_targets"]]
            if component["source"] == "instance":
                component["name"] = REDACTED
                component["commands"] = [REDACTED for _ in component["commands"]]
        skills = document["skills"]
        skills["instance_skill_names"] = [REDACTED for _ in skills["instance_skill_names"]]
    result["host"]["hostname"] = REDACTED
    result["checks"] = [
        {
            "id": check["id"],
            "status": check["status"],
            "message": replace(check["message"]),
            "details": _map_strings(check["details"], replace),
        }
        for check in result["checks"]
    ]
    result["context"] = _map_strings(document, replace)
    result["redacted"] = True
    return result


# --- Command line ---------------------------------------------------------------------


def human_lines(report: Mapping[str, Any]) -> list[str]:
    document = report["context"]
    where = document["instance"]["path"] if document is not None else "(no valid instance configuration)"
    lines = [f"[dotsteward] doctor: {where}"]
    lines += [f"[dotsteward] {check['status']:<4} {check['id']}: {check['message']}" for check in report["checks"]]
    counts = {status: sum(check["status"] == status for check in report["checks"]) for status in STATUS_ORDER}
    parts = [f"{counts['ok']} ok", _plural(counts["warn"], "warning"), _plural(counts["fail"], "failure")]
    if counts["skip"]:
        parts.append(f"{counts['skip']} skipped")
    lines.append(f"[dotsteward] summary: {', '.join(parts)}")
    return lines


USAGE = """\
Usage: dotsteward doctor [--json] [--redact]

Checks the health of the instance on this machine, read-only: the
configuration, the runtime identity, Nix, the launcher cache, the .dotsteward
mirrors, the last built generation's manifest and the age of the gate memo.
Each check is ok, warn, fail or skip.

  --json      one JSON document on stdout: the checks and the context
              (`dotsteward context --json`); without it, a line per check
  --redact    replace home directories, usernames, the hostname, the remote
              and private names (settings entries and targets, instance
              components and skills) with <redacted>, to share the report
  -h, --help  this help

Exit 0, or 1 when a check fails or for a usage error."""


def main(argv: Sequence[str] | None = None) -> int:
    args_parser = context.parser("doctor")
    args_parser.add_argument("--json", action="store_true")
    args_parser.add_argument("--redact", action="store_true")
    args = args_parser.parse_args(argv)
    if args.help:
        config._write(USAGE)
        return 0
    report = run()
    if args.redact:
        report = redact(report)
    if args.json:
        config._write(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        config._write("\n".join(human_lines(report)))
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
