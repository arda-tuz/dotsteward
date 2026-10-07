# dotsteward

dotsteward turns a private Git repository into a reproducible workstation
for coding agents. You describe your machine in one `workstation.toml`;
dotsteward builds it with Nix and Home Manager, activates it, validates it
end to end, keeps every pinned version current and carries the settings you
change locally back into the repository. Agent skills do the maintenance
for you.

Status: under development. Interfaces may change without notice before
version 1.0.0.

## How it works

- **Your instance** is a private repository made from the framework's
  template: `workstation.toml`, lock files, your own components and your
  settings. It pins one dotsteward release.
- **The framework** (this repository) provides the Nix library, a catalog
  of components, the `dotsteward` command line interface and the skills.
- **Skills** drive it: `dotsteward-init` sets up an instance,
  `dotsteward-maintain` adds or changes components and writes settings
  back, `dotsteward-update` refreshes every pin, `dotsteward-contribute`
  fixes the framework itself and upgrades your instance to the result.
- **One gate** proves every change before it is published: static checks,
  a privacy scan, pin consistency, `nix flake check` and probes of the
  built generation.

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
  and `curl`. Nix is installed for you from a pinned, verified installer.

## Get started

- [Getting started on Ubuntu](docs/getting-started-ubuntu.md)
- [Getting started on macOS](docs/getting-started-macos.md)

The quickest way is to let your coding agent do it: install the
`dotsteward-init` skill, for example in Claude Code,

```sh
claude plugin marketplace add https://github.com/arda-tuz/dotsteward.git
claude plugin install dotsteward@dotsteward
```

and ask it to set up a dotsteward workstation. The guides list the other
channels and the manual steps.

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
