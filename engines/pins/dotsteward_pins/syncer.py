"""Writes the derived values of the lock files: the body of ``pins sync``, which
``pins apply`` calls between its own writes."""

from __future__ import annotations

import datetime
from collections.abc import Mapping, Sequence

from dotsteward_cli import atomic

from .checker import GROUP_ERRORS, describe_os_error
from .instance import EngineError, Instance, Refusal
from .lockfile import SKILLS, VERSIONS, Locks, dump, generated_at
from .rules import Context, build_rules

MAX_SYNC_PASSES = 10


def write_changed(instance: Instance, locks: Locks, before: Mapping[str, str]) -> list[str]:
    """Writes the documents that differ from BEFORE (their text by kind), each with
    a new generated_at, and returns their labels."""
    now = datetime.datetime.now(datetime.UTC)
    written = []
    for kind, path, label in (
        (VERSIONS, instance.versions_path, instance.versions_label),
        (SKILLS, instance.skills_path, instance.skills_label),
    ):
        document = locks.documents.get(kind)
        if document is None or dump(document) == before.get(kind):
            continue
        document["generated_at"] = generated_at(kind, now)
        atomic.atomic_write(path, dump(document))
        written.append(label)
    return written


def sync_locks(instance: Instance, nix: bool, skills: Sequence[str]) -> list[str]:
    """Rewrites the derived values until they settle; the labels of the files
    written. Refusal for an unknown skill, untracked files before a Nix call or a
    rule that cannot run."""
    if nix:
        instance.refuse_untracked()
    rules = [rule for rule in build_rules(instance) if rule.SYNCS]
    locks = instance.load_locks()
    if skills:
        entries = locks.documents.get(SKILLS, {}).get("skills", [])
        known = {item.get("name") for item in entries if isinstance(item, dict)}
        unknown = sorted(set(skills) - known)
        if unknown:
            raise Refusal(f"skill not in lock: {', '.join(unknown)}")
    before = {kind: dump(document) for kind, document in locks.documents.items()}
    ctx = Context(instance, locks, nix=nix, extra_skills=frozenset(skills))

    for _ in range(MAX_SYNC_PASSES):
        snapshot = {kind: dump(document) for kind, document in locks.documents.items()}
        failures = []
        for rule in rules:
            try:
                rule.sync(ctx)
            except GROUP_ERRORS as error:
                failures.append(f"{rule.group}: missing or invalid lock field ({error!r})")
            except OSError as error:
                failures.append(f"{rule.group}: {describe_os_error(error, instance.root)}")
        if failures:
            raise Refusal(*failures)
        if snapshot == {kind: dump(document) for kind, document in locks.documents.items()}:
            break
    else:
        raise EngineError(f"sync did not settle after {MAX_SYNC_PASSES} passes; the derive rules form a cycle")

    return write_changed(instance, locks, before)
