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
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic, config, context, locks, machine, report, runner
from dotsteward_cli.skills import layout

EXIT_USAGE = 2
SCHEMA_VERSION = 1
_SUBJECT = re.compile(r"^(" + "|".join(context.CONVENTIONAL_TYPES) + r")(\([a-z0-9._/-]+\))?!?: .+")
_APT_PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]+")
_NIX_ATTRIBUTE = re.compile(r"[A-Za-z_][A-Za-z0-9_'-]*(\.[A-Za-z_][A-Za-z0-9_'-]*)*")
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
    "dotsteward apply, under the subject 'feat: stop tracking NAME'. The software stays installed; what the Home "
    "Manager profile installed (the nix method) leaves it at the next activation. --uninstall also removes, once "
    "the commit landed, what the component installed outside the profile and no other component names: its APT "
    "packages (through sudo on a terminal, else uninstall-required with the command, exit 3) and an official "
    "binary or a Python environment of the home directory. A component that another one requires stays. Exit "
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
            else:
                self.ask.append(question)
        if self.ask:
            for question in self.ask:
                self.run.item(str(question.get("code")), **{k: v for k, v in question.items() if k != "code"})
            self.code = report.PENDING
            return None
        return base

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
            foreign.append(path)
        return foreign

    def _same_intent_but_this(self, base: str) -> bool:
        before = self._git("show", f"{base}:{config.CONFIG_FILE}")
        try:
            old = tomllib.loads(before.stdout) if before.code == 0 else {}
            new = tomllib.loads(self.instance.file.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            return False
        return _without(old, self.name) == _without(new, self.name)

    def _pending_since(self, base: str) -> bool:
        """Whether anything waits between BASE and the work tree: a change or a commit."""
        if self._git("rev-list", "--count", f"{base}..HEAD").stdout.strip() not in {"", "0"}:
            return True
        return not self._checkout_clean()

    def _edit_workstation(self, edit: Callable[[Any], None]) -> str:
        """The text of workstation.toml after EDIT, which gets the tomlkit document. Valid or UsageError."""
        tomlkit = _tomlkit()
        text = self.instance.file.read_text(encoding="utf-8")
        document = tomlkit.parse(text)
        edit(document)
        new_text: str = tomlkit.dumps(document)
        problems = config.errors(tomllib.loads(new_text))
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
        if self.nix is not None and not _NIX_ATTRIBUTE.fullmatch(self.nix):
            raise UsageError(f"--nix: {self.nix!r} is not a nixpkgs attribute path")
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
        # A usage error comes before anything runs.
        self._edit_workstation(self._add)

    def _keys(self) -> dict[str, Any]:
        options = self.options
        keys: dict[str, Any] = {}
        if options.method:
            keys["method"] = options.method
        profiles = _list(options.profiles, "--profiles")
        if profiles is not None:
            keys["profiles"] = profiles
        if options.here and options.machines:
            raise UsageError("--here or --machines, not both")
        if options.here:
            name = machine.current_name(machine.read_machine(self.state_root), self.env)
            if name is None:
                raise UsageError("--here: this machine has no name yet; 'dotsteward host init' names it")
            keys["machines"] = [name]
        machines = _list(options.machines, "--machines")
        if machines is not None:
            keys["machines"] = machines
        tags = _list(options.tags, "--tags")
        if tags is not None:
            keys["tags"] = tags
        if options.updater:
            keys["updater"] = options.updater
        return keys

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
            return (
                f"# {self.name}: the APT packages {', '.join(self.apt)} from the sources of the machine, updated with\n"
                "# plain apt upgrade. Written by dotsteward add; the instance owns it from here.\n"
                "{ lib, ... }:\n"
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
        return (
            f"# {self.name}: the nixpkgs package {self.nix}, in the Home Manager profile. Written by dotsteward\n"
            "# add; the instance owns it from here.\n"
            "{ lib, pkgs, ... }:\n"
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
        if current is not None and current != self.scaffold:
            raise Refusal(
                f"components/{self.name}/default.nix is there already and is not what --{self.channel} writes: "
                f"change that file by the maintain skill and run dotsteward add {self.name}"
            )
        if self.apt is not None:
            self._check_apt(self.apt)
        return True

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
        base = self._begin()
        if base is None:
            return self.finish()
        text = self._edit_workstation(self._add)
        wrote = self.change != "unchanged"
        if wrote:
            atomic.atomic_write(self.instance.file, text)
        if self.scaffold is not None and not self.definition.is_file():
            self.definition.parent.mkdir(parents=True, exist_ok=True)
            atomic.atomic_write(self.definition, self.scaffold, mode=0o644)
            wrote = True
        self.run.step("intent", report.OK, detail=self.change)
        if not wrote and not self._pending_since(base):
            _say(self.command, f"{self.name} is tracked already: nothing to do")
            return self.finish()
        if not wrote:
            _say(
                self.command,
                f"{self.name} is in the intent already: dotsteward apply finishes what an earlier run left",
            )
        self._apply()
        return self.finish()

    def document(self) -> dict[str, Any]:
        return {**super().document(), "channel": self.channel}


# --- remove -----------------------------------------------------------------------------------


class Remove(_Transaction):
    command = "remove"

    def default_subject(self) -> str:
        return f"feat: stop tracking {self.name}"

    def __init__(self, instance: config.Instance, state_root: str, options: argparse.Namespace) -> None:
        super().__init__(instance, state_root, options)
        self.uninstall_result: dict[str, Any] | None = None
        self.plan_file = Path(state_root) / _UNINSTALL_DIRECTORY / f"uninstall-{self.name}.json"
        self.entry = self._manifest_entry(self.name)

    def _manifest_entry(self, name: str) -> dict[str, Any] | None:
        for entry in layout.manifest(self.instance).get("components") or ():
            if isinstance(entry, dict) and entry.get("name") == name:
                return entry
        return None

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

    def _plan(self) -> dict[str, Any]:
        """What --uninstall removes, worked out from the manifest before the component goes."""
        entry = self.entry or {}
        method = entry.get("method")
        install = entry.get("install") or {}
        home = Path(os.environ.get("HOME") or os.path.expanduser("~"))

        def at_home(value: Any) -> Path | None:
            if not isinstance(value, str) or not value.startswith("~/"):
                return None
            return home / value[2:]

        plan: dict[str, Any] = {"schema_version": SCHEMA_VERSION, "component": self.name, "method": method}
        if method == "deb":
            mine = [str(package) for package in [*(install.get("packageNames") or ()), *(install.get("apt") or ())]]
            others = self._packages_of_others()
            plan["packages"] = [package for package in dict.fromkeys(mine) if package not in others]
        elif method == "official-binary":
            dest = at_home(install.get("dest"))
            files = [] if dest is None else [dest]
            if dest is not None:
                files += [dest.parent / str(c.get("file")) for c in install.get("companions") or () if c.get("file")]
            plan["files"] = [str(path) for path in files]
        elif method == "pypi":
            venv = at_home(install.get("venv"))
            link_dir = at_home(install.get("linkDir") or "~/.local/bin")
            links = [link_dir / str(script) for script in install.get("bin") or ()] if link_dir else []
            plan["files"] = [str(path) for path in links]
            plan["directories"] = [] if venv is None else [str(venv)]
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

    def _uninstall(self) -> None:
        """Carries out the recorded plan, once the removal landed."""
        try:
            plan = json.loads(self.plan_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        result: dict[str, Any] = {"status": "done", "method": plan.get("method"), "removed": []}
        for path in [*(plan.get("files") or ()), *(plan.get("directories") or ())]:
            target = Path(path)
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
                result["removed"].append(path)
            elif target.exists() or target.is_symlink():
                target.unlink()
                result["removed"].append(path)
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

    def execute(self) -> int:
        dependents = self._dependents()
        if dependents:
            raise Refusal(
                f"{', '.join(dependents)} requires {self.name}: remove {'it' if len(dependents) == 1 else 'them'} first"
            )
        base = self._begin()
        if base is None:
            return self.finish()
        text = self._edit_workstation(self._remove)
        definition = self.root / "components" / self.name
        wrote = self.change == "removed"
        if wrote and self.options.uninstall:
            atomic.make_private_dirs(self.plan_file.parent)
            atomic.atomic_write(self.plan_file, json.dumps(self._plan(), indent=2, sort_keys=True) + "\n")
        if wrote:
            atomic.atomic_write(self.instance.file, text)
        if definition.is_dir():
            shutil.rmtree(definition)
            wrote = True
            self.change = "removed"
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
    parser.add_argument("--tags", action="append", metavar="TAG", help="only machines with one of these tags")
    parser.add_argument("--updater", help="the one thing that updates it")
    return parser


def _remove_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward remove", description=_REMOVE_DESCRIPTION)
    _common(parser)
    parser.add_argument(
        "--uninstall", action="store_true", help="also remove what it installed outside the profile (asked for)"
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
    if not config.nix_match("[a-z][a-z0-9-]*", options.name):
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
