# shell

zsh as the login shell, with the starship prompt and the
zsh-autosuggestions and zsh-syntax-highlighting plugins, installed by Home
Manager.

Enable it in `workstation.toml`:

```toml
[components.shell]
enable = true
```

## Methods

| Platform | Method | What is installed |
| --- | --- | --- |
| Linux | `nix` (the only supported method) | `zsh` of the locked nixpkgs and `packages.<system>.starship` in the Home Manager profile |
| darwin | `nix` (the only supported method) | the same packages, built for the darwin system |

zsh is the package of the instance's locked nixpkgs. starship is built from
the pinned upstream release on the locked nixpkgs toolchain
(`starship-package.nix`): the nixpkgs starship with only the version, the
source (`fetchFromGitHub`, tag `v<version>`), the vendored crates and
`doCheck = false` replaced, so its store path depends on the lock values
alone. The instance publishes it as `packages.<system>.starship`, and the
same package is used by `home.packages` and `programs.starship`. The lock
entries it reads are `nix_packages.starship.expected`,
`nix_packages.starship.source_nix_sha256` and
`nix_packages.starship.cargo_nix_sha256`; a lock without them fails with
`dotsteward: versions.lock.json lacks nix_packages.starship.expected
(required by component shell)`. `dotsteward init` merges them from
`seed.json`.

The login shell is the zsh of the Nix profile
(`$HOME/.nix-profile/bin/zsh`): `dotsteward rebuild` and the bootstrap add it
to `/etc/shells` and make it the user's login shell.

With `profiles` set, the other profiles get no zsh, no starship, no
`~/.zshrc` and no `starship.toml`; the contract values (manifest) stay the
same in every profile.

## Options

`[components.shell].options` in `workstation.toml`:

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `autosuggestions` | boolean | `true` | source zsh-autosuggestions in `~/.zshrc` |
| `syntaxHighlighting` | boolean | `true` | source zsh-syntax-highlighting in `~/.zshrc` |

```toml
[components.shell]
enable = true
options = { autosuggestions = true, syntaxHighlighting = false }
```

Both plugins are sourced from the store paths of the locked nixpkgs. With
both off the plugins block is left out. An unknown option or a value that is
not a boolean fails the build with a message that names it.

## Files

| Path | Written by | Content |
| --- | --- | --- |
| `~/.zshrc` | Home Manager link | `dotsteward.shell.zshrc.text` (below) |
| `~/.config/starship.toml` | Home Manager link, only when the instance sets `programs.starship.settings` | the settings as TOML |

Both links are managed links: rollback removes them and E2E checks them.
Bootstrap backs up `~/.zshrc` and `/etc/shells` before the first activation.
Home Manager's own `programs.zsh` stays off (it would write a different
`~/.zshrc`), and every starship shell integration of `programs.starship` is
off, because the `starship-init` block initializes the prompt.

`~/.zshrc` is rendered from ordered blocks
(`dotsteward.shell.zshrc.blocks.<name> = { order; text; attachToPrevious ?
false; }`): sorted by `order`, separated by one blank line, except that a
block with `attachToPrevious = true` follows the previous one directly. Every
block text ends in a newline. The component's blocks:

| Order | Block | Content |
| --- | --- | --- |
| 10 | `compinit` | `autoload -Uz compinit && compinit` |
| 20 | `history` | `HISTFILE`, `HISTSIZE`, `SAVEHIST`, `setopt APPEND_HISTORY HIST_IGNORE_DUPS SHARE_HISTORY` |
| 30 | `local-bin-path` | `~/.local/bin` first in a de-duplicated `PATH` |
| 40 | `plugins` | the plugins enabled by the options |
| 70 | `nix-profile-path` | `~/.nix-profile/bin` first in `PATH` when it exists |
| 99 | `starship-init` | `eval "$(starship init zsh)"` unless `TERM` is `dumb` |

An instance adds its own blocks between them by order, in `home.nix`, and
replaces the text of a default block with an ordinary definition:

```nix
{
  dotsteward.shell.zshrc.blocks = {
    keybindings = {
      order = 45;
      attachToPrevious = true;
      text = ''
        bindkey -e
      '';
    };
    aliases = {
      order = 50;
      text = ''
        alias gs='git status'
      '';
    };
  };

  programs.starship.settings = {
    add_newline = false;
  };
}
```

## Checks

- Probe: `starship --version` must run (presence).
- E2E: `zsh` and `starship` are required commands.
- Pinned versions: `zsh` (the locked nixpkgs version) and `starship` (the
  pinned release), compared with `nix_packages.zsh.resolved` and
  `nix_packages.starship.resolved` by `dotsteward pins check --nix`.
- `pins latest` reports the newest stable GitHub release of
  `starship/starship` (row `nix_packages.starship`).

## Verification

- The starship release tag: verified on 2026-10-06 from the upstream
  repository (`git ls-remote https://github.com/starship/starship
  refs/tags/v1.26.0` resolves to `fca92d8dcbd5981b0160af2f7ed7a430b6475a72`,
  the seed's `tag_revision`; v1.26.0 is the latest stable GitHub release).
- The seed's source and cargo hashes: verified on 2026-10-06 from a sandbox
  build of `packages.x86_64-linux.starship` (`checks.x86_64-linux.component-shell`),
  whose binary reports `starship 1.26.0`.
- `~/.zshrc` and the interactive shell: verified on 2026-10-06 from the same
  check, which compares the generation's `~/.zshrc` byte for byte and starts
  an interactive zsh with it that loads both plugins and the prompt.
- darwin: not verified (evaluation only; no darwin build runs in the
  framework checks).
