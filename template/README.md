# Workstation

This repository describes a workstation: the applications, command line tools,
agent skills and settings that make a machine yours, pinned so that a fresh
machine reproduces it. It is a dotsteward instance: the dotsteward framework
(the `dotsteward` flake input) turns these files into a Home Manager
generation, installs what Home Manager cannot, and checks the result.

## Set up a machine

A fresh Ubuntu 24.04 or macOS machine, from a clone of this repository:

```bash
./bootstrap.sh --profile fresh
```

`bootstrap.sh` checks the machine, backs up the files it will manage, installs
the pinned Nix after verifying its installer, installs the system packages of
the fresh profile, activates the generation, sets the login shell and runs the
end-to-end checks. It asks before every step that needs sudo.

A machine that already has Nix and your applications:

```bash
./rebuild.sh --profile workstation --switch
```

The profile names are those of `[profiles]` in `workstation.toml`. The machine
may use another username and home directory than `[identity]`: activation
always uses the user who runs it.

## Everyday commands

| Command | What it does |
| --- | --- |
| `./rebuild.sh --profile P --switch` | Build the generation of profile P and activate it. |
| `./rebuild.sh --profile P --build-only` | Build it without activating. |
| `./rollback.sh --latest --dry-run` | Show what a rollback would undo; `--apply` undoes it. |
| `./update.sh prepare --official-sources-only` | Start a maintenance transaction from `origin`. |
| `./update.sh validate` | Prove the changed tree: static checks, pins, `nix flake check`, probes. |
| `./update.sh publish` | Push the proven tree. |
| `./update.sh status` | Show the records of the current transaction. |

Every wrapper runs the dotsteward command line interface pinned by
`flake.lock`, through `.dotsteward/cli.sh`; `./update.sh -h` lists its
options. With the coding agent skills below you rarely need them directly.

## Changing the workstation

Ask your coding agent; the framework skills do the work and validate it:

- `dotsteward-maintain` adds, removes, replaces or reconfigures applications,
  tools, skills and settings, and writes settings you changed on this machine
  back to the repository.
- `dotsteward-update` moves every pinned version to the newest stable
  release, including the dotsteward framework itself.
- `dotsteward-contribute` changes the framework when something is wrong for
  everyone, and upgrades this repository to the fixed release.

Every change goes through one gate (`dotsteward gate`) before it is published.

## Layout

| Path | Content |
| --- | --- |
| `workstation.toml` | The configuration: identity, systems, profiles, components and their options. |
| `flake.nix`, `flake.lock` | Flake inputs: nixpkgs, home-manager, the dotsteward release and the inputs of components. |
| `versions.lock.json` | Every pinned version, URL and hash the components read. |
| `home.nix` | Personal Home Manager settings that belong to no component. |
| `home/AGENTS.md` | Shared rules for your coding agents, linked into each agent's configuration. |
| `components/` | Private components: applications outside the dotsteward catalog. |
| `agent/skills/`, `agent/skills.lock.json` | Vendored agent skills and their lock. |
| `agent/overlays/` | Your additions to the framework skills. |
| `local-maintained-files/` | Settings carried across machines inside files the applications also rewrite. |
| `tests/` | Your own static checks, run by the gate. |
| `.dotsteward/` | Framework-owned: the launcher and generated mirrors (`dotsteward sync` writes them). |
| `bootstrap.sh`, `rebuild.sh`, `rollback.sh`, `update.sh` | Entry points; `bootstrap.sh` is framework-owned. |

`bootstrap.sh` and `.dotsteward/cli.sh` stay byte-identical to the pinned
framework release, and the `.dotsteward/` mirrors are generated: never edit
them by hand. Machine state (backups, records, logs) lives outside the
repository, in `~/.local/state/dotsteward` by default.
