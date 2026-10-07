# Architecture

dotsteward turns a private Git repository into a reproducible workstation for coding agents. It is built on Nix and Home Manager, ships a small catalog of agent-centric tools, and comes with agent skills that maintain the repository for you.

This page explains how the pieces fit together. For a first install, read [getting-started-ubuntu.md](getting-started-ubuntu.md) or [getting-started-macos.md](getting-started-macos.md); [concepts.md](concepts.md) defines the terms used here.

## Two repositories

| Repository | Owner | Contains |
| --- | --- | --- |
| **Framework** (this repository, public) | dotsteward contributors | the Nix library, the catalog components, the `dotsteward` CLI and its engines, the framework skills, the instance template, tests and docs |
| **Instance** (yours, private) | you | `workstation.toml`, your lock files, your private components, your settings buffer, your skill overlays and your own tests |

The instance pins the framework by release tag in its `flake.lock`. Upgrading the framework is a deliberate step: the update skill shows the release notes, moves the tag and validates the result before anything is published.

The framework never contains user data. Identity (username, home directory, repository remote) lives in the instance.

## Concepts

- **Component**: one unit of the workstation, for example "Claude Code" or "zsh + starship". A component is a Home Manager module that fills the `dotsteward.components.<name>` contract: install method per platform, pinned versions and their official sources, settings files the user may edit locally, checks and probes, backup and rollback declarations, and documentation.
- **Catalog**: the components shipped by the framework: Claude Code, Codex, herdr, zsh + starship, OpenCode and Pi, VS Code (see [catalog.md](catalog.md)).
- **Private component**: a component written in your instance under `components/<name>/`, using exactly the same contract as the catalog. Anything outside the catalog is a private component.
- **Profile**: a named way to apply the instance. Each profile has a mode:
  - `fresh`: a new machine; system-level installs, system packages and desktop-level hooks run.
  - `adopt`: an existing machine; system-level phases are skipped and system-level components are reported as `not-managed` instead of being changed.
- **Install methods**: `nix`, `official-binary` (checksummed release download), `deb` (Ubuntu), `app-archive` (macOS, into `~/Applications`), `external` (installed by something else; verify only). The instance chooses the method per component and platform.

## Layers

```text
 skills (maintain, update, contribute, init)        agent-facing workflows
        |
 dotsteward CLI (preflight, bootstrap, rebuild,      deterministic steps, exit codes,
 rollback, gate, update, e2e, pins, settings, ...)   JSON output
        |
 manifest.json (rendered from the Nix contract)      the only interface between Nix and the CLI
        |
 lib.mkInstance + core modules + components          Nix and Home Manager
        |
 workstation.toml + versions.lock.json + flake.lock  your instance data
```

### Nix layer

- `lib.mkInstance { inputs; }` turns an instance flake into complete outputs: Home Manager configurations per profile, packages, checks and the manifest.
- The instance owns `nixpkgs` and `home-manager`; the framework input follows them, so there is exactly one nixpkgs in the lock.
- Every enabled component contributes to one evaluated contract. It is rendered into `manifest.json`, embedded in every generation (`share/dotsteward/manifest.json`), and mirrored into the instance as `.dotsteward/manifest.<system>.json` and `.dotsteward/stage0.<platform>.env` for steps that run before a build (for example the very first bootstrap). A Nix check fails when a mirror is stale.
- Contract options never depend on the active profile; profile scoping uses the component's `profiles` field. This keeps one manifest per system.

### CLI layer

The `dotsteward` CLI is a Nix package built with the instance's nixpkgs. Instances call it through `.dotsteward/cli.sh`, which builds it once per `flake.lock` and caches the result.

| Command | Job |
| --- | --- |
| `preflight --read-only` | inspect the machine; fast path or adaptive route (exit 3), never writes |
| `bootstrap` | fresh machine: backups, prerequisites, verified Nix install, first activation, checks |
| `rebuild` | build and activate the committed tree, apply settings, install agent skills, verify the login shell |
| `rollback` | return to the previous generation and restore backups |
| `gate` | the single validation gate (static checks, privacy scan, pin consistency, `nix flake check`, CLI probes) with a memo keyed by the tree |
| `update prepare\|publish\|status` | transaction base and non-forced publishing |
| `e2e` | end-to-end checks of the live machine |
| `pins check\|sync\|latest` | pin consistency and official upstream candidates |
| `settings <command>` | the local settings buffer |
| `init` | create an instance from the template, non-interactively |
| `contribute <step>` | deterministic steps of the framework contribution flow |
| `context`, `doctor [--redact]` | instance facts for skills; a shareable health report |

Every command has stable exit codes ([exit-codes.md](exit-codes.md)) and a JSON mode where a skill or test needs to read the result. [cli.md](cli.md) documents every option.

### Engines

- **Pins engine**: checks that every pinned version, hash and revision in `versions.lock.json`, `flake.lock` and the skills lock agree; regenerates derived mirrors; asks official sources (GitHub releases, npm, APT indexes, DEB URLs, vendor manifests, Nix releases) for newer stable versions. Component declarations provide the rules and sources; the engine contains no application names.
- **Settings engine** (`local-maintained-files`): applications rewrite their own settings files, so these files are not read-only links. The engine tracks chosen keys in a repository buffer and merges three ways (published value, local value, last applied base). Local changes win until you write them back to the repository; remote changes apply on rebuild; conflicts are decided by you. JSON, TOML and comment-free JSONC are supported; a file with comments is never rewritten.

## Skills

| Skill | Distributed through | Job |
| --- | --- | --- |
| `dotsteward-init` | plugin marketplaces and skills installers | set up a new instance or install an existing one on a new machine |
| `dotsteward-maintain` | the pinned framework, deployed by Home Manager | add, remove or reconfigure components; write local settings back |
| `dotsteward-update` | same | refresh every pin to the newest compatible stable release; upgrade the framework |
| `dotsteward-contribute` | same | change the framework itself and upgrade the instance to the result |

Each skill starts with `dotsteward context --json`, reads the instance overlay `agent/overlays/<skill>.md` if present (your phrasing, report format and private notes), and classifies the request:

- **personal**: expressible in instance files; handled by maintain or update.
- **framework**: a defect or feature any user would hit; handled by contribute.
- **mixed**: contribute first, then maintain on the upgraded instance.

Safety rules of a skill (validation gate, publish preconditions, decision ownership, secrets, no force push, local-only changes) always win over an overlay.

## Contribution flow

`dotsteward-contribute` defaults to **fork mode** for everyone: the change lands in your fork and the instance pins your fork. A pull request to the upstream repository is opened only when you ask. **Owner mode** (direct merge and patch release) requires both an instance setting and push permission on the upstream repository.

Steps: reproduce with a failing test, fix generically, run the framework gate and the privacy scans (including a scan for values of your own instance), try the change on your machine through a temporary framework override, publish, verify that the merged tree equals the tested tree, release, upgrade the instance. A privacy finding stops everything; nothing is published.

## Privacy model

- Framework commits use a GitHub noreply address, UTC timestamps and no generated trailers.
- A pre-push hook and CI scan every pushed commit for secrets, home paths, e-mail addresses, non-ASCII text, commit metadata and a private denylist that lives outside every repository.
- Test fixtures are synthetic; secret-shaped strings are assembled at run time.
- The framework bundles no third-party skills, publishes no npm package and has no telemetry.

## Platforms

| Platform | Status |
| --- | --- |
| Ubuntu 24.04, x86_64 | primary: unit and end-to-end suites, and a clean-machine install in CI |
| macOS 14 or later, Apple Silicon | evaluated by every framework check, with a smoke workflow for a real Mac; not yet claimed as tested |

Bash commands run with Nix-provided GNU tools on both platforms, so their behaviour does not depend on the host's tool versions. Only the pre-Nix bootstrap runs with the system shell, and it is written for bash 3.2. [platforms.md](platforms.md) has the details.

## Testing

- Tests are written before the code they cover; bug fixes start with a reproduction.
- Every suite is black-box: it runs the real CLI in a temporary home with stub executables, local bare Git remotes and a local HTTP server.
- Sandbox-safe suites run inside `nix flake check`; real activation runs only on disposable CI machines and virtual machines, never on a developer's machine.

## Versioning

A single `VERSION` file feeds the Nix library, the CLI, the plugin manifests and the marketplace files; a contract test keeps them equal. Releases are Git tags with generated release notes; there is no hand-written changelog.
