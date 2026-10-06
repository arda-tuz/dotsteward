"""``settings validate``: the static lint of a settings buffer.

It checks ``<settings.buffer_dir>/buffer.toml`` and its ``files/`` directory
without reading a live file, taking the lock or creating the state
directory: schema version 1, the allowed top-level, target and entry fields,
``~/`` paths (every platform of a per-platform path), formats and modes,
entry ids, the secret and home guards (the home is ``--home``), unique ids
and identities, no key tracked inside another, known targets (buffer and
component targets), the ``files/`` directory holding exactly the sources of
the file entries, and the executable bit of each source agreeing with its
entry's mode (Git and the Nix store keep only that bit).

The target and entry rules are the engine's own (``Target`` and ``Entry``),
so a buffer that passes here is one the engine accepts. Unlike the engine,
validate reports every problem it finds, not only the first.
"""

from __future__ import annotations

import collections.abc
import os
import stat
from typing import Any

TOP_LEVEL_KEYS = {"schema_version", "targets", "entries"}
# Stands in for a broken buffer target, so its entries are still checked.
PLACEHOLDER_TARGET = {"path": "~/.placeholder", "format": "json", "create_if_missing": False}


class Validation:
    def __init__(self, context: Any) -> None:
        self.context = context
        self.engine = context.engine
        self.problems: list[str] = []
        self.entry_count = 0
        self.target_count = 0

    def problem(self, error: Any) -> None:
        self.problems.extend(error.messages)

    def run(self) -> None:
        engine = self.engine
        doc = engine.parse_toml(engine.read_buffer_text(self.context.buffer_path), self.context.buffer_path)
        unknown = set(doc) - TOP_LEVEL_KEYS
        if unknown:
            self.problems.append(f"unknown top-level fields {sorted(unknown)}")
        if engine.plain(doc.get("schema_version")) != engine.SCHEMA_VERSION:
            self.problems.append(f"schema_version must be {engine.SCHEMA_VERSION}")
        targets = self.check_targets(doc)
        entries = self.check_entries(doc, targets)
        self.check_files(entries, engine.plain(doc.get("entries")))

    def check_targets(self, doc: Any) -> dict[str, Any]:
        engine = self.engine
        targets = dict(self.context.component_targets)
        raw_targets = engine.plain(doc.get("targets")) or {}
        if not isinstance(raw_targets, dict):
            self.problems.append("targets must be tables")
            return targets
        for name, spec in raw_targets.items():
            if not isinstance(spec, dict):
                self.problems.append(f"targets.{name} must be a table")
                continue
            try:
                targets[name] = engine.Target(name, spec, self.context.platform)
            except engine.LmfError as error:
                self.problem(error)
                targets[name] = engine.Target(name, PLACEHOLDER_TARGET, self.context.platform)
        self.target_count = len(targets)
        return targets

    def check_entries(self, doc: Any, targets: dict[str, Any]) -> list[Any]:
        engine = self.engine
        raw_entries = doc.get("entries") or []
        if not isinstance(raw_entries, list):
            self.problems.append("entries must be an array of tables")
            return []
        self.entry_count = len(raw_entries)
        entries = []
        seen_ids: set[str] = set()
        seen_identities: set[str] = set()
        for item in raw_entries:
            try:
                entry = engine.Entry(item, targets, self.context.home)
            except engine.LmfError as error:
                self.problem(error)
                continue
            if entry.id in seen_ids:
                self.problems.append(f"duplicate entry id: {entry.id}")
            elif entry.identity in seen_identities:
                self.problems.append(f"the same target and key twice: {entry.label}")
            else:
                seen_ids.add(entry.id)
                seen_identities.add(entry.identity)
                entries.append(entry)
        keys = [entry for entry in entries if entry.kind == "key"]
        for first in keys:
            for second in keys:
                if first is not second and first.target is second.target and second.key[: len(first.key)] == first.key:
                    self.problems.append(f"{second.id} lies inside {first.id}; a path cannot be tracked twice")
        return entries

    def check_files(self, entries: list[Any], raw_entries: Any) -> None:
        engine = self.engine
        files_dir = self.context.files_dir
        files_rel = self.context.files_rel
        for entry in entries:
            if entry.kind != "file" or entry.absent:
                continue
            source = os.path.join(files_dir, entry.source)
            where = f"{files_rel}/{entry.source}"
            if os.path.islink(source) or not os.path.isfile(source):
                self.problems.append(f"{entry.id}: repository source missing: {where}")
                continue
            try:
                with open(source, "rb") as handle:
                    data = handle.read()
                executable = bool(os.stat(source).st_mode & stat.S_IXUSR)
            except OSError as error:
                self.problems.append(f"{entry.id}: cannot read {where}: {error.strerror}")
                continue
            try:
                engine.check_file_content(data, entry.id, self.context.home)
            except engine.LmfError as error:
                self.problem(error)
            if bool(int(entry.mode, 8) & stat.S_IXUSR) != executable:
                self.problems.append(f"{entry.id}: mode {entry.mode} disagrees with the executable bit of {where}")

        # Every source named by a present file entry, valid or not, so a broken
        # entry is reported once (above) and its source is not an orphan too.
        sources = set()
        for item in raw_entries if isinstance(raw_entries, list) else []:
            if (
                isinstance(item, collections.abc.Mapping)
                and item.get("kind") == "file"
                and item.get("absent") is not True
                and isinstance(item.get("source"), str)
            ):
                sources.add(item["source"])
        if not os.path.isdir(files_dir):
            return
        for name in sorted(os.listdir(files_dir)):
            path = os.path.join(files_dir, name)
            if os.path.islink(path) or not os.path.isfile(path):
                self.problems.append(f"{files_rel}/{name} is not a regular file")
            elif name not in sources:
                self.problems.append(f"{files_rel}/{name} is not the source of any file entry")


def main(context: Any) -> int:
    """Validates the buffer of CONTEXT; 0 when it is valid, 2 otherwise."""
    engine = context.engine
    validation = Validation(context)
    validation.run()
    problems = validation.problems
    if problems:
        for message in problems:
            engine.report_error(message)
        count = len(problems)
        engine.report_error(
            f"validate: {count} problem{'s' if count != 1 else ''} in {context.buffer_rel}; "
            f"fix the buffer (see {engine.MAINTAIN_SKILL})"
        )
        return engine.EXIT_ERROR
    engine.log(
        f"validate: {context.buffer_rel} is valid ({validation.entry_count} entries, {validation.target_count} targets)"
    )
    return engine.EXIT_OK
