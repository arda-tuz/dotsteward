"""Holds: what `upgrade` keeps back, and why, in the machine layer.

A hold is a table ``[holds."<kind>:<name>"]`` of ``hosts/<name>.toml`` with ``version``, ``reason``
and ``since``. The kind is part of the key, so the two never mix, whatever the names are:

- **A pin hold**, ``pin:<pin id>`` (``pin:agent_tools.codex.linux``): ``upgrade`` writes it when a move
  of the pin went red on this machine, in the gate or in E2E. The pin does not take ``version``. The
  hold is over when upstream calls another version the latest (a row the research could not read
  says nothing), when the research no longer has the pin, or with ``upgrade --retry-held``.
- **A component hold**, ``component:<name>`` (or the bare name, as earlier releases wrote it): the
  owner writes it. The pins of the component take no
  version from ``version`` on, and on the machine of the file its apt packages keep their installed
  upstream version and take only its Debian revisions while they are below it. Only the owner takes
  it out; a hold of a component the instance does not have holds nothing and is said.

The shared lock reaches every machine, so the writer leaves what the host file of any machine holds,
and every run names those holds with the machine and the reason. Only the machine of a file writes
it, through ``host publish``, in a commit of its own, and not while a commit of the pins waits for
the remote (``WAITING_REF``): a hold commit first would make the remote another tip.

``<state>/holds.json`` (0600) is the record of this machine between its runs and the remote: the pin
holds it made (``published`` once the host file on the remote has them), ``released`` the pin ids to
take out of it, ``released_all`` all of its pin holds (``--retry-held``). A record of the first
release, without ``published``, is a hold that waits for its publish like a new one.
"""

from __future__ import annotations

import datetime
import json
import os
from collections.abc import Collection, Iterable, Mapping
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, machine, tomlfile, versions
from dotsteward_cli.upgrade import facts

_FILE = "holds.json"
SCHEMA_VERSION = 2
_FIELDS = ("version", "reason", "since")
PIN = "pin:"
COMPONENT = "component:"
WAITING_REF = "refs/dotsteward/upgrade/waiting"
# The rows of the research that say what upstream calls the latest; an error row says nothing.
_ANSWERS = ("update", "review", "current", "held")


def _path(state_root: str) -> Path:
    return Path(state_root) / _FILE


def _load(state_root: str) -> dict[str, Any]:
    try:
        document = json.loads(_path(state_root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        document = {}
    if not isinstance(document, dict):
        document = {}
    holds = document.get("holds")
    released = document.get("released")
    return {
        "holds": [hold for hold in holds if isinstance(hold, dict) and isinstance(hold.get("id"), str)]
        if isinstance(holds, list)
        else [],
        "released": [name for name in released if isinstance(name, str)] if isinstance(released, list) else [],
        "released_all": document.get("released_all") is True,
    }


def _save(state_root: str, document: Mapping[str, Any]) -> None:
    text = json.dumps({"schema_version": SCHEMA_VERSION, **document}, indent=2, sort_keys=True) + "\n"
    atomic.make_private_dirs(state_root)
    atomic.atomic_write(_path(state_root), text, mode=0o600)


def read(state_root: str) -> list[dict[str, Any]]:
    """The pin holds this machine made."""
    holds: list[dict[str, Any]] = _load(state_root)["holds"]
    return holds


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def add(state_root: str, component: str, identifier: str, version: str, reason: str) -> None:
    """A pin hold of this machine; the same one once. It waits for the next `host publish`."""
    document = _load(state_root)
    if any(hold["id"] == identifier and hold.get("version") == version for hold in document["holds"]):
        return
    document["holds"] = [hold for hold in document["holds"] if hold["id"] != identifier]
    document["holds"].append(
        {"component": component, "id": identifier, "version": version, "reason": reason, "since": _now()}
    )
    document["released"] = [name for name in document["released"] if name != identifier]
    _save(state_root, document)


def retry(state_root: str) -> None:
    """``--retry-held``: every pin hold of this machine goes, here and in its host file."""
    _save(state_root, {"holds": [], "released": [], "released_all": True})


def release(state_root: str, identifiers: Collection[str]) -> None:
    """The pin holds IDENTIFIERS are over: they leave the host file with the next `host publish`."""
    if not identifiers:
        return
    document = _load(state_root)
    document["holds"] = [hold for hold in document["holds"] if hold["id"] not in identifiers]
    document["released"] = sorted({*document["released"], *identifiers})
    _save(state_root, document)


def unpublished(state_root: str) -> bool:
    """Something of this machine waits for its host file."""
    document = _load(state_root)
    return (
        document["released_all"]
        or bool(document["released"])
        or any(hold.get("published") is not True for hold in document["holds"])
    )


# --- the host file ---------------------------------------------------------------------------


def component_names(instance: config.Instance, env: Mapping[str, str] | None = None) -> set[str]:
    """The components of the instance, which a component hold can name."""
    names = set((instance.config.get("components") or {}).keys())
    names.update(str(entry.get("name")) for entry in facts.mirror(instance, env).get("components") or ())
    return names


def _plain(value: Mapping[str, Any]) -> dict[str, str]:
    return {field: str(value[field]) for field in _FIELDS if value.get(field) is not None}


def table(current: Mapping[str, Any], state_root: str) -> dict[str, dict[str, str]]:
    """The ``holds`` of the host file over CURRENT (the one on the remote): the component holds stay;
    the pin holds this machine released go; the ones it holds and the remote does not have yet come.
    A published hold the remote no longer has was taken out by hand, and stays out."""
    document = _load(state_root)
    wanted: dict[str, dict[str, str]] = {}
    for key, value in current.items():
        if not isinstance(value, Mapping):
            continue
        name = str(key).removeprefix(PIN)
        if str(key).startswith(PIN) and (document["released_all"] or name in document["released"]):
            continue
        wanted[str(key)] = _plain(value)
    for hold in document["holds"]:
        if hold.get("published") is not True:
            wanted[PIN + hold["id"]] = _plain(hold)
    return wanted


def published(state_root: str, holds: Mapping[str, Mapping[str, Any]]) -> None:
    """HOLDS is what the host file on the remote has now: the record of this machine follows it."""
    document = _load(state_root)
    kept = []
    for hold in document["holds"]:
        there = holds.get(PIN + hold["id"])
        if there is None:
            # Taken out by hand after its publish, or released meanwhile: over.
            continue
        if str(there.get("version")) == str(hold.get("version")):
            hold = {**hold, "published": True}
        kept.append(hold)
    after = {"holds": kept, "released": [], "released_all": False}
    if after != document:
        _save(state_root, after)


def machine_holds(root: str | os.PathLike[str]) -> list[dict[str, str]]:
    """Every hold of the host files of the tree at ROOT: ``{machine, kind, key, version, reason,
    since}``, KEY the pin id or the component name."""
    found = []
    for name in machine.known_names(root):
        try:
            text = machine.host_path(root, name).read_text(encoding="utf-8")
            document = tomlfile.loads(text)
        except (OSError, tomlfile.TomlError):
            continue
        holds = document.get("holds")
        for key, value in sorted(holds.items()) if isinstance(holds, dict) else ():
            kind, separator, rest = str(key).partition(":")
            if not separator:
                # The bare name of an earlier release: a component hold.
                kind, rest = "component", str(key)
            if kind not in ("pin", "component") or not rest:
                continue
            if isinstance(value, dict) and value.get("version") is not None:
                found.append(
                    {
                        "machine": name,
                        "kind": kind,
                        "key": rest,
                        "version": str(value["version"]),
                        "reason": str(value.get("reason") or ""),
                        "since": str(value.get("since") or ""),
                    }
                )
    return found


def in_force(state_root: str, root: str | os.PathLike[str], me: str | None) -> list[dict[str, str]]:
    """The holds that count now: those of every host file at ROOT and those of this machine that wait
    for their publish, without what this machine released."""
    document = _load(state_root)
    holds: dict[tuple[str, str, str], dict[str, str]] = {}
    for hold in machine_holds(root):
        if (
            hold["machine"] == me
            and hold["kind"] == "pin"
            and (document["released_all"] or hold["key"] in document["released"])
        ):
            continue
        holds[(hold["machine"], hold["kind"], hold["key"])] = hold
    for hold in document["holds"]:
        if me is not None and (me, "pin", hold["id"]) not in holds:
            holds[(me, "pin", hold["id"])] = {
                "machine": me,
                "kind": "pin",
                "key": hold["id"],
                "version": str(hold.get("version")),
                "reason": str(hold.get("reason") or ""),
                "since": str(hold.get("since") or ""),
            }
    return [holds[key] for key in sorted(holds)]


def component_holds(root: str | os.PathLike[str], me: str | None) -> dict[str, dict[str, str]]:
    """The component holds of the host file of this machine, by component: what binds its apt."""
    return {hold["key"]: hold for hold in machine_holds(root) if hold["machine"] == me and hold["kind"] == "component"}


# --- the writer ----------------------------------------------------------------------------


def _latest_rows(latest: str | os.PathLike[str]) -> tuple[set[str], dict[str, str]]:
    """The ids the research has, and of those the newest version upstream calls the latest; a row
    the research could not read says nothing about it."""
    try:
        document = json.loads(Path(latest).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return set(), {}
    rows = document.get("items") if isinstance(document, dict) else None
    known: set[str] = set()
    found: dict[str, str] = {}
    for row in rows if isinstance(rows, list) else ():
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            continue
        known.update([row["id"], *(str(name) for name in (row.get("details") or {}).get("ids") or ())])
        if row.get("status") in _ANSWERS and row.get("latest") is not None:
            found[row["id"]] = str(row["latest"])
    return known, found


def _owned_by(identifier: str, component: str, owners: Mapping[str, str]) -> bool:
    return owners.get(identifier) == component or component in identifier.split(".")


def skip_patterns(
    state_root: str,
    latest: str | os.PathLike[str],
    holds: Iterable[Mapping[str, str]],
    me: str | None,
    owners: Mapping[str, str],
) -> list[str]:
    """The pins the writer leaves alone. A pin hold is over when upstream calls another version the
    latest, or when the research no longer has the pin: what comes now gets its own chance, and one of
    this machine leaves its host file. A row the research could not read keeps it. A component hold
    leaves every pin of the component whose newest version it does not take."""
    known, rows = _latest_rows(latest)
    skips: list[str] = []
    over: list[str] = []
    for hold in holds:
        if hold["kind"] == "pin":
            gone = bool(known) and hold["key"] not in known
            if gone or rows.get(hold["key"], hold["version"]) != hold["version"]:
                if hold["machine"] == me:
                    over.append(hold["key"])
                continue
            skips.append(hold["key"])
            continue
        for identifier, newest in sorted(rows.items()):
            if _owned_by(identifier, hold["key"], owners) and versions.compare(newest, hold["version"]) >= 0:
                skips.append(identifier)
    release(state_root, over)
    return list(dict.fromkeys(skips))
