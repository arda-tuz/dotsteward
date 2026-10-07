# Concepts

The words the rest of the documentation uses, in the order you meet them.

## Framework and instance

dotsteward is split into two repositories:

- The **framework** (this repository, public) holds the Nix library, the
  catalog components, the `dotsteward` command line interface and its
  engines, the framework skills, the instance template, tests and docs. It
  never contains anything about a particular user.
- An **instance** (yours, private) describes one person's workstation:
  `workstation.toml`, the lock files, private components, the settings
  buffer, skill overlays and the instance's own tests.

The instance pins one framework release in its `flake.lock`. Upgrading the
framework is a deliberate, validated change of the instance, like any other.

## Check identity and runtime identity

`[identity]` in `workstation.toml` names the **check identity**: the user and
home that sandbox builds, `homeConfigurations.<username>` and the gate
evaluate for. Activation on a machine always uses the **runtime identity**,
the user who runs it (`$USER` and `$HOME`). One instance therefore installs
on machines with different user names and homes without any edit;
`dotsteward context --json` shows both identities and whether they match.

## Components

A **component** is one unit of the workstation, for example Claude Code or
zsh with starship. It is a Home Manager module that fills the
`dotsteward.components.<name>` contract: its install method per platform,
its pinned versions and their official sources, the settings files the user
may change locally, its probes and end-to-end checks, its backup and
rollback declarations, and its documentation.

- The **catalog** is the set of components the framework ships: Claude
  Code, Codex, herdr, zsh with starship, OpenCode and Pi, and VS Code (see
  [catalog.md](catalog.md)).
- A **private component** lives in the instance under `components/<name>/`
  and uses exactly the same contract. Anything outside the catalog is a
  private component.

A component is part of the instance when its `[components.<name>]` table
says `enable = true`.

## Install methods

Each component supports one or more **install methods** per platform and has
a default; the instance may choose another one per component and platform.

| Method | What it does |
| --- | --- |
| `nix` | Home Manager installs it from Nix. |
| `official-binary` | A pinned vendor release, checked by size and SHA-256, into `~/.local/bin`. |
| `deb` | Debian packages with pinned minimum versions, in one APT transaction (Ubuntu). |
| `app-archive` | A pinned application bundle, copied into `~/Applications` (macOS). |
| `external` | Installed by something else; dotsteward only verifies it. |

`deb` and `app-archive` are system-level methods: they run only in a `fresh`
profile.

## Profiles

A **profile** is a named way to apply the instance to a machine. Each
profile has a **mode**:

- `fresh`: a new machine. The bootstrap installs the system packages, the
  system-level components and the system hooks, then activates the user
  environment.
- `adopt`: a machine that is already set up. System-level phases are
  skipped, and system-level components are reported as `not-managed`
  instead of being changed.

A component may be limited to some profiles. The template defines
`workstation` (adopt; the default and check profile) and `fresh` (the
bootstrap profile).

## Generations and the manifest

Building the instance for a profile produces a Home Manager **generation**.
Every enabled component contributes to one evaluated contract, rendered as
the **manifest** (`manifest.json`) inside each generation. The manifest is
the only interface between Nix and the CLI: the end-to-end checks, the
probes, the installer and the rollback read it.

Steps that run before anything is built, such as the very first bootstrap,
read **mirrors** of the manifest committed in the instance under
`.dotsteward/`. `dotsteward sync` regenerates them, and a Nix check fails
when a mirror is stale.

## Lock files and pins

Every version the workstation uses is pinned:

- `flake.lock`: nixpkgs, Home Manager, the dotsteward release and the flake
  inputs of components.
- `versions.lock.json`: every other version, URL and hash that components
  read (vendor releases, Debian packages, application archives).
- `agent/skills.lock.json`: the vendored instance skills and their digests.

The **pins engine** (`dotsteward pins`) checks that these files agree with
each other and with the rules the components declare, rewrites the derived
values, and asks official sources for newer stable releases.

## The gate and transactions

Every change to an instance is a **transaction**: `update prepare` records
a base, the change is made, the **gate** (`dotsteward gate`) proves the
resulting tree, and `update publish` pushes a commit whose tree is exactly
the proven tree. The gate runs the static checks (including the privacy
scan), the pins check, `nix flake check` and the CLI probes of a built
generation; a passed tree is remembered, so an unchanged tree is not proven
twice.

A transaction has a **scope**: `update` (only pinned versions may change,
within an allowlist of paths) or `maintain` (any change, with conventional
commit subjects).

## Settings buffer

Applications rewrite their own settings files, so those files cannot be
read-only links into the Nix store. Instead the instance tracks chosen keys
(or whole files) in the **settings buffer**, the `local-maintained-files/`
directory. The settings engine (`dotsteward settings`) merges three ways:
the published value, the local value and the last applied base. Local
changes win until you write them back to the repository
(`settings flush`); published changes are applied on the next rebuild; a conflict
waits for your decision (`settings resolve`).

## Skills and overlays

The framework ships agent skills that drive these commands for you:
`dotsteward-maintain` for personal changes, `dotsteward-update` for version
refreshes, `dotsteward-contribute` for changes to the framework itself, and
`dotsteward-init` to set up an instance. An instance may add an **overlay**
per framework skill, `agent/overlays/<skill>.md`, with its own phrasing,
report format and notes; the safety rules of a skill always win over an
overlay. The instance may also vendor its own skills under `agent/skills/`.

## Machine state

Everything dotsteward records about one machine (backups, transaction and
validation records, logs, the launcher cache) lives outside the repository,
under `~/.local/state/dotsteward` by default (`state.root`). Backups are
taken before any managed file is replaced, and `dotsteward rollback` uses
them to undo the setup.

See [architecture.md](architecture.md) for how the pieces fit together and
[workstation-toml.md](workstation-toml.md) for every configuration key.
