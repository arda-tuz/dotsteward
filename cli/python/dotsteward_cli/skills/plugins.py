"""The plugins of Claude Code that skill tracking knows about (design 4.7).

Two kinds, both under ``plugin:<name>`` keys of pending.json and base.json:

- **An own plugin**: a directory directly in ``~/.claude/skills`` with a
  ``.claude-plugin/plugin.json`` (what `claude plugin init` makes; Claude Code loads it as
  ``<name>@skills-dir``, from no marketplace); or, with the codex component, one directly in
  ``${CODEX_HOME:-~/.codex}/plugins`` with ``.codex-plugin/plugin.json`` or ``plugin.json``
  (where the Codex documentation puts a personal plugin; ``cache`` there is Codex's own),
  which another machine also gets into its personal marketplace and ``codex plugin add``.
  It is a skill as far as tracking goes: the copy lands in ``agent/plugins/<directory>``
  with an ``own_plugins`` entry of the lock (``{name, directory, agents, directory_sha256,
  machines?}``), and `agents install` puts it in the same place of another machine as a
  real directory.
- **A plugin of a marketplace**: a ``NAME@MARKETPLACE`` that Claude Code installed at user
  scope (``plugins/installed_plugins.json`` of ``${CLAUDE_CONFIG_DIR:-~/.claude}``), of a
  marketplace that ``plugins/known_marketplaces.json`` names with a GitHub source. It is
  downloaded, so it is a question: ``--all`` adds a
  ``[[components.claude-code.options.plugins]]`` table with the spec and the marketplace to
  ``workstation.toml``, ``--here`` with ``machines`` too, and ``--never`` lands in
  ``declined.plugins`` of the host file. The marketplace keeps the plugin up to date by
  itself (T7-b), so an update is never a change to capture, and an update of a plugin that
  is not tracked never tracks it.

What is no question: a plugin at project or local scope, one of a marketplace that is not a
GitHub one (nothing on another machine could add it), the plugins Claude Code brings itself,
one the instance tracks already, one this machine declined, and anything at all while the
instance does not manage Claude Code. A question also goes when the checkout says it was
answered, here or on another machine. The look reads files only and starts no process; it
reads them again only when one of them, or workstation.toml of the checkout, changed.
"""

from __future__ import annotations

import os
import re
from collections.abc import Callable, Mapping
from typing import Any

PLUGIN_MANIFEST = os.path.join(".claude-plugin", "plugin.json")
# A plugin of Codex: its manifest, or the plugin.json at the root of a portable plugin.
CODEX_MANIFESTS = (os.path.join(".codex-plugin", "plugin.json"), "plugin.json")
CODEX_AGENT = "codex"
CODEX_COMPONENT = "codex"
# Below the plugins of Codex, what Codex itself keeps: its installed copies.
CODEX_OWN_DIRS = frozenset({"cache"})
# Where the repository keeps own plugins; `static` checks the same place.
OWN_PLUGINS_DIR = "agent/plugins"
COMPONENT = "claude-code"
AGENT = "claude"
# Marketplaces of the agents themselves: what they bring needs no tracking.
BUILTIN_MARKETPLACES = frozenset(
    {"synced", "builtin", "skills-dir", "openai-bundled", "openai-primary-runtime", "openai-curated"}
)
_REPO = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
_SPEC = re.compile(r"([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)")
INSTALLED_FILE = os.path.join("plugins", "installed_plugins.json")
MARKETPLACES_FILE = os.path.join("plugins", "known_marketplaces.json")


def _home() -> str:
    return os.environ.get("HOME") or os.path.expanduser("~")


def claude_skills_dir() -> str:
    """Where Claude Code finds own plugins: ``~/.claude/skills``, the link root of skills."""
    return os.path.join(_home(), ".claude", "skills")


def claude_config_dir() -> str:
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(_home(), ".claude")


def codex_plugins_dir() -> str:
    """Where the Codex documentation puts a personal plugin: ``${CODEX_HOME:-~/.codex}/plugins``."""
    return os.path.join(os.environ.get("CODEX_HOME") or os.path.join(_home(), ".codex"), "plugins")


def manifest_of(path: str) -> str | None:
    """The plugin manifest of the directory PATH, when it is an own plugin of an agent: directly
    in ~/.claude/skills with .claude-plugin/plugin.json, or directly in the plugins of Codex
    with .codex-plugin/plugin.json or plugin.json (not the cache of Codex)."""
    normal_path = os.path.normpath(path)
    parent, name = os.path.split(normal_path)
    if parent == claude_skills_dir():
        candidates: tuple[str, ...] = (PLUGIN_MANIFEST,)
    elif parent == codex_plugins_dir() and name not in CODEX_OWN_DIRS and not name.startswith("."):
        candidates = CODEX_MANIFESTS
    else:
        return None
    for candidate in candidates:
        if os.path.isfile(os.path.join(normal_path, candidate)):
            return os.path.join(normal_path, candidate)
    return None


def agent_of(path: str) -> str | None:
    """The agent of the own plugin at PATH, None when it is none."""
    if manifest_of(path) is None:
        return None
    return AGENT if os.path.dirname(os.path.normpath(path)) == claude_skills_dir() else CODEX_AGENT


def is_own_plugin_dir(path: str) -> bool:
    return manifest_of(path) is not None


def plugin_root(agent: str) -> str:
    return codex_plugins_dir() if agent == CODEX_AGENT else claude_skills_dir()


def own_copy(name: str, agents: Any = None) -> str | None:
    """The local copy of the own plugin NAME in the roots of AGENTS (all of them without)."""
    wanted = [str(agent) for agent in agents] if isinstance(agents, list) and agents else [AGENT, CODEX_AGENT]
    for agent in wanted:
        candidate = os.path.join(plugin_root(agent), name)
        if is_own_plugin_dir(candidate):
            return candidate
    return None


def manifest_name(path: str) -> str | None:
    """The ``name`` of the plugin manifest of the directory PATH."""
    from dotsteward_cli.skills import state

    manifest = manifest_of(path)
    document = state.read_json(manifest, None) if manifest else None
    name = document.get("name") if isinstance(document, dict) else None
    return name.strip() if isinstance(name, str) and name.strip() else None


def is_spec(name: str) -> bool:
    return _SPEC.fullmatch(name) is not None


# --- the files of Claude Code ------------------------------------------------------------


def _files() -> tuple[str, str]:
    root = claude_config_dir()
    return os.path.join(root, INSTALLED_FILE), os.path.join(root, MARKETPLACES_FILE)


def files_stamp(instance: str) -> list[float | None]:
    """The times of the two files and of workstation.toml of the checkout INSTANCE, so a look
    reads them only after a change: an install, or an answer that a pull brought."""
    stamp: list[float | None] = []
    for path in (*_files(), os.path.join(instance, "workstation.toml")):
        try:
            stamp.append(os.stat(path).st_mtime_ns / 1e9)
        except OSError:
            stamp.append(None)
    return stamp


def installed_at_user_scope() -> dict[str, dict[str, Any]]:
    """Spec to install record of every plugin installed at user scope."""
    from dotsteward_cli.skills import state

    document = state.read_json(_files()[0], None)
    plugins = document.get("plugins") if isinstance(document, dict) else None
    found: dict[str, dict[str, Any]] = {}
    for spec, records in plugins.items() if isinstance(plugins, dict) else ():
        if not isinstance(spec, str) or not is_spec(spec) or not isinstance(records, list):
            continue
        for record in records:
            if isinstance(record, dict) and record.get("scope") == "user":
                found[spec] = record
                break
    return found


def github_marketplaces() -> dict[str, str]:
    """Name to OWNER/REPO of every marketplace with a GitHub source."""
    from dotsteward_cli.skills import state

    document = state.read_json(_files()[1], None)
    found: dict[str, str] = {}
    for name, entry in document.items() if isinstance(document, dict) else ():
        source = entry.get("source") if isinstance(entry, dict) else None
        repo = source.get("repo") if isinstance(source, dict) and source.get("source") == "github" else None
        if isinstance(repo, str) and _REPO.fullmatch(repo):
            found[str(name)] = repo
    return found


def candidates() -> dict[str, dict[str, Any]]:
    """Spec to the source of every plugin of a GitHub marketplace at user scope."""
    markets = github_marketplaces()
    found = {}
    for spec, record in installed_at_user_scope().items():
        market = spec.rpartition("@")[2]
        if market in BUILTIN_MARKETPLACES or market not in markets:
            continue
        found[spec] = {
            "marketplace": market,
            "repo": markets[market],
            "version": record.get("version"),
            "revision": record.get("gitCommitSha"),
        }
    return found


# --- what the instance says --------------------------------------------------------------


def _component(config: Mapping[str, Any]) -> Mapping[str, Any] | None:
    components = config.get("components")
    table = components.get(COMPONENT) if isinstance(components, Mapping) else None
    return table if isinstance(table, Mapping) else None


def manages_claude(config: Mapping[str, Any]) -> bool:
    table = _component(config)
    return table is not None and table.get("enable") is True


def _tables(config: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    table = _component(config)
    options = table.get("options") if table is not None else None
    entries = options.get("plugins") if isinstance(options, Mapping) else None
    listed = entries if isinstance(entries, list) else []
    return [entry for entry in listed if isinstance(entry, Mapping) and isinstance(entry.get("spec"), str)]


def tracked_specs(config: Mapping[str, Any], machine: str | None = None) -> set[str]:
    """The specs of [[components.claude-code.options.plugins]] that MACHINE takes: a table with
    machines is for those machines only (all of them without MACHINE)."""
    found = set()
    for entry in _tables(config):
        machines = entry.get("machines")
        if machine is not None and isinstance(machines, list) and machine not in machines:
            continue
        found.add(str(entry["spec"]))
    return found


def table_of(config: Mapping[str, Any], spec: str) -> Mapping[str, Any] | None:
    return next((entry for entry in _tables(config) if entry["spec"] == spec), None)


def read_config(tree: str) -> dict[str, Any]:
    """The raw workstation.toml of TREE, empty when it cannot be read."""
    from dotsteward_cli import tomlfile

    try:
        return tomlfile.load(os.path.join(tree, "workstation.toml"))
    except (OSError, ValueError):
        return {}


def declined_of(document: Mapping[str, Any]) -> set[str]:
    """``declined.plugins`` of a host file."""
    declined = document.get("declined")
    names = declined.get("plugins") if isinstance(declined, Mapping) else None
    return {name for name in names if isinstance(name, str)} if isinstance(names, list) else set()


def declined_in(tree: str, machine: str | None) -> set[str]:
    if not machine:
        return set()
    from dotsteward_cli import tomlfile

    try:
        return declined_of(tomlfile.load(os.path.join(tree, "hosts", f"{machine}.toml")))
    except (OSError, ValueError):
        return set()


# --- the look ----------------------------------------------------------------------------


def look(
    context: Mapping[str, Any],
    document: Mapping[str, Any],
    base: Mapping[str, Any],
    machine: Callable[[], str | None],
    *,
    full: bool,
    now: float,
) -> tuple[dict[str, dict[str, Any]], list[str], list[float | None] | None, list[str]]:
    """What the plugins of marketplaces want changed: items of pending.json to set, keys to
    drop, the new stamp of the files (None: unchanged, nothing was read), and the records of
    base.json that no longer hold.

    A record says the remote tracks a spec since its commit. Once the checkout has that commit
    and its options.plugins no longer names the spec, somebody took the table out: the plugin
    is not tracked any more, and an installed one is a question again (reason untracked)."""
    instance = str(context["instance"])
    stamp = files_stamp(instance)
    if not full and document.get("plugin_files") == stamp:
        return {}, [], None, []
    items = document["items"]
    found = candidates() if stamp[0] is not None and stamp[1] is not None else {}
    set_items: dict[str, dict[str, Any]] = {}
    # A question that waits; an answer that waits for its capture stays.
    asking = {
        key: str(item.get("name"))
        for key, item in items.items()
        if isinstance(item, dict)
        and item.get("kind") == "plugin"
        and isinstance(item.get("source"), dict)
        and item["source"].get("marketplace")
        and item.get("state") == "ask"
    }
    # Uninstalled meanwhile: the question goes.
    drop = [key for key, spec in asking.items() if spec not in found]
    fresh = [spec for spec in found if f"plugin:{spec}" not in items and f"plugin:{spec}" not in base]
    recorded = {
        key.partition(":")[2]: str(record.get("base_commit") or "")
        for key, record in base.items()
        if key.startswith("plugin:")
        and isinstance(record, dict)
        and record.get("tracked") == "marketplace"
        and key.partition(":")[2] in found
        and key not in items
    }
    forget: list[str] = []
    if fresh or recorded or len(drop) < len(asking):
        config = read_config(instance)
        managed = manages_claude(config)
        here = machine()
        known = tracked_specs(config, here) | declined_in(instance, here) if managed else set()
        # Answered meanwhile, on another machine or by hand: the question goes too.
        drop += [key for key, spec in asking.items() if key not in drop and (not managed or spec in known)]
        for spec, commit in recorded.items() if managed else ():
            if spec not in known and _checkout_has(instance, commit):
                forget.append(f"plugin:{spec}")
                fresh.append(spec)
        for spec in fresh if managed else []:
            if spec not in known:
                set_items[f"plugin:{spec}"] = {
                    "kind": "plugin",
                    "name": spec,
                    "path": None,
                    "state": "ask",
                    "origin": "downloaded",
                    "source": found[spec],
                    "evidence": None,
                    "detected_at": now,
                    "last_asked": None,
                    "reason": "untracked" if f"plugin:{spec}" in forget else None,
                    "attempts": 0,
                }
    return set_items, drop, stamp, forget


def _checkout_has(instance: str, commit: str) -> bool:
    """Whether the checkout INSTANCE has COMMIT: what it says about the spec is then newer."""
    from dotsteward_cli.skills import threeway

    return bool(commit) and not threeway.is_behind(instance, commit)


# --- the answer --------------------------------------------------------------------------


def options_entry(config: Mapping[str, Any], spec: str, repo: str, machine: str | None) -> dict[str, Any]:
    """The table of options.plugins for SPEC. A marketplace has one autoUpdate for all of its
    plugins, so an entry of the same marketplace that turns it off is followed."""
    if not is_spec(spec) or not _REPO.fullmatch(repo):
        raise ValueError(f"not a plugin of a GitHub marketplace: {spec} ({repo})")
    market = spec.rpartition("@")[2]
    entry: dict[str, Any] = {"spec": spec, "marketplace": repo}
    table = _component(config)
    options = table.get("options") if table is not None else None
    for other in options.get("plugins", []) if isinstance(options, Mapping) else []:
        if not isinstance(other, Mapping) or str(other.get("spec", "")).rpartition("@")[2] != market:
            continue
        if isinstance(other.get("marketplace"), str):
            entry["marketplace"] = other["marketplace"]
        if other.get("autoUpdate") is False:
            entry["autoUpdate"] = False
    if machine is not None:
        entry["machines"] = [machine]
    return entry


def with_machines(text: str, spec: str, machines: list[str] | None) -> str:
    """TEXT of workstation.toml with the table of SPEC for MACHINES (every machine with
    None); every other key and comment stays."""
    import tomlkit

    document: Any = tomlkit.parse(text)
    for entry in document["components"][COMPONENT]["options"]["plugins"]:
        if entry.get("spec") == spec:
            if machines is None:
                entry.pop("machines", None)
            else:
                entry["machines"] = machines
    result: str = tomlkit.dumps(document)
    return result


def with_options_entry(text: str, entry: Mapping[str, Any]) -> str:
    """TEXT of workstation.toml with ENTRY at the end of
    [[components.claude-code.options.plugins]]; every other key and comment stays."""
    import tomlkit

    document = tomlkit.parse(text)
    components = document.setdefault("components", tomlkit.table(is_super_table=True))
    table = components.setdefault(COMPONENT, tomlkit.table())
    options = table.setdefault("options", tomlkit.table())
    plugins = options.get("plugins")
    if plugins is None:
        plugins = tomlkit.aot()
        options["plugins"] = plugins
    if isinstance(plugins, tomlkit.items.AoT):
        added = tomlkit.table()
        for key, value in entry.items():
            added[key] = value
        plugins.append(added)
    else:
        inline = tomlkit.inline_table()
        inline.update(entry)
        plugins.append(inline)
    result: str = tomlkit.dumps(document)
    return result
