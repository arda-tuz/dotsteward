"""``dotsteward status``: one read-only overview of this machine and its instance (docs/track.md).

It reads what is on this machine and nothing else: the checkout and its refs as the last fetch left
them, the records of the state root (the machine, the active generation, the last E2E run, the
holds, the research of the last upgrade, review.json, what other machines brought), the manifest
mirror and the local branch of the state of this machine. It fetches nothing, starts no command of
this CLI, takes no lock and writes nothing, so it answers at once, without a network and while
another command runs. The one outside reader is ``dpkg-query``, for the packages of a deb
component.

What it reports, for each tracked component: whether it applies here and why not (another machine,
a tag, a profile, the platform, an answer, a question that waits), whether it is installed where
that can be read cheaply, its method, updater, version constraint and holds. Besides: the checkout
against the remote, whether the active generation is the checkout and how its E2E went, newer
versions the last upgrade found, the skills and plugins, the state branch and its orphans (the
components of its last record that the intent no longer has), and what review.json waits for. What
the machine has that nobody tracks is no part of it.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import config, machine, platforms, report
from dotsteward_cli import publish as publishing
from dotsteward_cli import state as state_branch
from dotsteward_cli.skills import commands as skill_commands
from dotsteward_cli.skills import layout
from dotsteward_cli.upgrade import holds

SCHEMA_VERSION = 1
_ATTENTION = ("update", "review", "held")

_DESCRIPTION = (
    "One read-only overview of this machine and its instance: the machine, the checkout against what the last "
    "fetch knows of the remote, whether the active generation is the checkout and its E2E, every tracked component "
    "(here or why not, installed, method, updater, constraint, holds), newer versions the last upgrade found, what "
    "other machines brought that waits for an answer, the skills and plugins, the state branch of this machine and "
    "its orphans, and what review.json holds. Offline and fast: it fetches nothing, runs no other command and "
    "writes nothing. Exit status: 0, 1 when the instance cannot be read."
)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


def _git(root: Path, *arguments: str) -> str:
    done = publishing.git(root, *arguments)
    return done.stdout.strip() if done.code == 0 else ""


def _mtime(path: Path) -> str | None:
    try:
        moment = path.stat().st_mtime
    except OSError:
        return None
    return datetime.datetime.fromtimestamp(moment, datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _framework_version() -> str | None:
    try:
        return (config.FRAMEWORK_ROOT / "VERSION").read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def _checkout(instance: config.Instance) -> dict[str, Any]:
    root = instance.root
    branch = str(instance.config["instance"]["branch"])
    head = _git(root, "rev-parse", "--verify", "--quiet", "HEAD") or None
    remote = _git(root, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}^{{commit}}") or None
    ahead = behind = None
    if head and remote:
        counts = _git(root, "rev-list", "--left-right", "--count", f"HEAD...{remote}").split()
        if len(counts) == 2:
            ahead, behind = int(counts[0]), int(counts[1])
    porcelain = publishing.git(root, "status", "--porcelain", "--untracked-files=normal").stdout
    git_dir = _git(root, "rev-parse", "--path-format=absolute", "--git-dir")
    return {
        "path": str(root),
        "branch": branch,
        "current_branch": _git(root, "symbolic-ref", "--quiet", "--short", "HEAD") or None,
        "head": head,
        "remote_tip": remote,
        "ahead": ahead,
        "behind": behind,
        "changes": [line for line in porcelain.splitlines() if line],
        "fetched_at": _mtime(Path(git_dir) / "FETCH_HEAD") if git_dir else None,
    }


def _activation(instance: config.Instance, state_root: str, head: str | None) -> dict[str, Any]:
    activation = _read_json(Path(state_root) / "current" / "activation.json")
    tree = _git(instance.root, "rev-parse", "--verify", "--quiet", "HEAD^{tree}") if head else ""
    generation = activation.get("generation") if isinstance(activation.get("generation"), str) else None
    e2e = _read_json(Path(state_root) / "update" / "e2e.json")
    result = None
    if generation is not None and e2e.get("generation") == generation:
        result = {"passed": "pass", "failed": "fail"}.get(str(e2e.get("result")))
    return {
        "tree_oid": activation.get("tree_oid"),
        "profile": activation.get("profile"),
        "generation": generation,
        "active": bool(tree) and activation.get("tree_oid") == tree,
        "e2e": result,
        "e2e_at": e2e.get("recorded_at") if result is not None else None,
    }


def _installed_packages(packages: Sequence[str]) -> dict[str, str] | None:
    if not packages or shutil.which("dpkg-query") is None:
        return None
    done = subprocess.run(
        ["dpkg-query", "-W", "-f", "${Package}\t${db:Status-Status}\t${Version}\n", *packages],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )
    found = {}
    for line in done.stdout.splitlines():
        package, _, rest = line.partition("\t")
        status, _, version = rest.partition("\t")
        if status == "installed" and version:
            found[package] = version
    return found


def _at_home(value: Any) -> Path | None:
    if not isinstance(value, str) or not value.startswith("~/"):
        return None
    return Path(os.environ.get("HOME") or os.path.expanduser("~")) / value[2:]


def _deb_packages(entry: Mapping[str, Any], table: Mapping[str, Any]) -> tuple[list[str], list[str]]:
    """The packages a deb component installs, and those it installs or follows."""
    install = entry.get("install") or {}
    installs = [str(name) for name in [*(install.get("packageNames") or ()), *(install.get("apt") or ())]]
    return installs, sorted({*installs, *(str(name) for name in table.get("track") or ())})


def _installation(
    entry: Mapping[str, Any], table: Mapping[str, Any], versions: Mapping[str, str] | None
) -> dict[str, Any]:
    """Whether the component is installed, where that can be read without running anything heavy.
    VERSIONS: the installed version of every package of a deb component here, None without dpkg."""
    method = entry.get("method")
    install = entry.get("install") or {}
    if method == "deb":
        if versions is None:
            return {}
        _, wanted = _deb_packages(entry, table)
        return {
            "installed": "installed" if state_branch.deb_installed(install, versions) else "missing",
            "packages": {package: versions[package] for package in wanted if package in versions},
        }
    if method == "official-binary":
        dest = _at_home(install.get("dest"))
        if dest is not None:
            return {"installed": "installed" if dest.exists() else "missing"}
    if method == "pypi":
        venv = _at_home(install.get("venv"))
        if venv is not None:
            return {"installed": "installed" if (venv / "bin").is_dir() else "missing"}
    return {}


def _components(
    instance: config.Instance, scope: Mapping[str, Any], state_root: str, env: Mapping[str, str]
) -> list[dict[str, Any]]:
    entries = {
        str(entry.get("name")): entry
        for entry in layout.manifest(instance).get("components") or ()
        if isinstance(entry, dict)
    }
    held: dict[str, list[dict[str, Any]]] = {}
    for hold in holds.read(state_root):
        held.setdefault(str(hold.get("component")), []).append(
            {key: hold[key] for key in ("id", "version", "reason", "since") if key in hold}
        )
    runtime = config.runtime_platform(env)
    profile = scope.get("profile")
    catalog = set(config.framework_catalog())
    enabled = sorted(machine.enabled_components(instance))
    # One dpkg-query for every deb component: one call costs as much as a hundred packages.
    packages = sorted(
        {
            package
            for name, table in enabled
            if (entries.get(name) or {}).get("method") == "deb"
            for package in _deb_packages(entries[name], table)[1]
        }
    )
    versions = _installed_packages(packages) if packages else {}
    found = []
    for name, table in enabled:
        entry = entries.get(name) or {}
        reason = scope["reasons"].get(f"component:{name}")
        profiles = table.get("profiles")
        if reason is None and profiles is not None and profile is not None and profile not in profiles:
            reason = "profile"
        if reason is None and entry.get("unavailable"):
            reason = machine.REASON_PLATFORM
        here = reason in (None, machine.REASON_NOT_ACTIVATED)
        row: dict[str, Any] = {
            "name": name,
            "source": "catalog" if name in catalog else "instance",
            "method": config.method_for(instance.config, name, runtime) or entry.get("method"),
            "updater": table.get("updater"),
            "here": here,
            "reason": reason,
            "constraint": (
                {"version": table.get("version"), "reason": table.get("reason")} if table.get("version") else None
            ),
            "held": held.get(name, []),
            "installed": None,
        }
        if here and entry:
            row.update(_installation(entry, table, versions))
        found.append(row)
    return found


def _updates(state_root: str) -> dict[str, Any]:
    """What the research of the last upgrade found newer than the pins."""
    path = Path(state_root) / "upgrade" / "latest.json"
    document = _read_json(path)
    rows = [
        {key: row.get(key) for key in ("id", "current", "latest", "status")}
        for row in document.get("items") or ()
        if isinstance(row, dict) and row.get("status") in _ATTENTION
    ]
    return {"researched_at": document.get("researched_at") or (_mtime(path) if document else None), "rows": rows}


def _skills(instance: config.Instance, scope: Mapping[str, Any], state_root: str) -> dict[str, Any]:
    lock = machine.read_lock(instance)
    own = skill_commands.own_revisions(instance)
    entries = []
    for entry in machine.entries_of(lock, "skills"):
        name = entry.get("name")
        if not isinstance(name, str):
            continue
        reason = scope["reasons"].get(f"skill:{name}")
        entries.append({"name": name, "own": entry.get("revision") in own, "here": reason is None, "reason": reason})
    from dotsteward_cli.skills import state as skill_state

    waiting = skill_state.load_pending(state_root).get("items") or {}
    return {
        "tracking": bool(instance.config.get("skills", {}).get("tracking", False)),
        "entries": sorted(entries, key=lambda row: row["name"]),
        "capture_waiting": sorted(str(key).removeprefix("skill:") for key in waiting),
    }


def _plugins(instance: config.Instance, scope: Mapping[str, Any]) -> list[dict[str, Any]]:
    lock = machine.read_lock(instance)
    found: dict[str, dict[str, Any]] = {}
    for entry in machine.entries_of(lock, "own_plugins"):
        if isinstance(entry.get("name"), str):
            found[entry["name"]] = {"name": entry["name"], "own": True}
    for entry in machine.plugin_entries(instance):
        if isinstance(entry.get("spec"), str):
            found[entry["spec"]] = {"name": entry["spec"], "own": False}
    rows = []
    for name, row in sorted(found.items()):
        reason = scope["reasons"].get(f"plugin:{name}")
        rows.append({**row, "here": reason is None, "reason": reason})
    return rows


def _state(
    instance: config.Instance, name: str | None, env: Mapping[str, str]
) -> tuple[dict[str, Any] | None, list[str]]:
    """The last record of this machine on its state branch, and its orphans."""
    if name is None:
        return None, []
    try:
        shown = state_branch.read(instance, name, env)
    except state_branch.Refusal:
        return None, []
    document = shown["state"]
    recorded = set((document.get("components") or {}).keys())
    intent = {component for component, _ in machine.enabled_components(instance)}
    return (
        {
            "recorded_at": document.get("recorded_at"),
            "recorded_by": document.get("recorded_by"),
            "intent_commit": document.get("intent_commit"),
            "source": shown["source"],
            "waiting": bool(shown["queued"]),
        },
        sorted(recorded - intent),
    )


def overview(instance: config.Instance, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The document of ``status --json``."""
    env = os.environ if env is None else env
    state_root = config.state_root(instance, env)
    scope = machine.effective(instance, env)
    checkout = _checkout(instance)
    recorded, orphans = _state(instance, scope["name"], env)
    review = report.load_review(state_root) or {}
    return {
        "schema_version": SCHEMA_VERSION,
        "command": "status",
        "machine": {
            "name": scope["name"],
            "platform": platforms.platform_id(env),
            "profile": scope["profile"],
            "tags": scope["tags"],
            "framework_version": _framework_version(),
            "producer": (instance.config.get("hosts") or {}).get("producer"),
        },
        "checkout": checkout,
        "activation": _activation(instance, state_root, checkout["head"]),
        "components": _components(instance, scope, state_root, env),
        "holds": holds.read(state_root),
        "updates": _updates(state_root),
        "incoming": scope["incoming"],
        "requires": scope["requires"],
        "skills": _skills(instance, scope, state_root),
        "plugins": _plugins(instance, scope),
        "state": recorded,
        "orphans": orphans,
        "review": [
            {key: item.get(key) for key in ("command", "code", "message", "run") if item.get(key) is not None}
            for item in review.get("items") or ()
            if isinstance(item, dict)
        ],
    }


# --- text -------------------------------------------------------------------------------------


def _short(oid: Any) -> str:
    return str(oid)[:12] if oid else "none"


def human(document: Mapping[str, Any]) -> list[str]:
    lines = []
    this = document["machine"]
    lines.append(
        f"machine     {this['name'] or '(no name: dotsteward host init)'}, {this['platform']}, "
        f"profile {this['profile'] or 'unknown'}, framework {this['framework_version'] or 'unknown'}"
    )
    checkout = document["checkout"]
    where = f"{checkout['branch']} at {_short(checkout['head'])}"
    if checkout["remote_tip"] is None:
        where += f", origin/{checkout['branch']} never fetched"
    else:
        where += (
            f", {checkout['ahead']} ahead and {checkout['behind']} behind origin/{checkout['branch']}"
            f" as of {checkout['fetched_at'] or 'the last fetch'}"
        )
    if checkout["changes"]:
        where += f", {len(checkout['changes'])} changed path(s)"
    lines.append(f"checkout    {where}")
    active = document["activation"]
    if active["tree_oid"] is None:
        lines.append("generation  none recorded: dotsteward rebuild activates the checkout")
    else:
        said = "is the checkout" if active["active"] else "is not the checkout: dotsteward rebuild activates it"
        e2e = {"pass": "E2E passed", "fail": "E2E FAILED"}.get(str(active["e2e"]), "E2E not run on it")
        lines.append(f"generation  {said}; {e2e}")
    lines.append("components")
    for row in document["components"]:
        parts = [row["method"] or "default method"]
        if row["here"]:
            parts.append(row["installed"] or "here")
        else:
            parts.append(f"not here ({row['reason']})")
        if row["updater"]:
            parts.append(f"updater {row['updater']}")
        if row["constraint"]:
            parts.append(f"version {row['constraint']['version']}")
        for hold in row["held"]:
            parts.append(f"held at {hold.get('version')} ({hold.get('reason')})")
        lines.append(f"  {row['name']:<24} " + ", ".join(str(part) for part in parts))
    updates = document["updates"]
    if updates["rows"]:
        lines.append(f"newer versions (research of {updates['researched_at']})")
        for row in updates["rows"]:
            lines.append(f"  {row['id']}: {row['current']} -> {row['latest']} ({row['status']})")
    if document["incoming"]:
        lines.append("from other machines, waiting for an answer (dotsteward incoming)")
        for item in document["incoming"]:
            lines.append(f"  {item.get('id')}: {item.get('change')} by {item.get('by') or 'unknown'}")
    skills = document["skills"]
    own = sum(1 for row in skills["entries"] if row["own"])
    away = [row["name"] for row in skills["entries"] if not row["here"]]
    lines.append(
        f"skills      {len(skills['entries'])} tracked ({own} own), tracking {'on' if skills['tracking'] else 'off'}"
        + (f", not here: {', '.join(away)}" if away else "")
        + (f", capture waits: {', '.join(skills['capture_waiting'])}" if skills["capture_waiting"] else "")
    )
    plugins = document["plugins"]
    away = [row["name"] for row in plugins if not row["here"]]
    lines.append(f"plugins     {len(plugins)} tracked" + (f", not here: {', '.join(away)}" if away else ""))
    recorded = document["state"]
    if recorded is None:
        lines.append("state       no record of this machine (dotsteward state record)")
    else:
        lines.append(
            f"state       recorded {recorded['recorded_at']} by {recorded['recorded_by']}"
            + (", waits for the push (dotsteward state push)" if recorded["waiting"] else "")
        )
    if document["orphans"]:
        lines.append(f"orphans     {', '.join(document['orphans'])}: in the last record here, no longer in the intent")
    if document["review"]:
        lines.append("review.json")
        for item in document["review"]:
            lines.append(
                f"  {item.get('command')}: {item.get('code')}" + (f": {item['run']}" if item.get("run") else "")
            )
    return lines


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dotsteward status", description=_DESCRIPTION)
    parser.add_argument("--json", action="store_true", help="print one JSON document")
    options = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        instance = config.load_instance()
        document = overview(instance)
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return 1
    if options.json:
        json.dump(document, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print("\n".join(human(document)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
