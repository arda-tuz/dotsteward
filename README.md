# dotsteward

dotsteward is a framework for reproducible agent workstations built on Nix and
Home Manager. You keep a private instance repository that describes your
machine in one `workstation.toml`; dotsteward builds it, activates it,
validates it end to end, keeps its pinned versions current and carries
locally changed application settings back into the repository.

Status: under development, not released yet (version `0.0.0`). Interfaces
may change without notice until the first release.

## Catalog

The framework ships these components:

| Component | What it provides |
| --- | --- |
| `shell` | zsh with starship |
| `claude-code` | Claude Code |
| `codex` | Codex |
| `herdr` | herdr |
| `opencode-pi` | OpenCode and Pi |
| `vscode` | VS Code |

Anything else lives in your instance as a private component.

## Platforms

- Ubuntu 24.04 on x86_64 (primary).
- macOS on arm64 with standalone Home Manager (evaluated; not yet a
  supported install target).

## Command line

```sh
nix run github:arda-tuz/dotsteward -- --help
nix run github:arda-tuz/dotsteward -- version
```

From a checkout:

```sh
./cli/dotsteward --help
./cli/dotsteward version
```

## Development

```sh
bash tests/run.sh              # fast test suites (no Nix needed)
bash tests/run.sh tests/skeleton --only version
nix flake check -L             # every check in the Linux build sandbox
git ls-files -z '*.nix' | xargs -0 nix fmt --   # format Nix files
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the rules every change follows and
[SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

MIT, see [LICENSE](LICENSE).
