# Framework map

Read this first, then only the files it points to for the components you change. Instance paths are relative to the instance root (`instance.path` of `dotsteward context --json`); framework paths are relative to the framework source.

## Contents

1. Where things are
2. Instance files
3. Facts from the context
4. Commands
5. New-file checklist
6. Removal checklist

## Where things are

- **Instance:** the user's repository. Everything this skill writes lives here.
- **Framework source:** the `dotsteward` flake input pinned in `flake.lock`, read-only. From the instance root its store path is:

  ```bash
  nix flake archive --json --dry-run | jq -r .inputs.dotsteward.path
  ```

  The framework skills of the active generation are links into the same source (`<source>/skills/<name>`), so this skill's own resolved directory is two levels below it.
- **Catalog component docs** (framework source): `modules/components/<name>/README.md` (what it installs per platform, methods, options, settings targets, verification status) and `modules/components/<name>/maintenance.md` (update notes and the lock paths that move together). Read them only for the components you change.
- **Machine state:** `state.root` of the context (records, backups, host overrides, the settings base). Never commit anything from there.

## Instance files

| Path | Role | Written by |
| --- | --- | --- |
| `workstation.toml` | identity, instance, profiles, gate, commit rules, components and their methods, profiles and options, settings, skills, pins, privacy, protected files, upstream | this skill |
| `flake.nix`, `flake.lock` | instance inputs (nixpkgs, home-manager, `dotsteward` with follows, component inputs between `# dotsteward:inputs:begin` and `# dotsteward:inputs:end`); the lock only through `nix flake lock` or `nix flake update <input>` | this skill (inputs), Nix (lock) |
| `versions.lock.json` | every version, URL, size and hash the components' rules read | this skill, then `dotsteward sync` |
| `home.nix` | plain Home Manager configuration without component checks | this skill |
| `components/<name>/` | private components: `default.nix` (the contract), optional `package.nix` (instance packages), hook and check scripts | this skill |
| `agent/skills/<name>/`, `agent/skills.lock.json` | vendored instance skills and their lock (digests, provenance, expected count) | this skill, then `dotsteward pins sync --skill` |
| `agent/overlays/<skill>.md` | per-skill overlays of the framework skills (`[skills.overlays]` may move them) | the user, or this skill on request |
| `home/AGENTS.md` (`agent_rules.source`) | shared agent rules linked into every enabled agent | this skill, unless protected |
| `local-maintained-files/` (`settings.buffer_dir`) | the settings buffer: `buffer.toml` and `files/` | only this skill, through `dotsteward settings` |
| `tests/` | instance static scripts listed in `[gate] static` | this skill |
| `.dotsteward/manifest.<system>.json`, `.dotsteward/stage0.<platform>.env` | generated mirrors of the evaluated manifest | `dotsteward sync` only |
| `.dotsteward/cli.sh`, `bootstrap.sh` | framework launcher and stage-0, byte-identical to the pinned framework's template | framework upgrades only |
| `rebuild.sh`, `rollback.sh`, `update.sh` | thin wrappers around the CLI | framework template |
| `README.md`, `AGENTS.md` | instance documentation (policy, not version numbers) | this skill |

## Facts from the context

`dotsteward context --json` replaces every hard-coded path:

| Field | Use |
| --- | --- |
| `instance.path`, `instance.remote`, `instance.branch`, `instance.checkout` | where to work, the remote check, the branch, the canonical checkout |
| `profiles.current`, `profiles.check`, `profiles.bootstrap`, `profiles.modes` | the profile for preflight, rebuild and E2E; `fresh` or `adopt` per profile |
| `state.candidate`, `state.validation`, `state.log` | the transaction records (read them with `dotsteward update status --json`) |
| `gate.*` | Nix job limits, free-space floor, binary cache, gate step names |
| `commit.*` | the settings and upgrade subjects and the commit types the publish step accepts |
| `protected` | byte-protected paths |
| `overlays` | the overlay file of each framework skill, or null |
| `components[]` | each enabled component's source (`catalog` or `instance`), method, profiles, settings targets and commands |
| `settings.buffer_dir`, `settings.target_names`, `settings.entry_ids` | the buffer location and what it tracks (never values) |
| `skills.hm_root`, `skills.instance_skill_names` | where framework skills are linked, which instance skills exist |
| `framework.version`, `framework.rev`, `framework.upstream` | the pinned framework release and its upstream |
| `platform.system`, `platform.fast_path` | this machine's system and whether it is on the fast path |

## Commands

| Command | Role |
| --- | --- |
| `dotsteward preflight --read-only --json --profile P` | read-only machine check (exit 3: adaptive route) |
| `dotsteward update prepare --official-sources-only --scope maintain` | records the base of the transaction |
| `dotsteward gate --scope maintain` | the one validation of the final tree (preflight, static, pins, flake check, CLI probes) |
| `dotsteward update status --json` | the candidate and validation records |
| `dotsteward update publish --scope maintain` | pushes the validated commits without force |
| `dotsteward rebuild --profile P --switch` | builds and activates the generation, applies settings, installs agent tools and skills |
| `dotsteward e2e --profile P` | verifies the machine against the instance |
| `dotsteward sync` | regenerates the `.dotsteward/` mirrors, then the derived lock values |
| `dotsteward pins latest`, `dotsteward pins sync --skill NAME` | official version candidates; skill digests in the skills lock |
| `dotsteward install --profile P --check-only` | checks every install method of the profile |
| `dotsteward agents check --profile P` | checks the agent tools and the skill layout |
| `dotsteward settings ...` | the settings buffer (`local-maintained-files.md`) |
| `dotsteward component run NAME HOOK` | runs a component hook with the hook environment |

## New-file checklist

- Stage every new file (`git add -A`); Nix and the gate see only tracked files.
- Shell scripts: a file with a shebang is executable; one without declares `# shellcheck shell=bash`. The static check runs `bash -n` and ShellCheck at the locked version.
- No script pipes a download into a shell, force-pushes or allows package downgrades (static bans).
- Hook and check scripts live in the component directory and are referenced from `default.nix` (they are copied into the store); they read the hook environment (`DOTSTEWARD_PROFILE`, `DOTSTEWARD_PROFILE_MODE`, `DOTSTEWARD_CHECK_ONLY`, ...), never hard-coded paths.
- A new Home Manager link: add it to `rollback.managedLinks`. If it replaces an existing user file, also add it to `rebuild.adoptPaths` and `bootstrap.backupPaths`; a force-linked file needs `rollback.forceLinkedRestore`.
- New pins go only into `versions.lock.json` at paths a component rule reads; derived values and mirrors come from `dotsteward sync`.
- Paths that version updates may change: `gate.updatePaths` of the component (or `[gate] update_allowlist`).
- An instance static script: list it in `[gate] static`.
- Describe behaviour and policy in `README.md` and `AGENTS.md`, not version numbers.

## Removal checklist

Inventory every reference with `git grep -n '<name>'` first. Remove the `[components.<name>]` table or the private component, package declarations, flake inputs (then `nix flake lock`), lock entries, configuration files, settings entries, checks, docs, allowlist entries and links; run `dotsteward sync`. Preserve recoverable user state unless deletion was explicitly requested. Prove that the removed command or configuration no longer comes from the instance and that any replacement passes the same checks.
