"""``dotsteward add`` and ``dotsteward remove``: tracking a component, as one maintain transaction
(docs/track.md).

A person tells the agent to track a piece of software; ``add NAME`` turns that into the intent and
publishes it with the one ``dotsteward apply``. It opens the transaction with ``maintain begin``,
works out the channel of NAME, writes ``[components.NAME]`` into workstation.toml with tomlkit (the
comments and the layout of the file stay), for a clear channel outside the catalog also the
component of the instance in ``components/NAME/default.nix``, and then runs ``apply`` with the
options it was given. A channel that needs research (pins, hashes, a vendor source) is no guess:
``add`` writes nothing and asks for it (``channel-unknown``), the agent writes the component by the
maintain skill and runs the same ``add``, which then finds it.

``remove NAME`` is the reverse: the table, the entry of ``[components] order`` and for a component
of the instance its directory go, through the same ``apply``. The software stays where something
other than the Home Manager profile put it (APT, a downloaded binary, a virtual environment,
system files); only ``--uninstall`` removes that, after the commit landed, and only what no other
component names. What Home Manager installed (the ``nix`` method, the links of a component) leaves
the profile at the next activation, as it does for any change of the intent.

Each command commits only its own change. What else waits between the remote and the work tree is
a question of ``maintain begin``, so the command writes nothing and exits 3 with it; what an earlier
run of the same command for the same component left (a red gate, no network, a person's sudo step)
is its own, and the same command finishes it. Both hold the instance lock; begin and apply run
nested in it, through the dispatcher, so every guard, step, report and exit status of theirs stays
as it is.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, context, locks, machine, platforms, report, runner, tomlfile
from dotsteward_cli.skills import layout
from dotsteward_cli.upgrade import holds

EXIT_USAGE = 2
SCHEMA_VERSION = 1
_SUBJECT = re.compile(r"^(" + "|".join(context.CONVENTIONAL_TYPES) + r")(\([a-z0-9._/-]+\))?!?: .+")
_APT_PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]+")
_NIX_ATTRIBUTE = re.compile(r"[A-Za-z_][A-Za-z0-9_'-]*(\.[A-Za-z_][A-Za-z0-9_'-]*)*")
# The words Nix reserves: no attribute name or path part without quotes ("or" is not one).
NIX_KEYWORDS = frozenset({"let", "in", "rec", "if", "then", "else", "assert", "with", "inherit"})
_COMMAND = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
_LIST_VALUE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# What begin asks that this command answers itself when the change is its own.
_OWN_QUESTIONS = {"checkout-dirty", "unpublished-commits"}
# What begin asks that is no business of this command: a note.
_NOTES = {"settings-local"}
_SCOPED_KEYS = ("method", "profiles", "machines", "tags", "updater")
_UNINSTALL_DIRECTORY = "track"

_ADD_DESCRIPTION = (
    "Tracks a component: opens a maintain transaction, writes [components.NAME] with enable = true into "
    "workstation.toml and finishes it with the one dotsteward apply, under the subject 'feat: track NAME'. "
    "NAME is a catalog component, a component of the instance in components/NAME/default.nix, plain APT "
    "packages (--apt) or a nixpkgs package (--nix), which become such a component. Any other channel needs "
    "research: nothing is written and channel-unknown says how to go on. Only this change is committed: other "
    "changes of the checkout or commits the remote lacks are questions. Run the same command again after a red "
    "step or a sudo step: it finishes. Exit status: the one of apply (0 done, 1 a refusal or a red step, "
    "3 a sudo step or a person waits, 6 no network: the push waits); 2 usage error; 3 also a question before "
    "anything was written."
)
_REMOVE_DESCRIPTION = (
    "Stops tracking a component: opens a maintain transaction, removes [components.NAME], its entry of "
    "[components] order and, for a component of the instance, components/NAME, and finishes it with the one "
    "dotsteward apply, under the subject 'feat: stop tracking NAME'. Only files a commit holds go; anything else in "
    "components/NAME stays or is a question (untracked-files). The software stays installed. A nix component would "
    "leave the profile of every machine it is for: a plain remove asks (profile-removal); --uninstall confirms, "
    "--keep-here keeps it on this machine only. --uninstall also removes, once the removal is published, what the "
    "component provably installed outside the profile and no other component names: its APT packages (through sudo "
    "on a terminal, else uninstall-required with the command, exit 3), an official binary that answers its version "
    "probe, a Python environment and its links below HOME. A component that another one requires stays. Exit "
    "status: as for dotsteward add."
)


class UsageError(Exception):
    """A command line that cannot work, exit 2."""


class Refusal(Exception):
    """The command does nothing, exit 1."""


def _say(prefix: str, text: str) -> None:
    print(f"[{prefix}] {text}", flush=True)


def _error(text: str) -> None:
    print(f"[dotsteward] ERROR: {text}", file=sys.stderr, flush=True)


def _tomlkit() -> Any:
    try:
        import tomlkit
    except ImportError as error:
        raise Refusal("this command needs tomlkit; run it with the framework's own python3") from error
    return tomlkit


def _plain(value: Any) -> Any:
    """A tomlkit item as the plain value it holds."""
    unwrap = getattr(value, "unwrap", None)
    return unwrap() if callable(unwrap) else value


def _list(values: Sequence[str] | None, what: str, pattern: re.Pattern[str] = _LIST_VALUE) -> list[str] | None:
    """The values of a repeated or comma-separated option, in order, each once; None when not given."""
    if values is None:
        return None
    found: list[str] = []
    for value in values:
        for part in value.split(","):
            part = part.strip()
            if not pattern.fullmatch(part):
                raise UsageError(f"{what}: {part!r} is not a valid name")
            if part not in found:
                found.append(part)
    if not found:
        raise UsageError(f"{what} needs at least one name")
    return found


def _without(document: Mapping[str, Any], name: str) -> dict[str, Any]:
    """The parsed workstation.toml without anything about the component NAME."""
    copy: dict[str, Any] = json.loads(json.dumps(document, default=str))
    components = copy.get("components")
    if isinstance(components, dict):
        components.pop(name, None)
        order = components.get("order")
        if isinstance(order, list):
            components["order"] = [entry for entry in order if entry != name]
    return copy


# --- workstation.toml as text ------------------------------------------------------------------
#
# A table goes where a person would put it and leaves every comment where it was: tomlkit hangs the
# comment above a header onto the table before it, so a table it adds lands between a comment and
# the header that comment is about. These edits work on lines; each result is checked against the
# document it must parse to, and tomlkit's edit is the fallback for a layout they do not know.

_HEADER = re.compile(r"^\s*\[\[?\s*([A-Za-z0-9_.-]+)\s*\]\]?\s*(#.*)?$")


def _normal(document: Any) -> Any:
    return json.loads(json.dumps(document, default=str))


def _headers(lines: Sequence[str]) -> list[tuple[int, str]]:
    found = []
    for index, line in enumerate(lines):
        matched = _HEADER.match(line)
        if matched:
            found.append((index, matched.group(1)))
    return found


def _is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def _lead(lines: Sequence[str], index: int) -> int:
    """The first line of the comments right above the header at INDEX, which are about it."""
    while index > 0 and _is_comment(lines[index - 1]):
        index -= 1
    return index


def _next_lead(lines: Sequence[str], headers: Sequence[tuple[int, str]], index: int) -> int:
    """Where what follows the block of the header at INDEX begins: the lead of the next header."""
    later = [at for at, _ in headers if at > index]
    return _lead(lines, later[0]) if later else len(lines)


def _block_end(lines: Sequence[str], headers: Sequence[tuple[int, str]], index: int) -> int:
    """The line after the last key of the table whose header is at INDEX. The comments after it,
    right below or after a blank line, are about what follows: a section, the next table."""
    later = [at for at, _ in headers if at > index]
    end = later[0] if later else len(lines)
    while end > index + 1 and (not lines[end - 1].strip() or _is_comment(lines[end - 1])):
        end -= 1
    return end


def _read(path: Path) -> str:
    """The text of PATH with its own line endings."""
    return path.read_bytes().decode("utf-8")


def _by_lf(edit: Callable[[str], str | None]) -> Callable[[str], str | None]:
    """EDIT on the LF form of a text whose every line ends in CRLF, and the result in CRLF again;
    any other text as it is."""

    def edited(text: str) -> str | None:
        crlf = "\r\n" in text and text.count("\r\n") == text.count("\n")
        result = edit(text.replace("\r\n", "\n") if crlf else text)
        return result.replace("\n", "\r\n") if crlf and result is not None else result

    return edited


def _comment(text: str) -> str:
    """TEXT as the comment lines at the top of a Nix file."""
    return "".join(f"# {line}\n" for line in textwrap.wrap(text, width=98, break_on_hyphens=False))


def _value(value: Any) -> str:
    if value is True or value is False:
        return "true" if value else "false"
    return json.dumps(value)


def _place_table(text: str, name: str, values: Mapping[str, Any]) -> str:
    """TEXT with [components.NAME] after the last block of [components]."""
    lines = text.splitlines(keepends=True)
    headers = _headers(lines)
    rendered = f"[components.{name}]\n" + "".join(f"{key} = {_value(value)}\n" for key, value in values.items())
    ours = [at for at, header in headers if header == "components" or header.startswith("components.")]
    if not ours:
        body = text if not text or text.endswith("\n") else text + "\n"
        return body + ("\n" if body.strip() else "") + rendered
    end = _block_end(lines, headers, ours[-1])
    before = "".join(lines[:end])
    if not before.endswith("\n"):
        before += "\n"
    return before + "\n" + rendered + "".join(lines[end:])


def _add_keys(text: str, name: str, values: Mapping[str, Any]) -> str | None:
    """TEXT with VALUES as new keys at the end of the table [components.NAME]; None without its header."""
    lines = text.splitlines(keepends=True)
    headers = _headers(lines)
    at = next((index for index, header in headers if header == f"components.{name}"), None)
    if at is None:
        return None
    end = _block_end(lines, headers, at)
    before = "".join(lines[:end])
    if not before.endswith("\n"):
        before += "\n"
    return before + "".join(f"{key} = {_value(value)}\n" for key, value in values.items()) + "".join(lines[end:])


def _set_keys(text: str, name: str, values: Mapping[str, Any]) -> str | None:
    """TEXT with VALUES in the table [components.NAME]: a key the table has changes in place, a
    new one goes at the end of the table. None when the table has no header of its own."""
    tomlkit = _tomlkit()
    document = tomlkit.parse(text)
    entry = (document.get("components") or {}).get(name)
    if entry is None:
        return None
    fresh = {}
    for key, value in values.items():
        if key in entry:
            entry[key] = value
        else:
            fresh[key] = value
    changed: str = tomlkit.dumps(document)
    return _add_keys(changed, name, fresh) if fresh else changed


def _drop_table(text: str, name: str) -> tuple[str, list[str]]:
    """TEXT without [components.NAME] and its sub-tables, and the comments it kept. A table is its
    header and its keys. The comment right above the header goes with it when it names the
    component; else it stays, as a paragraph of its own, since it may be about more than this
    table. A comment after the keys, or one a blank line keeps apart, is about what follows."""
    lines = text.splitlines(keepends=True)
    headers = _headers(lines)
    own = re.compile(rf"(?<![a-z0-9-]){re.escape(name)}(?![a-z0-9-])")
    prefix = f"components.{name}"
    targets = [at for at, header in headers if header == prefix or header.startswith(f"{prefix}.")]
    kept: list[str] = []
    drop: set[int] = set()
    pad_after: set[int] = set()
    for at in targets:
        lead = _lead(lines, at)
        start = lead
        if lead < at and not any(own.search(line) for line in lines[lead:at]):
            start = at
            kept.append("".join(lines[lead:at]).strip())
            pad_after.add(at - 1)
        end = _block_end(lines, headers, at)
        # The blank lines after the table go with it when a blank line comes before it, so one
        # blank line stays between what was above and what follows.
        if start == 0 or not lines[start - 1].strip() or start - 1 in pad_after:
            while end < len(lines) and not lines[end].strip():
                end += 1
        drop.update(range(start, end))
    out: list[str] = []
    for index, line in enumerate(lines):
        if index in drop:
            continue
        out.append(line if line.endswith("\n") else line + "\n")
        following = next((later for later in range(index + 1, len(lines)) if later not in drop), None)
        if index in pad_after and following is not None and lines[following].strip():
            out.append("\n")
    result = "".join(out)
    while result.endswith("\n\n"):
        result = result[:-1]
    return result, kept


def _strip_component(text: str, name: str) -> str:
    """TEXT with nothing about the component NAME: its table, wherever it is, and its order entry."""
    import tomlkit

    dropped, _ = _drop_table(text, name)
    document = tomlkit.parse(dropped)
    components = document.get("components")
    if components is not None:
        if name in components:
            del components[name]
        order = components.get("order")
        if order is not None:
            for index in reversed(range(len(order))):
                if _plain(order[index]) == name:
                    del order[index]
    stripped: str = tomlkit.dumps(document)
    return stripped


class _Transaction(runner.Runner):
    """What add and remove share: the instance, begin, the check that only their change waits, apply."""

    command = ""

    def __init__(self, instance: config.Instance, state_root: str, options: argparse.Namespace) -> None:
        super().__init__(instance, state_root, "apply")
        self.options = options
        self.name: str = options.name
        self.run = report.RunReport(self.command, state_root)
        self.ask: list[dict[str, Any]] = []
        self.notes: list[str] = []
        self.change: str | None = None
        self.apply_report: dict[str, Any] | None = None
        self.code = report.OK
        self.subject = options.subject or self.default_subject()
        self.taken: list[str] | None = None
        self.replace_scaffold = False
        self.run.data.update(component=self.name)

    def default_subject(self) -> str:
        raise NotImplementedError

    def execute(self) -> int:
        raise NotImplementedError

    # --- the transaction -----------------------------------------------------------------

    def _begin(self) -> str | None:
        """Opens the transaction. The base it knows, or None when the run stops here (self.code)."""
        arguments = ["maintain", "begin", "--json"]
        if self.options.profile:
            arguments += ["--profile", self.options.profile]
        done = self._ds_output(*arguments)
        try:
            document = json.loads(done.stdout)
        except ValueError:
            document = None
        if done.returncode not in {report.OK, report.PENDING, report.PARTIAL} or not isinstance(document, dict):
            self.run.step("begin", done.returncode or report.FAILED, detail=(document or {}).get("refused"))
            self.code = report.FAILED
            return None
        self.run.step("begin", report.OK)
        base = document.get("base_oid")
        if not isinstance(base, str) or not base:
            self.code = report.FAILED
            _error("maintain begin knows no base: the remote was never fetched")
            return None
        foreign = self._foreign(base)
        for question in document.get("ask") or ():
            code = question.get("code")
            if code in _NOTES:
                self.notes.append(f"{code}: {question.get('message')}")
            elif code in _OWN_QUESTIONS and not foreign:
                continue
            elif code == "checkout-dirty" and self.options.with_changes:
                self.taken = foreign
                if foreign:
                    _say(self.command, f"--with-changes takes along: {', '.join(foreign)}")
                continue
            else:
                self.ask.append(question)
        if self.ask:
            self._asked()
            return None
        # begin may have brought the checkout forward: what follows reads the tree it brought.
        self.instance = config.load_instance(str(self.root))
        return base

    def _asked(self) -> None:
        for question in self.ask:
            self.run.item(str(question.get("code")), **{k: v for k, v in question.items() if k != "code"})
        self.code = report.PENDING

    def _foreign(self, base: str) -> list[str]:
        """The paths whose change between BASE and the work tree is not about this component."""
        listed = self._git("diff", "--name-only", "--no-renames", base, "--").stdout.splitlines()
        listed += self._git("ls-files", "--others", "--exclude-standard").stdout.splitlines()
        foreign = []
        for path in sorted(set(filter(None, listed))):
            if path.startswith((f"components/{self.name}/", ".dotsteward/")):
                continue
            if path == config.CONFIG_FILE and self._same_intent_but_this(base):
                continue
            if self._own_host_file(path) and self._same_host_but_this(base, path):
                continue
            foreign.append(path)
        return foreign

    def _own_host_file(self, path: str) -> bool:
        this = machine.current_name(machine.read_machine(self.state_root), self.env)
        return this is not None and path == f"{machine.HOSTS_DIR}/{this}.toml"

    def _same_host_but_this(self, base: str, path: str) -> bool:
        """Whether this machine's host file differs from BASE only in what it says of the component."""

        def without(text: str) -> Any:
            document = tomlfile.loads(text) if text else {}
            names = (document.get("declined") or {}).get("components")
            if isinstance(names, list):
                document["declined"]["components"] = [name for name in names if name != self.name]
            (document.get("holds") or {}).pop(self.name, None)
            return _normal(document)

        before = self._git("show", f"{base}:{path}")
        try:
            same: bool = without(before.stdout if before.code == 0 else "") == without(_read(self.root / path))
            return same
        except (OSError, tomlfile.TomlError):
            return False

    def _same_intent_but_this(self, base: str) -> bool:
        """Whether workstation.toml differs from BASE only in the table and the order entry of the
        component: a comment changed anywhere else is someone else's change."""
        before = self._git("show", f"{base}:{config.CONFIG_FILE}")
        try:
            old = before.stdout if before.code == 0 else ""
            new = _read(self.instance.file)
            return _strip_component(old.replace("\r\n", "\n"), self.name) == _strip_component(
                new.replace("\r\n", "\n"), self.name
            )
        except Exception:  # an unreadable or broken file: not provably ours
            return False

    def _pending_since(self, base: str) -> bool:
        """Whether anything waits between BASE and the work tree: a change or a commit."""
        if self._git("rev-list", "--count", f"{base}..HEAD").stdout.strip() not in {"", "0"}:
            return True
        return not self._checkout_clean()

    def _edited(self, edit: Callable[[Any], None], by_lines: Callable[[str], str | None], expected: Any) -> str:
        """The new text of workstation.toml: BY_LINES of the text, when it parses to EXPECTED; else
        EDIT of the tomlkit document. Valid, or UsageError."""
        text = _read(self.instance.file)
        new_text = _by_lf(by_lines)(text)
        try:
            same = new_text is not None and _normal(tomlfile.loads(new_text)) == _normal(expected)
        except tomlfile.TomlError:
            same = False
        if new_text is None or not same:
            tomlkit = _tomlkit()
            document = tomlkit.parse(text)
            edit(document)
            new_text = tomlkit.dumps(document)
        problems = config.errors(tomlfile.loads(new_text))
        if problems:
            raise UsageError("workstation.toml would not be valid: " + "; ".join(problems))
        return new_text

    def _apply(self) -> None:
        arguments = ["apply", "-m", self.subject]
        if self.options.activate is not None:
            arguments.append("--activate" if self.options.activate else "--no-activate")
        if self.options.publish is not None:
            arguments.append("--publish" if self.options.publish else "--no-publish")
        if self.options.profile:
            arguments += ["--profile", self.options.profile]
        before = report.load_last(self.state_root, "apply")
        self.code = self._ds(*arguments)
        after = report.load_last(self.state_root, "apply")
        if after is not None and (before is None or after.get("run") != before.get("run")):
            self.apply_report = after
        self.run.step("apply", self.code)

    def document(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "command": self.command,
            "component": self.name,
            "change": self.change,
            "ask": self.ask,
            "notes": self.notes,
            "apply": self.apply_report,
            "exit_code": self.code,
        }

    def finish(self) -> int:
        for note in self.notes:
            _say(self.command, note)
        for question in self.ask:
            said = [str(question[key]) for key in ("message", "run") if question.get(key)]
            _say(self.command, f"{question.get('code')}: " + " -> ".join(said))
        self.run.data.update(change=self.change, exit_code=self.code)
        paths = self.run.write()
        if paths.review is not None:
            _say(self.command, f"see {paths.review}")
        return self.code


# --- add --------------------------------------------------------------------------------------


class Add(_Transaction):
    command = "add"

    def default_subject(self) -> str:
        return f"feat: track {self.name}"

    def __init__(self, instance: config.Instance, state_root: str, options: argparse.Namespace) -> None:
        super().__init__(instance, state_root, options)
        self.keys = self._keys()
        self.apt = _list(options.apt, "--apt", _APT_PACKAGE)
        self.commands = _list(options.command, "--command", _COMMAND) or []
        self.nix: str | None = options.nix
        if self.nix is not None and (not _NIX_ATTRIBUTE.fullmatch(self.nix) or set(self.nix.split(".")) & NIX_KEYWORDS):
            raise UsageError(f"--nix: {self.nix!r} is not a nixpkgs attribute path (or a part is a Nix keyword)")
        if self.apt is not None and self.nix is not None:
            raise UsageError("one channel at a time: --apt or --nix")
        self.catalog = self.name in config.framework_catalog()
        if self.catalog and (self.apt is not None or self.nix is not None):
            raise UsageError(f"{self.name} is a catalog component: add it without --apt or --nix")
        self.definition = self.root / "components" / self.name / "default.nix"
        self.scaffold = self._scaffold()
        self.channel = (
            "catalog"
            if self.catalog
            else "apt"
            if self.apt is not None
            else "nix"
            if self.nix is not None
            else "instance"
        )
        self.run.data.update(channel=self.channel)
        self.entry = self._manifest_entry()
        method = self.keys.get("method")
        supported = ((self.entry or {}).get("supported_methods") or {}).get(config.runtime_platform(self.env)) or []
        if method and supported and method not in supported:
            raise UsageError(f"--method: {self.name} supports {', '.join(supported)} here, not {method}")
        self.dropped: dict[str, list[str]] = {}
        self.here: bool | None = None
        self.reason: str | None = None
        # A usage error comes before anything runs.
        self._add_text()

    def _manifest_entry(self) -> dict[str, Any] | None:
        for entry in layout.manifest(self.instance).get("components") or ():
            if isinstance(entry, dict) and entry.get("name") == self.name:
                return entry
        return None

    def _keys(self) -> dict[str, Any]:
        options = self.options
        keys: dict[str, Any] = {}
        if options.method:
            keys["method"] = options.method
        profiles = _list(options.profiles, "--profiles")
        if profiles is not None:
            keys["profiles"] = profiles
        if sum(bool(given) for given in (options.here, options.also_here, options.machines)) > 1:
            raise UsageError("one of --here, --also-here and --machines")
        self.this = machine.current_name(machine.read_machine(self.state_root), self.env)
        if (options.here or options.also_here) and self.this is None:
            raise UsageError("--here: this machine has no name yet; 'dotsteward host init' names it")
        if options.here:
            keys["machines"] = [self.this]
        machines = _list(options.machines, "--machines")
        if machines is not None:
            keys["machines"] = machines
        for name in keys.get("machines") or ():
            if not machine.host_path(self.root, name).is_file():
                raise UsageError(
                    f"--machines: {name} has no host file (hosts/{name}.toml): a machine joins with "
                    "'dotsteward host init' on it"
                )
        tags = _list(options.tags, "--tags")
        if tags is not None:
            keys["tags"] = tags
        if options.updater:
            keys["updater"] = options.updater
        return keys

    def _add_text(self) -> str:
        """The text with the table of the component as add wants it; sets self.change."""
        current = tomlfile.loads(_read(self.instance.file))
        table = dict((current.get("components") or {}).get(self.name) or {})
        if self.options.also_here and isinstance(table.get("machines"), list) and self.this not in table["machines"]:
            self.keys["machines"] = [*table["machines"], self.this]
        self.dropped = {
            key: [value for value in table[key] if value not in self.keys[key]]
            for key in ("machines", "tags", "profiles")
            if isinstance(table.get(key), list)
            and key in self.keys
            and any(value not in self.keys[key] for value in table[key])
        }
        wanted = {**table, "enable": True, **self.keys}
        expected = _normal(current)
        expected.setdefault("components", {})[self.name] = _normal(wanted)
        if not table:
            self.change = "added"
            values = {"enable": True, **self.keys}
            return self._edited(self._add, lambda text: _place_table(text, self.name, values), expected)
        self.change = "enabled" if table.get("enable") is not True else "unchanged"
        moved = {key: value for key, value in self.keys.items() if table.get(key) != value}
        if self.change == "unchanged" and moved:
            self.change = "changed"
        if self.change == "unchanged":
            return _read(self.instance.file)

        def by_lines(text: str) -> str | None:
            return _set_keys(text, self.name, {"enable": True, **moved})

        return self._edited(self._add, by_lines, expected)

    def _add(self, document: Any) -> None:
        tomlkit = _tomlkit()
        components = document.get("components")
        if components is None:
            components = tomlkit.table(True)
            document["components"] = components
        table = components.get(self.name)
        if table is None:
            table = tomlkit.table()
            table["enable"] = True
            for key, value in self.keys.items():
                table[key] = value
            components[self.name] = table
            self.change = "added"
            return
        self.change = "unchanged"
        if _plain(table.get("enable")) is not True:
            table["enable"] = True
            self.change = "enabled"
        for key, value in self.keys.items():
            if _plain(table.get(key)) != value:
                table[key] = value
                if self.change == "unchanged":
                    self.change = "changed"

    def _scaffold(self) -> str | None:
        """The text of components/NAME/default.nix for a channel outside the catalog, None without one."""
        if self.apt is None and self.nix is None:
            return None
        checks = (
            f"    checks.commands = [ {' '.join(json.dumps(command) for command in self.commands)} ];\n"
            if self.commands
            else ""
        )
        if self.apt is not None:
            listed = " ".join(json.dumps(package) for package in self.apt)
            about = (
                f"{self.name}: the APT packages {', '.join(self.apt)} from the sources of the machine, updated with "
                "plain apt upgrade. Written by dotsteward add; the instance owns it from here."
            )
            return (
                _comment(about) + "{ lib, ... }:\n"
                "{\n"
                f"  dotsteward.components.{self.name} = {{\n"
                '    platforms = [ "linux" ];\n'
                '    method = lib.mkDefault "deb";\n'
                '    supportedMethods.linux = [ "deb" ];\n'
                "    install.deb = {\n"
                "      pin = null;\n"
                f"      apt = [ {listed} ];\n"
                "    };\n"
                f"{checks}"
                "  };\n"
                "}\n"
            )
        about = (
            f"{self.name}: the nixpkgs package {self.nix}, in the Home Manager profile. Written by dotsteward add; "
            "the instance owns it from here."
        )
        return (
            _comment(about) + "{ lib, pkgs, ... }:\n"
            "{\n"
            f"  dotsteward.components.{self.name} = {{\n"
            '    method = lib.mkDefault "nix";\n'
            "    supportedMethods = {\n"
            '      linux = [ "nix" ];\n'
            '      darwin = [ "nix" ];\n'
            "    };\n"
            f"    install.nix.packages = [ pkgs.{self.nix} ];\n"
            f"{checks}"
            "  };\n"
            "}\n"
        )

    def _channel_known(self) -> bool:
        """Whether the channel of NAME is clear; refuses one that cannot work."""
        if self.catalog:
            return True
        current = self.definition.read_text(encoding="utf-8") if self.definition.is_file() else None
        if self.scaffold is None:
            return current is not None
        if current is not None and current != self.scaffold and self._own_scaffold(current):
            # What an add that went red wrote and no commit holds: the next add writes its own.
            current = None
            self.replace_scaffold = True
        if current is not None and current != self.scaffold:
            raise Refusal(
                f"components/{self.name}/default.nix is there already and is not what --{self.channel} writes: "
                f"change that file by the maintain skill and run dotsteward add {self.name}"
            )
        if self.apt is not None:
            if self._for_this_machine():
                self._check_apt(self.apt)
            else:
                _say(self.command, f"{', '.join(self.apt)}: not checked on this machine, which the scope leaves out")
        return True

    def _own_scaffold(self, text: str) -> bool:
        relative = str(self.definition.relative_to(self.root))
        committed = self._git("ls-tree", "--name-only", "HEAD", "--", relative).stdout.strip()
        return not committed and text.startswith(f"# {self.name}: the ") and "Written by dotsteward" in text

    def _for_this_machine(self) -> bool:
        machines = self.keys.get("machines")
        if machines is not None and self.this not in machines:
            return False
        tags = self.keys.get("tags")
        if tags is not None:
            host = (machine.read_host(self.root, self.this) if self.this else None) or {}
            return bool(set(tags) & set(host.get("tags") or []))
        return True

    def _take_back_never(self) -> bool:
        """This machine's answer Never for the component goes: the owner asked to track it."""
        if self.this is None:
            return False
        from dotsteward_cli import incoming

        took = incoming.take_back_never(self.state_root, "components", self.name)
        path = machine.host_path(self.root, self.this)
        if path.is_file():
            tomlkit = _tomlkit()
            text = _read(path)
            document = tomlkit.parse(text)
            names = (document.get("declined") or {}).get("components")
            if names is not None and self.name in [_plain(item) for item in names]:
                for index in reversed(range(len(names))):
                    if _plain(names[index]) == self.name:
                        del names[index]
                atomic.atomic_write(path, tomlkit.dumps(document))
                took = True
        if took:
            _say(self.command, f"this machine answered Never for {self.name}: add takes back the answer Never")
        return took

    def _scope_here(self) -> None:
        """Whether the component applies on this machine now, and why not."""
        try:
            instance = config.load_instance(str(self.root))
            scope = machine.effective(instance, self.env)
        except config.DotstewardError:
            return
        reason = scope["reasons"].get(f"component:{self.name}")
        table = (instance.config.get("components") or {}).get(self.name) or {}
        profiles = table.get("profiles")
        if reason is None and isinstance(profiles, list) and scope["profile"] and scope["profile"] not in profiles:
            reason = "profile"
        entry = self._manifest_entry()
        if reason is None and entry and entry.get("unavailable"):
            reason = machine.REASON_PLATFORM
        self.here = reason in (None, machine.REASON_NOT_ACTIVATED, machine.REASON_INCOMING)
        self.reason = None if self.here else reason
        if self.here:
            return
        why = {
            machine.REASON_MACHINES: (
                f"{self.name} does not apply on this machine (machines: {', '.join(table.get('machines') or [])}): "
                f"dotsteward add {self.name} --also-here adds this machine"
            ),
            machine.REASON_TAGS: (
                f"{self.name} does not apply on this machine (tags: {', '.join(table.get('tags') or [])}, this "
                f"machine has {', '.join(scope['tags']) or 'none'})"
            ),
            machine.REASON_PLATFORM: (
                f"{self.name} is not available on this platform ({platforms.platform_id(self.env)})"
            ),
            machine.REASON_DECLINED: f"{self.name} does not apply on this machine: it answered Never",
            "profile": f"{self.name} does not apply on this machine (profiles: {', '.join(profiles or [])})",
        }.get(str(reason), f"{self.name} does not apply on this machine ({reason})")
        _say(self.command, why)

    def _check_apt(self, packages: Sequence[str]) -> None:
        """Each package is installed or a source of this machine offers it; read from the local lists."""
        if shutil.which("apt-cache") is None:
            raise Refusal("--apt needs APT, and this machine has no apt-cache")
        done = subprocess.run(
            ["apt-cache", "policy", *packages],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
        known: dict[str, bool] = {}
        current = None
        for line in done.stdout.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                current = line[:-1]
                known[current] = False
            elif current is not None:
                key, _, value = line.strip().partition(": ")
                if key in {"Installed", "Candidate"} and value and value != "(none)":
                    known[current] = True
        missing = [package for package in packages if not known.get(package)]
        if missing:
            raise Refusal(
                f"no APT source of this machine offers {', '.join(missing)}, and it is not installed: a vendor "
                "repository needs its source in the component (install.deb.aptSources), which the maintain skill "
                "writes; then dotsteward add again"
            )

    def execute(self) -> int:
        if not self._channel_known():
            self.ask.append(
                {
                    "code": "channel-unknown",
                    "component": self.name,
                    "message": (
                        f"{self.name} is no catalog component and no component of this instance: plain APT packages "
                        f"take --apt PACKAGE, a nixpkgs package --nix ATTRIBUTE; anything else (an official binary, "
                        "a vendor repository, a release download) needs research by the dotsteward-maintain skill, "
                        f"which writes components/{self.name}/default.nix; then the same dotsteward add"
                    ),
                }
            )
            self.run.item("channel-unknown", component=self.name, message=self.ask[-1]["message"])
            self.code = report.PENDING
            return self.finish()
        if self._narrowed():
            return self.finish()
        base = self._begin()
        if base is None:
            return self.finish()
        text = self._add_text()
        if self._narrowed():
            return self.finish()
        wrote = self.change != "unchanged"
        if wrote:
            atomic.atomic_write(self.instance.file, text)
        if self.scaffold is not None and (not self.definition.is_file() or self.replace_scaffold):
            self.definition.parent.mkdir(parents=True, exist_ok=True)
            atomic.atomic_write(self.definition, self.scaffold, mode=0o644)
            wrote = True
        if self._take_back_never():
            wrote = True
        self.run.step("intent", report.OK, detail=self.change)
        if not wrote and not self._pending_since(base):
            _say(self.command, f"{self.name} is tracked already: nothing to do")
            self._scope_here()
            return self.finish()
        if not wrote:
            _say(
                self.command,
                f"{self.name} is in the intent already: dotsteward apply finishes what an earlier run left",
            )
        self._apply()
        self._scope_here()
        return self.finish()

    def _narrowed(self) -> bool:
        """A scope option that would drop values of a list the table has: a question."""
        if not self.dropped or self.options.replace_scope:
            return False
        said = "; ".join(f"{key}: {', '.join(values)}" for key, values in self.dropped.items())
        self.ask.append(
            {
                "code": "scope-narrowed",
                "component": self.name,
                "dropped": self.dropped,
                "message": (
                    f"this would drop {said} from the scope of {self.name}: --also-here adds this machine and keeps "
                    "the others, --replace-scope confirms the new scope"
                ),
            }
        )
        self._asked()
        return True

    def document(self) -> dict[str, Any]:
        return {
            **super().document(),
            "channel": self.channel,
            "here": self.here,
            "reason": self.reason,
            "with_changes": self.taken,
        }


# --- remove -----------------------------------------------------------------------------------


class Remove(_Transaction):
    command = "remove"

    def default_subject(self) -> str:
        if self.options.keep_here:
            this = machine.current_name(machine.read_machine(self.state_root), self.env)
            return f"feat: keep {self.name} on {this} only"
        return f"feat: stop tracking {self.name}"

    def __init__(self, instance: config.Instance, state_root: str, options: argparse.Namespace) -> None:
        super().__init__(instance, state_root, options)
        self.uninstall_result: dict[str, Any] | None = None
        self.kept_comments: list[str] = []
        self.plan_file = Path(state_root) / _UNINSTALL_DIRECTORY / f"uninstall-{self.name}.json"
        self.entry: dict[str, Any] | None = None
        self.base = ""
        if options.keep_here and options.uninstall:
            raise UsageError("--keep-here or --uninstall, not both")

    def _manifest_entry(self, name: str) -> dict[str, Any] | None:
        for entry in layout.manifest(self.instance).get("components") or ():
            if isinstance(entry, dict) and entry.get("name") == name:
                return entry
        return None

    def _remove_text(self) -> str:
        """The text without the component; sets self.change and self.kept_comments."""
        text = _read(self.instance.file)
        current = tomlfile.loads(text)
        components = current.get("components") or {}
        if self.name not in components and self.name not in (components.get("order") or []):
            self.change = "unchanged"
            return text
        self.change = "removed"

        def by_lines(text: str) -> str | None:
            dropped, self.kept_comments = _drop_table(text, self.name)
            tomlkit = _tomlkit()
            document = tomlkit.parse(dropped)
            order = (document.get("components") or {}).get("order")
            if order is not None:
                for index in reversed(range(len(order))):
                    if _plain(order[index]) == self.name:
                        del order[index]
            result: str = tomlkit.dumps(document)
            return result

        new_text = self._edited(self._remove, by_lines, _without(current, self.name))
        if _normal(tomlfile.loads(new_text)) == _normal(current):
            self.change = "unchanged"
        return new_text

    def _remove(self, document: Any) -> None:
        components = document.get("components")
        self.change = "unchanged"
        if components is None:
            return
        if self.name in components:
            del components[self.name]
            self.change = "removed"
        order = components.get("order")
        if order is not None and self.name in [_plain(entry) for entry in order]:
            for index in reversed(range(len(order))):
                if _plain(order[index]) == self.name:
                    del order[index]
            self.change = "removed"

    def _dependents(self) -> list[str]:
        """The enabled components that require this one."""
        enabled = {name for name, _ in machine.enabled_components(self.instance)}
        found = []
        for entry in layout.manifest(self.instance).get("components") or ():
            if not isinstance(entry, dict) or entry.get("name") == self.name or entry.get("name") not in enabled:
                continue
            if self.name in (entry.get("requires") or ()):
                found.append(str(entry["name"]))
        return sorted(found)

    def _home(self) -> Path:
        return Path(os.environ.get("HOME") or os.path.expanduser("~")).resolve()

    def _at_home(self, value: Any) -> Path | None:
        """A home path of the manifest (~/...) as an absolute path strictly below HOME, else None."""
        if not isinstance(value, str) or not value.startswith("~/"):
            return None
        home = self._home()
        path = Path(os.path.normpath(home / value[2:]))
        if path == home or home not in path.parents:
            return None
        return path

    def _plan(self) -> dict[str, Any]:
        """What --uninstall may remove, worked out from the manifest before the component goes. Each
        path is checked again when it is removed."""
        entry = self.entry or {}
        method = entry.get("method")
        install = entry.get("install") or {}
        plan: dict[str, Any] = {"schema_version": SCHEMA_VERSION, "component": self.name, "method": method}
        if method == "deb":
            mine = [str(package) for package in [*(install.get("packageNames") or ()), *(install.get("apt") or ())]]
            others = self._packages_of_others()
            plan["packages"] = [package for package in dict.fromkeys(mine) if package not in others]
        elif method == "official-binary":
            plan["binary"] = install.get("dest")
            plan["probe"] = {"argv": install.get("versionArgv"), "regex": install.get("versionRegex")}
            plan["companions"] = [str(c.get("file")) for c in install.get("companions") or () if c.get("file")]
        elif method == "pypi":
            plan["venv"] = install.get("venv")
            plan["link_dir"] = install.get("linkDir") or "~/.local/bin"
            plan["bin"] = [str(script) for script in install.get("bin") or ()]
        return plan

    def _packages_of_others(self) -> set[str]:
        enabled = dict(machine.enabled_components(self.instance))
        found: set[str] = set()
        for entry in layout.manifest(self.instance).get("components") or ():
            name = entry.get("name") if isinstance(entry, dict) else None
            if name == self.name or name not in enabled:
                continue
            install = entry.get("install") or {}
            found |= {str(p) for p in [*(install.get("packageNames") or ()), *(install.get("apt") or ())]}
            found |= {str(p) for p in enabled[name].get("track") or ()}
        return found

    def _installed(self, packages: Sequence[str]) -> list[str]:
        if not packages or shutil.which("dpkg-query") is None:
            return []
        done = subprocess.run(
            ["dpkg-query", "-W", "-f", "${Package}\t${db:Status-Status}\n", *packages],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
        installed = {line.split("\t")[0] for line in done.stdout.splitlines() if line.endswith("\tinstalled")}
        return [package for package in packages if package in installed]

    def _summary(self) -> None:
        """What stays on this machine."""
        entry = self.entry or {}
        method = entry.get("method")
        if method == "nix":
            _say(
                self.command, f"{self.name} leaves the Home Manager profile at the next activation (dotsteward rebuild)"
            )
        elif self.options.uninstall:
            return
        elif method == "deb":
            plan = self._plan()
            packages = self._installed(plan.get("packages") or [])
            if packages:
                _say(
                    self.command,
                    f"{self.name} stays installed ({', '.join(packages)}): apt upgrade keeps it up to date",
                )
            else:
                _say(self.command, f"{self.name} stays installed")
        elif method:
            _say(self.command, f"{self.name} stays installed ({method}); dotsteward remove --uninstall removes it")

    # --- what --uninstall removes, each path proven the component's --------------------------------

    def _keep(self, result: dict[str, Any], path: Path | str, why: str) -> None:
        result["kept"].append({"path": str(path), "why": why})
        _say(self.command, f"{path} stays: {why}")

    def _answers_probe(self, binary: Path, probe: Mapping[str, Any]) -> bool:
        argv, regex = probe.get("argv"), probe.get("regex")
        if not isinstance(argv, list) or not isinstance(regex, str):
            return False
        try:
            done = subprocess.run(
                [str(binary), *(str(arg) for arg in argv)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return re.search(regex, done.stdout + done.stderr) is not None

    def _remove_files(self, plan: Mapping[str, Any], result: dict[str, Any]) -> None:
        method = plan.get("method")
        if method == "official-binary":
            binary = self._at_home(plan.get("binary"))
            if binary is None:
                if plan.get("binary"):
                    self._keep(result, str(plan.get("binary")), "it is not a path below HOME")
                return
            if not binary.exists() and not binary.is_symlink():
                return
            if binary.is_symlink() or not binary.is_file():
                self._keep(result, binary, f"it is no file that {self.name} installed (a link or a directory)")
                return
            if not self._answers_probe(binary, plan.get("probe") or {}):
                self._keep(result, binary, f"it does not answer the version probe of {self.name}")
                return
            for path in [binary, *(binary.parent / name for name in plan.get("companions") or ())]:
                if path.is_file() and not path.is_symlink():
                    path.unlink()
                    result["removed"].append(str(path))
        elif method == "pypi":
            venv = self._at_home(plan.get("venv"))
            link_dir = self._at_home(plan.get("link_dir"))
            if venv is None:
                if plan.get("venv"):
                    self._keep(result, str(plan.get("venv")), "it is not a path below HOME")
                return
            for script in plan.get("bin") or ():
                link = link_dir / script if link_dir is not None else None
                if link is None or not (link.exists() or link.is_symlink()):
                    continue
                if link.is_symlink() and (venv.resolve() in link.resolve().parents):
                    link.unlink()
                    result["removed"].append(str(link))
                else:
                    self._keep(result, link, f"it is no link into the environment of {self.name}")
            if venv.is_dir() and not venv.is_symlink():
                if (venv / "pyvenv.cfg").is_file():
                    shutil.rmtree(venv)
                    result["removed"].append(str(venv))
                else:
                    self._keep(result, venv, "it holds no pyvenv.cfg: no environment of a Python application")

    def _removal_published(self) -> bool:
        """Whether the remote, as the last fetch saw it, no longer tracks the component."""
        if self.apply_report is not None:
            return bool((self.apply_report.get("data") or {}).get("published"))
        shown = self._git("show", f"refs/remotes/origin/{self.branch}:{config.CONFIG_FILE}")
        if shown.code != 0:
            return False
        try:
            remote = tomlfile.loads(shown.stdout)
        except tomlfile.TomlError:
            return False
        return self.name not in (remote.get("components") or {})

    def _uninstall(self) -> None:
        """Carries out the recorded plan, once the removal is published."""
        try:
            plan = json.loads(self.plan_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _say(
                self.command,
                f"nothing to uninstall: no plan of {self.name} is recorded here (it left the intent without "
                "--uninstall); remove its software by hand",
            )
            return
        if not self._removal_published():
            _say(
                self.command,
                f"the removal of {self.name} is not published yet: nothing is uninstalled; the same "
                "dotsteward remove --uninstall --publish does it",
            )
            self.uninstall_result = {"status": "waiting", "method": plan.get("method"), "removed": [], "kept": []}
            self.run.step("uninstall", report.OK, detail="waits for the publish")
            return
        result: dict[str, Any] = {"status": "done", "method": plan.get("method"), "removed": [], "kept": []}
        self._remove_files(plan, result)
        packages = self._installed(plan.get("packages") or [])
        if packages:
            command = ["sudo", "apt-get", "remove", *packages]
            result["run"] = " ".join(command)
            if self.terminal:
                status = self._attached(command)
                if status != 0:
                    result["status"] = "failed"
                    self.run.step("uninstall", report.FAILED, detail=f"{result['run']} exited {status}")
                    self.code = report.FAILED
                    self.uninstall_result = result
                    return
                result["removed"] += packages
            else:
                result["status"] = "pending"
                message = f"removing {', '.join(packages)} needs sudo: run the command in a terminal"
                self.ask.append({"code": "uninstall-required", "run": result["run"], "message": message})
                self.run.item("uninstall-required", run=result["run"], message=message)
                self.code = report.combine([self.code, report.PENDING])
                self.uninstall_result = result
                self.run.step("uninstall", report.PENDING, detail=result["run"])
                return
        self.plan_file.unlink(missing_ok=True)
        for path in result["removed"]:
            _say(self.command, f"removed {path}")
        self.uninstall_result = result
        self.run.step("uninstall", report.OK)

    # --- the tree ----------------------------------------------------------------------------------

    def _table_at(self, revision: str) -> Mapping[str, Any] | None:
        shown = self._git("show", f"{revision}:{config.CONFIG_FILE}")
        if shown.code != 0:
            return None
        try:
            table = (tomlfile.loads(shown.stdout).get("components") or {}).get(self.name)
        except tomlfile.TomlError:
            return None
        return table if isinstance(table, dict) else None

    def _work_table(self) -> Mapping[str, Any] | None:
        try:
            table = (tomlfile.loads(_read(self.instance.file)).get("components") or {}).get(self.name)
        except (OSError, tomlfile.TomlError):
            return None
        return table if isinstance(table, dict) else None

    def _directory(self) -> str:
        return f"components/{self.name}/"

    def _not_committed(self) -> list[str]:
        """The files under components/NAME that no commit holds and git does not ignore: someone's
        work, which the commit of remove would take along."""
        untracked = self._git("ls-files", "--others", "--exclude-standard", "--", self._directory()).stdout
        staged = self._git("diff", "--cached", "--name-only", "--diff-filter=A", "HEAD", "--", self._directory()).stdout
        return sorted({line for line in (untracked + staged).splitlines() if line})

    def _remove_directory(self) -> list[str]:
        """Deletes the committed files of components/NAME; what else is there stays, named."""
        committed = self._git("ls-tree", "-r", "--name-only", "HEAD", "--", self._directory()).stdout.splitlines()
        removed = []
        for name in committed:
            path = self.root / name
            if path.is_file() or path.is_symlink():
                path.unlink()
                removed.append(name)
        directory = self.root / self._directory()
        kept = (
            sorted(
                str(path.relative_to(self.root)) for path in directory.rglob("*") if path.is_file() or path.is_symlink()
            )
            if directory.is_dir()
            else []
        )
        for name in kept:
            _say(self.command, f"{name} stays: git does not know it (an ignored file)")
        if directory.is_dir():
            for folder in sorted((p for p in directory.rglob("*") if p.is_dir()), reverse=True):
                with contextlib.suppress(OSError):
                    folder.rmdir()
            with contextlib.suppress(OSError):
                directory.rmdir()
        return removed

    def _machines_of(self, table: Mapping[str, Any]) -> list[str]:
        """The machines the component is for, by the intent: its machines, else every known machine."""
        if isinstance(table.get("machines"), list):
            return sorted(str(name) for name in table["machines"])
        names = set(machine.known_names(self.root))
        this = machine.current_name(machine.read_machine(self.state_root), self.env)
        if this is not None:
            names.add(this)
        tags = table.get("tags")
        if isinstance(tags, list):
            names = {
                name for name in names if set(tags) & set((machine.read_host(self.root, name) or {}).get("tags") or [])
            }
        return sorted(names)

    def _host_text(self) -> tuple[Path, str] | None:
        """This machine's host file without what it says about the component: its answer Never
        and its holds. None when there is nothing to take out."""
        this = machine.current_name(machine.read_machine(self.state_root), self.env)
        if this is None:
            return None
        path = machine.host_path(self.root, this)
        if not path.is_file():
            return None
        tomlkit = _tomlkit()
        text = _read(path)
        document = tomlkit.parse(text)
        declined = document.get("declined")
        if declined is not None and self.name in [_plain(item) for item in declined.get("components", [])]:
            names = declined["components"]
            for index in reversed(range(len(names))):
                if _plain(names[index]) == self.name:
                    del names[index]
        held = document.get("holds")
        if held is not None and self.name in held:
            del held[self.name]
        new_text: str = tomlkit.dumps(document)
        return (path, new_text) if new_text != text else None

    def _pins(self) -> list[str]:
        install = (self.entry or {}).get("install") or {}
        pins = [install.get("pin"), *((c or {}).get("pin") for c in install.get("companions") or ())]
        return [str(pin) for pin in pins if isinstance(pin, str) and pin]

    def _keep_here(self, table: Mapping[str, Any]) -> int:
        this = machine.current_name(machine.read_machine(self.state_root), self.env)
        if this is None:
            raise UsageError("--keep-here: this machine has no name yet; 'dotsteward host init' names it")
        current = tomlfile.loads(_read(self.instance.file))
        expected = _normal(current)
        expected["components"][self.name] = {**_normal(table), "machines": [this]}
        if table.get("machines") == [this]:
            self.change = "unchanged"
            _say(self.command, f"{self.name} is kept on {this} only already")
            if not self._pending_since(self.base):
                return self.finish()
        else:
            self.change = "kept-here"

            def edit(document: Any) -> None:
                document["components"][self.name]["machines"] = [this]

            text = self._edited(edit, lambda text: _set_keys(text, self.name, {"machines": [this]}), expected)
            atomic.atomic_write(self.instance.file, text)
        self.run.step("intent", report.OK, detail=self.change)
        _say(self.command, f"{self.name} stays on {this} only: no other machine has it after its next rebuild")
        self._apply()
        return self.finish()

    def execute(self) -> int:
        base = self._begin()
        if base is None:
            return self.finish()
        self.base = base
        self.entry = self._manifest_entry(self.name)
        dependents = self._dependents()
        if dependents:
            raise Refusal(
                f"{', '.join(dependents)} requires {self.name}: remove {'it' if len(dependents) == 1 else 'them'} first"
            )
        committed = self._table_at(base) or self._table_at("HEAD")
        work = self._work_table()
        if committed is None:
            if work is not None:
                _say(
                    self.command,
                    f"workstation.toml has a table of {self.name} that no commit holds (an add that did not "
                    f"finish): dotsteward add {self.name} finishes it",
                )
            _say(self.command, f"{self.name} is not tracked: nothing to do")
            if self.options.uninstall:
                self._uninstall()
            return self.finish()
        table = work if work is not None else committed
        if self.options.keep_here:
            if work is None:
                raise Refusal(f"--keep-here: {self.name} is out of the intent already")
            return self._keep_here(table)
        method = (self.entry or {}).get("method")
        if work is not None and method == "nix" and not self.options.uninstall:
            machines = self._machines_of(table)
            self.ask.append(
                {
                    "code": "profile-removal",
                    "component": self.name,
                    "machines": machines,
                    "message": (
                        f"{self.name} is a nix component: without its table it leaves the Home Manager profile of "
                        f"every machine it is for at their next rebuild ({', '.join(machines) or 'every machine'}); "
                        f"--uninstall confirms that, --keep-here keeps it on this machine only"
                    ),
                }
            )
            self._asked()
            return self.finish()
        unknown = self._not_committed()
        if unknown:
            self.ask.append(
                {
                    "code": "untracked-files",
                    "paths": unknown,
                    "message": (
                        f"components/{self.name} holds files no commit has: move them out, or commit them first, "
                        "then the same dotsteward remove; nothing was written"
                    ),
                }
            )
            self._asked()
            return self.finish()
        text = self._remove_text()
        wrote = self.change == "removed"
        if wrote and self.options.uninstall:
            atomic.make_private_dirs(self.plan_file.parent)
            atomic.atomic_write(self.plan_file, json.dumps(self._plan(), indent=2, sort_keys=True) + "\n")
        if wrote:
            atomic.atomic_write(self.instance.file, text)
            for comment in self.kept_comments:
                first = comment.splitlines()[0]
                _say(self.command, f"the comment above [components.{self.name}] stays, it may be about more: {first}")
        if self._remove_directory():
            wrote = True
            self.change = "removed"
        host = self._host_text()
        if host is not None:
            atomic.atomic_write(host[0], host[1])
            _say(self.command, f"this machine's answer and holds about {self.name} leave {host[0].name}")
            wrote = True
        pins = self._pins()
        if pins and wrote:
            _say(self.command, f"the pins {', '.join(pins)} stay in versions.lock.json: only the producer moves pins")
        self.run.step("intent", report.OK, detail=self.change)
        if not wrote and not self._pending_since(base):
            _say(self.command, f"{self.name} is not tracked: nothing to do")
        else:
            if not wrote:
                _say(
                    self.command,
                    f"{self.name} is out of the intent already: dotsteward apply finishes what an earlier run left",
                )
            self._summary()
            self._apply()
        if self.code == report.OK:
            kept = [hold for hold in holds.read(self.state_root) if hold.get("component") != self.name]
            if len(kept) != len(holds.read(self.state_root)):
                holds.write(self.state_root, kept)
        if self.code == report.OK and self.options.uninstall:
            self._uninstall()
        elif self.code == report.OK and self.plan_file.exists() and not self.options.uninstall:
            self.plan_file.unlink()
        return self.finish()

    @property
    def terminal(self) -> bool:
        return sys.stdin.isatty() and sys.stdout.isatty()

    def document(self) -> dict[str, Any]:
        return {**super().document(), "uninstall": self.uninstall_result}


# --- the command lines ------------------------------------------------------------------------


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("name", metavar="NAME", help="the component")
    parser.add_argument("-m", "--message", dest="subject", metavar="SUBJECT", help="the conventional commit subject")
    activate = parser.add_mutually_exclusive_group()
    activate.add_argument("--activate", dest="activate", action="store_true", default=None, help="activate here")
    activate.add_argument("--no-activate", dest="activate", action="store_false", help="do not activate")
    publish = parser.add_mutually_exclusive_group()
    publish.add_argument("--publish", dest="publish", action="store_true", default=None, help="publish the commit")
    publish.add_argument("--no-publish", dest="publish", action="store_false", help="keep the commit here")
    parser.add_argument("--profile", help="the profile to activate (default: this machine's)")
    parser.add_argument(
        "--with-changes",
        action="store_true",
        help="the other changes of the checkout belong to this transaction (the user said so)",
    )
    parser.add_argument("--json", action="store_true", help="print one JSON document on standard output")


def _add_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward add", description=_ADD_DESCRIPTION)
    _common(parser)
    parser.add_argument("--apt", action="append", metavar="PACKAGE", help="plain APT packages (repeatable)")
    parser.add_argument("--nix", metavar="ATTRIBUTE", help="a nixpkgs package")
    parser.add_argument("--command", action="append", metavar="COMMAND", help="a command it provides (repeatable)")
    parser.add_argument("--method", help="the install method, of those the component supports")
    parser.add_argument("--profiles", action="append", metavar="PROFILE", help="only these profiles")
    parser.add_argument("--machines", action="append", metavar="MACHINE", help="only these machines")
    parser.add_argument("--here", action="store_true", help="only this machine")
    parser.add_argument("--also-here", action="store_true", help="this machine too, besides the machines it has")
    parser.add_argument(
        "--replace-scope", action="store_true", help="the scope options replace what the table has (confirmed)"
    )
    parser.add_argument("--tags", action="append", metavar="TAG", help="only machines with one of these tags")
    parser.add_argument("--updater", help="the one thing that updates it")
    return parser


def _remove_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward remove", description=_REMOVE_DESCRIPTION)
    _common(parser)
    parser.add_argument(
        "--uninstall", action="store_true", help="also remove what it installed outside the profile (asked for)"
    )
    parser.add_argument(
        "--keep-here", action="store_true", help="keep it on this machine only instead: machines = [this machine]"
    )
    return parser


def _print_document(document_out: int | None, document: Mapping[str, Any]) -> None:
    if document_out is None:
        return
    with os.fdopen(document_out, "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments[:1] not in (["add"], ["remove"]):
        _error("usage: python -m dotsteward_cli.track add|remove ARG...")
        return EXIT_USAGE
    command, rest = arguments[0], arguments[1:]
    options = (_add_parser() if command == "add" else _remove_parser()).parse_args(rest)
    if not config.nix_match("[a-z][a-z0-9-]*", options.name) or options.name in NIX_KEYWORDS:
        _error(f"{options.name!r} is not a component name (lower-case letters, digits and dashes)")
        return EXIT_USAGE
    if options.subject is not None and ("\n" in options.subject or not _SUBJECT.fullmatch(options.subject)):
        _error(f"the subject is not a conventional commit of one line: {options.subject}")
        return EXIT_USAGE
    # With --json everything else goes to standard error, of this process and its children.
    document_out = None
    if options.json:
        document_out = os.dup(1)
        os.dup2(2, 1)
    try:
        instance, state_root = config.load_instance(), config.required_state_root()
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    kind: type[_Transaction] = Add if command == "add" else Remove
    run: _Transaction | None = None
    try:
        with locks.instance_lock(command, state_root=state_root):
            run = kind(instance, state_root, options)
            code = run.execute()
    except UsageError as error:
        _error(str(error))
        return EXIT_USAGE
    except Refusal as error:
        _error(str(error))
        code = report.FAILED
        if run is not None:
            run.code = code
    except locks.LockBusy as busy:
        _error(str(busy))
        return report.FAILED
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return report.FAILED
    except KeyboardInterrupt:
        return 130
    if run is not None:
        _print_document(document_out, run.document())
    return code


if __name__ == "__main__":
    sys.exit(main())
