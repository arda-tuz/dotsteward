# Getting started on macOS

dotsteward manages a macOS home directory with standalone Home Manager on
Apple Silicon (`aarch64-darwin`). Every framework check evaluates the darwin
configurations, and a smoke workflow exists to install the catalog on a real
Mac, but macOS is not yet claimed as a tested platform: expect rough edges
and report them. [platforms.md](platforms.md) lists what differs from Linux.

The steps follow [getting-started-ubuntu.md](getting-started-ubuntu.md);
this page gives only what is different on a Mac.

## What you need

- macOS 14 or later on Apple Silicon (arm64), as an administrator. An older
  macOS or an Intel Mac is off the fast path: the read-only preflight stops
  there (exit 3) before it writes anything.
- At least 15 GiB free on the file systems of `$HOME` and `/nix` (the Nix
  installer creates its own APFS volume).
- The Xcode Command Line Tools, which provide `git`. The bootstrap checks for
  them and stops with this hint when they are missing:

  ```bash
  xcode-select --install
  ```

  Finish the installation before you continue. `curl` and `xz` are built in.
- A GitHub account with `gh auth login` done, and a git identity, as on
  Ubuntu.

`sudo` is needed to install Nix (the multi-user install creates the `/nix`
volume, build users and a launch daemon) and to make the Nix profile's zsh
your login shell (`/etc/shells` and `dscl`) when the `shell` component is
enabled. There are no system packages on macOS.

## Create the instance

The agent route and steps 1 and 2 (release and Nix) are the same as on
Ubuntu. When you run `init`, choose the darwin system:

```bash
nix --extra-experimental-features 'nix-command flakes' run "github:arda-tuz/dotsteward/$tag" -- init \
  --dir ~/workstation --remote git@github.com:OWNER/workstation.git \
  --systems aarch64-darwin --components shell,claude-code,vscode --framework-ref "$tag"
```

One instance can serve both platforms: `--systems x86_64-linux,aarch64-darwin`
(the first system is the one the checks build). Each component picks its
darwin install method by default:

| Component | Default on macOS |
| --- | --- |
| `shell`, `herdr` | `nix` |
| `claude-code`, `codex` | `official-binary` (the vendor's darwin arm64 build) |
| `opencode-pi` | `official-binary` for OpenCode, Pi from Nix |
| `vscode` | `app-archive`: the vendor's archive, verified and copied into `~/Applications` |

`--method-platform COMPONENT=linux:METHOD,darwin:METHOD` chooses per
platform, for example `external` for an application you install yourself.

## Set up the Mac

A Mac without your applications takes the fresh profile:

```bash
cd ~/workstation && ./bootstrap.sh --profile fresh
```

The bootstrap runs with the system's own bash 3.2 until Nix exists; after
that every command runs with the tools the framework pins. In the fresh
profile, `app-archive` components such as VS Code are installed into
`~/Applications`; a newer bundle that is already there is kept.

A Mac that is already set up is adopted, then given its login shell:

```bash
cd ~/workstation && ./rebuild.sh --profile workstation --switch
cd ~/workstation && ./.dotsteward/cli.sh login-shell set --profile workstation
```

In the adopt profile `app-archive` components are `not-managed`: dotsteward
neither installs nor checks the bundle.

## Verify and undo

```bash
cd ~/workstation && ./.dotsteward/cli.sh e2e --profile workstation
cd ~/workstation && ./rollback.sh --latest --dry-run
```

On macOS, `rollback --latest --apply` sets the login shell back to
`/bin/zsh`. Application settings follow the platform: a settings target may
name a different path on darwin (VS Code's lives under
`~/Library/Application Support`), while the settings buffer in the
repository stays the same file on both platforms.

See [concepts.md](concepts.md) for the model and [cli.md](cli.md) for every
command.
