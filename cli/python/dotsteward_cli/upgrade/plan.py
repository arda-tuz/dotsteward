"""``dotsteward upgrade --plan``: what both modes would do. No lock, no write, no sudo: the remote is
only asked where it stands. The same engines answer as in a run, so the plan is no second opinion.
"""

from __future__ import annotations

import os
from collections.abc import Mapping, Sequence
from typing import Any

from dotsteward_cli import apt_plan, config, firmware, machine, report
from dotsteward_cli import publish as publishing
from dotsteward_cli.upgrade import analysis, facts


def _apt(request: apt_plan.Request) -> dict[str, Any]:
    try:
        return apt_plan.plan(request)
    except apt_plan.AptEngineError as failure:
        return {"available": False, "error": f"{failure.code}: {failure.message}"}


def _remote(instance: config.Instance) -> dict[str, Any]:
    branch = instance.config["instance"]["branch"]
    done = publishing.git(
        instance.root, "ls-remote", "origin", f"refs/heads/{branch}", seconds=publishing.FETCH_SECONDS
    )
    if publishing.classify(done) != publishing.OK:
        return {"reachable": False}
    tip = done.stdout.split()[0] if done.stdout.split() else ""
    head = publishing.git(instance.root, "rev-parse", "HEAD").stdout.strip()
    return {"reachable": True, "tip": tip, "up_to_date": tip == head}


def build(instance: config.Instance, accept: Sequence[str]) -> dict[str, Any]:
    env = os.environ
    effective = machine.effective(instance, env)
    profile = effective["profile"]
    active = facts.active_components(instance, profile, env)
    mirror = facts.mirror(instance, env)
    tracked = facts.tracked_packages(active, instance)
    shared: dict[str, Any] = {
        "accept": tuple(accept),
        "constraints": facts.constraints(active, instance),
        "gated": facts.gated(instance, effective["name"]),
    }
    remote = _remote(instance)
    channels = analysis.read_user_channels(facts.tracked_commands(mirror, active), not remote["reachable"], env)
    listing = firmware.list_updates()
    return {
        "machine": effective["name"],
        "profile": profile,
        "remote": remote,
        "producer": facts.role(instance, effective["name"]),
        "self": [entry.component for entry in facts.self_updates(active, instance)],
        "tracked": {"apt": _apt(apt_plan.Request(mode="tracked", tracked=tracked, **shared))},
        "all": {"apt": _apt(apt_plan.Request(mode="all", tracked=tracked, **shared))},
        "channels": channels,
        "firmware": listing.to_json(),
        "status": report.status_name(report.OK),
    }


def _changes(answer: Mapping[str, Any]) -> str:
    if answer.get("error"):
        return f"apt: {answer['error']}"
    changes = answer.get("changes") or {}
    parts = [f"{len(changes.get(bucket) or [])} {bucket}" for bucket in ("install", "upgrade", "remove")]
    return "apt: " + ", ".join(parts)


def text(document: Mapping[str, Any]) -> str:
    remote = document["remote"]
    where = "not reachable" if not remote["reachable"] else "up to date" if remote["up_to_date"] else "ahead of here"
    said = [
        f"Machine: {document['machine'] or 'no name yet'}, profile {document['profile'] or 'unknown'}",
        f"Remote: {where}",
        f"Pins move on: {document['producer']}",
        "Own updaters: " + (", ".join(document["self"]) or "none"),
        "Tracked only:",
        f"  {_changes(document['tracked']['apt'])}",
        "Everything:",
        f"  {_changes(document['all']['apt'])}",
    ]
    said += [f"  {line}" for line in analysis.lines(document["channels"]) if not line.startswith("apt")]
    installable = (document["firmware"] or {}).get("installable") or []
    said.append(f"Firmware: {len(installable)} can be applied, only after a yes on a terminal")
    return "\n".join(said)
