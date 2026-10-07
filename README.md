# dotsteward

Developers move between computers all the time: a company laptop, a
personal laptop, a desktop at home, and sooner or later a newly bought
machine that starts out empty. Making each of them feel like your own, with
the same tools, versions, settings and agent skills, usually costs hours of
installing, copying and remembering.

dotsteward takes that work off your hands. Install your favorite agentic
coding harness on the machine, for example Claude Code or Codex, point it at
your personal dotsteward repository, and the agent reproduces your whole
development setup there. When you change something on one machine, the
agent writes it back to the repository, so the next machine gets it too.

## How it works

- **A public framework and your private instance.** This repository is the
  framework: the Nix library, a catalog of components, the `dotsteward`
  command line interface, the agent skills and a template. Your instance is
  a private repository made from the template: one `workstation.toml` that
  lists your components and their settings, the lock files, and any
  components of your own. It pins one release of the framework.
- **Agent skills do the work.** `dotsteward-init` creates your instance or
  installs it on a new machine; `dotsteward-maintain` adds, removes or
  reconfigures components and writes locally changed settings back;
  `dotsteward-update` refreshes every pinned version; `dotsteward-contribute`
  fixes the framework itself and upgrades your instance to the fixed
  release.
- **Reproducible builds with Nix and Home Manager.** The instance is a Nix
  flake. Home Manager builds your tools and configuration files into one
  generation from the locked inputs, so every machine gets the same result,
  and `./rollback.sh` undoes an activation. What Nix cannot install (such as
  vendor packages) is installed from pinned, verified downloads.
- **One validation gate.** Every change is proven before it is pushed:
  static checks, a privacy scan, pin consistency, `nix flake check` and
  probes of the built generation.
- **Version pins from official sources.** `versions.lock.json` records the
  version, URL and hash of everything outside nixpkgs. Updates take new
  versions only from the official release channels of each project, never
  from mirrors, and keep the hashes verified.
- **A local settings buffer.** Applications rewrite their own settings
  files, so dotsteward does not lock them read-only. They live in the
  settings buffer (`local-maintained-files/`): your local changes keep
  working, and the agent writes them back to the repository when you ask.

## Quick start

Install the `dotsteward-init` skill in your coding agent through one of its
channels:

```sh
# Claude Code
claude plugin marketplace add https://github.com/arda-tuz/dotsteward.git
claude plugin install dotsteward@dotsteward

# Codex
codex plugin marketplace add https://github.com/arda-tuz/dotsteward.git
codex plugin add dotsteward@dotsteward
```

Then ask the agent to set up a dotsteward workstation. On your first
machine it creates your private instance repository; on every other machine,
tell it the repository (for example `OWNER/workstation`) and it installs
your setup from there. The skill checks the machine read-only first,
explains every step that needs `sudo`, and hands those steps to you to run
in your own terminal.

To do the same by hand, follow the guide for your platform:

- [Getting started on Ubuntu](docs/getting-started-ubuntu.md)
- [Getting started on macOS](docs/getting-started-macos.md)

## Catalog

| Component | What it provides |
| --- | --- |
| `shell` | zsh with starship |
| `claude-code` | Claude Code |
| `codex` | Codex |
| `herdr` | herdr |
| `opencode-pi` | OpenCode and Pi |
| `vscode` | VS Code |

Anything else lives in your instance as a private component, written
against the same contract. Details: [docs/catalog.md](docs/catalog.md).

## Platforms

| Platform | Status |
| --- | --- |
| Ubuntu 24.04, x86_64 | primary: tested end to end, including a clean-machine install in CI |
| macOS 14 or later, Apple Silicon | evaluated by every check, with a smoke workflow for a real Mac; not yet claimed as tested |

See [docs/platforms.md](docs/platforms.md).

## Requirements

- **Memory:** at least 4 GiB, 8 GiB or more recommended. The validation
  gate derives its Nix build parallelism from the memory and CPUs of the
  machine, so a 4 GiB machine builds one package at a time instead of
  running out of memory ([details](docs/workstation-toml.md#gate)).
- **Disk:** at least 15 GiB free for `/nix` and your home directory; the
  gate refuses to run below 5 GiB.
- **Accounts and tools:** a GitHub account for your private instance
  repository, `git` with your own identity (`user.name` and `user.email`),
  `curl` and `xz`. Nix is installed for you from a pinned, verified
  installer.

## Documentation

| Document | Content |
| --- | --- |
| [Concepts](docs/concepts.md) | instance, components, profiles, methods, the manifest, pins, the gate, the settings buffer, skills |
| [Architecture](docs/architecture.md) | how the layers, engines, skills and the privacy model fit together |
| [workstation.toml](docs/workstation-toml.md) | every configuration key with its default |
| [Command line](docs/cli.md) | every command and option, generated from the help text |
| [Exit codes](docs/exit-codes.md) | the exit status of every command |
| [Catalog](docs/catalog.md) | the components the framework ships |
| [Platforms](docs/platforms.md) | Linux and macOS differences, install methods, login shell |
| [Component contract](docs/component-contract.md) | every option a component sets; [writing components](docs/writing-components.md) walks through one |
| [Settings buffer](docs/settings-buffer.md) | how locally changed application settings reach the repository |
| [Pins engine](docs/pins-engine.md) and [update policy](docs/update-policy.md) | lock files, rule kinds, latest adapters; how an instance moves to newer releases |
| [Skills](docs/skills.md) and [overlays](docs/overlays.md) | the agent skills and how an instance adds its own guidance |
| [Privacy](docs/privacy.md) | the layers and the scanner that keep personal data out of public repositories |
| [Contributing from your machine](docs/contribute.md) and [testing](docs/testing.md) | the contribution flow and the test suites |

## Development

```sh
bash tests/run.sh              # fast test suites (no Nix needed)
bash tests/run.sh tests/static --only docs
nix flake check -L             # every check in the Linux build sandbox
tools/gen-docs.sh              # regenerate docs/cli.md and the catalog index
git ls-files -z '*.nix' | xargs -0 nix fmt --   # format Nix files
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the rules every change follows and
[SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

MIT, see [LICENSE](LICENSE).
