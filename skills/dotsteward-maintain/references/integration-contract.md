# Integration contract

## Contents

1. Instance invariants
2. Component routing
3. Evidence and validation
4. Removal and replacement

## Instance invariants

- The instance checkout is the one whose `origin` equals `instance.remote` of `dotsteward context --json`; its branch is `instance.branch`.
- The fast-path platform is `platform.fast_path` of the context (from `[platform]` in `workstation.toml`). Machine-only adaptations live in `<state root>/host-overrides/` only, never in the repository.
- The framework is a pinned flake input (`dotsteward` in `flake.lock`). Its skills, CLI, engines and catalog components are read-only for this skill; framework changes go through `dotsteward-contribute`.
- Skill discovery: the canonical root is a physical `~/.agents/skills` directory with physical skills or per-skill links. Framework skills are linked from the active generation at `skills.hm_root`; instance skills come from the vendored directory and the skills lock. Agents that need their own skill root (for example Claude Code) get per-skill links created by `dotsteward agents install`.
- Byte-protected files are listed under `protected` in the context (sha256 per path in `[protected]`); the static check refuses any change to them. Extend another file instead.
- A profile in `adopt` mode does not install system-level packages or replace existing applications and their settings; the only managed part of an application's own settings file is the set of entries in the settings buffer (synchronized three-way; local changes win until this skill writes them to the repository). A profile in `fresh` mode also runs the system-install phase.
- No secrets or account state in Git, no force push, no background repository updater.

## Component routing

Model the request as an ordered transaction. Shared locks, components, tests and documentation must describe the final combined state, not intermediate steps.

- **Catalog component:** set `[components.<name>]` in `workstation.toml` (`enable`, `method` or `method_by_platform`, `profiles`, `options`). The catalog README (in the framework source, `modules/components/<name>/README.md`) lists its methods, options and settings targets; its lock paths come from its seed values and its update notes from `maintenance.md`.
- **Private component:** a Home Manager module at `components/<name>/default.nix` that sets `dotsteward.components.<name>` (`references/component-contract.md`), enabled with `[components.<name>] enable = true`. Use it for an application outside the catalog, for a preference the catalog component cannot express, and for anything that needs hooks, probes or E2E checks.
- **Nix package:** a portable command-line tool from the locked nixpkgs when its resolved version meets the contract (`install.nix.packages` of a component, or `home.packages` in `home.nix` for a plain package without checks); a custom build goes into `components/<name>/package.nix`, with its source pinned as a flake input or in `versions.lock.json`. List a plain nixpkgs package's lock key in `[pins] nixpkgs_versions` when its version is pinned.
- **Official binary or system package:** `official-binary` (user level, verified download, `at-least` or `exact` policy), `deb` (Ubuntu, one verified apt transaction, fresh mode only) or `app-archive` (macOS, fresh mode only). Pin the official immutable download (URL, size, SHA-256) in `versions.lock.json` at the component's `pin` path. Keep the vendor's official update channel and never downgrade a newer local installation.
- **Instance skill:** only `SKILL.md`, `agents/`, `references/`, `scripts/`, `assets/` and a license; the complete directory digest and provenance in the skills lock; every agent sees it without duplicate physical copies.
- **Application configuration:** documented portable settings only; exclude databases, credentials, sessions, recent files, histories, logs, caches and machine indexes. Apply idempotently and preserve unrelated user state. When the application also writes the file, never link or replace it: track the individual keys (or a whole user-authored file) in the settings buffer with `dotsteward settings track` or `track-file` (`local-maintained-files.md`). Files the application never writes may stay Home Manager links or `dotsteward.files` copies.

## Evidence and validation

Every integration needs: official source and license; locked version or revision with integrity data; platform, architecture and profile applicability; runtime dependencies and feature probes; deterministic and adaptive behaviour (fresh and adopt profiles); idempotent reinstall and `--check-only` behaviour; a static check plus a real smoke or E2E check; a secret scan and a dirty-tree review (both inside the gate); documentation and maintenance routing.

For GUI applications exercise launch, version and package integration without touching user accounts. For CLIs run a real isolated workflow. For skills validate the structure, the metadata, the install links, discovery in every enabled agent, and the content digests.

## Removal and replacement

Inventory every reference first (`git grep -n '<name>'`). Remove the component configuration, package declarations, flake inputs, lock entries, configuration files, checks, docs, allowlist entries, settings buffer entries (`dotsteward settings untrack`) and stale links. Preserve recoverable user state unless deletion was explicitly requested. Prove that the removed command or configuration no longer comes from the instance and that the replacement passes the same acceptance path. Validate additions and removals of a batch together; do not publish a partial subset unless the user narrows the scope after seeing the incompatibility evidence.
