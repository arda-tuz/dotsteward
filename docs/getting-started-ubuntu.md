# Getting started on Ubuntu

This guide sets up a workstation on Ubuntu 24.04 (x86_64), the primary
platform. You end with a private instance repository that describes the
machine and a home directory built from it. For macOS, read
[getting-started-macos.md](getting-started-macos.md).

There are two ways through it: let a coding agent drive the setup with the
`dotsteward-init` skill, or run the same commands yourself. Both make the
same changes and ask before each one that needs `sudo`.

## What you need

- Ubuntu 24.04 on x86_64, as a user who may use `sudo`. Another release or
  architecture is off the supported fast path: the bootstrap's read-only
  preflight stops there (exit 3) before it writes anything.
- At least 4 GiB of memory (8 GiB or more recommended; the validation gate
  derives its build parallelism from the memory and CPUs, see
  [workstation.toml](workstation-toml.md#gate)) and at least 15 GiB free on
  the file systems of `$HOME` and `/nix`.
- `git`, `curl` and `xz` (the Nix installer unpacks a `.tar.xz`):

  ```bash
  sudo apt-get install git ca-certificates curl xz-utils
  ```

- A GitHub account for the private instance repository, with `gh auth login`
  done (`gh` can also come from Nix once Nix is installed).
- A git identity (`git config --global user.name` and `user.email`): the new
  instance is committed with it.

`sudo` is needed for three things only: installing Nix (a multi-user install
that creates `/nix`, build users and a service), the system packages of a
fresh machine (one APT transaction), and making the Nix profile's zsh your
login shell when the `shell` component is enabled.

## With a coding agent

Install the `dotsteward-init` skill through one of its channels, then ask
the agent to set up a dotsteward workstation:

```bash
# Claude Code
claude plugin marketplace add https://github.com/arda-tuz/dotsteward.git
claude plugin install dotsteward@dotsteward

# Codex
codex plugin marketplace add https://github.com/arda-tuz/dotsteward.git
codex plugin add dotsteward@dotsteward

# any agent supported by gh skill
gh skill install arda-tuz/dotsteward dotsteward-init --agent claude-code --scope user
```

The skill checks the machine read-only, explains what needs `sudo`, asks for
your choices (components, repository, systems) and then runs the steps
below. It hands commands that need a password to you to run in your own
terminal.

## By hand

### 1. Choose a release

Use one framework release for the whole setup:

```bash
tag=$(gh release view --repo arda-tuz/dotsteward --json tagName --jq .tagName)
echo "$tag"
```

### 2. Install Nix (when it is missing)

The release pins the Nix installer by size and SHA-256. Its stage-0
bootstrap verifies the download before running it; never pipe an installer
into a shell.

```bash
work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-init.XXXXXX")
git clone --depth 1 --branch "$tag" https://github.com/arda-tuz/dotsteward "$work/dotsteward"
"$work/dotsteward/template/bootstrap.sh" --install-nix-only
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix --version
rm -rf -- "$work"
```

### 3. Create the instance

`dotsteward init` writes a new instance from the template, locks it, renders
its mirrors, checks its pins and commits it. It is all or nothing: on any
failure the directory is left as it was.

```bash
nix --extra-experimental-features 'nix-command flakes' run "github:arda-tuz/dotsteward/$tag" -- init \
  --dir ~/workstation --remote git@github.com:OWNER/workstation.git \
  --components shell,claude-code,codex --framework-ref "$tag"
```

`--remote` must be exactly what `git remote get-url origin` will print
(`https://github.com/OWNER/workstation.git` when `gh` uses HTTPS). Choose
components from the [catalog](catalog.md); `--method COMPONENT=METHOD`
picks another install method. The result is a `workstation.toml` like the
[example](workstation-toml.md#example).

### 4. Validate it and publish it as a private repository

Create the private repository without pushing, prove the instance with the
gate, then push it. The instance's `AGENTS.md` asks for a passed gate before
every push, the first one included; right after `init` the gate validates
against the commit `init` made.

```bash
gh repo create OWNER/workstation --private --source ~/workstation --remote origin
gh repo view OWNER/workstation --json visibility --jq .visibility
cd ~/workstation && ./.dotsteward/cli.sh gate --scope maintain
git -C ~/workstation push -u origin main
```

The first gate downloads and builds most of the workstation, which the
bootstrap below reuses.

### 5. Set up the machine

On a fresh machine, the bootstrap does everything: read-only preflight,
backups of every file the instance will manage, prerequisites, the pinned
Nix, the system packages, activation, the login shell and the end-to-end
checks.

```bash
cd ~/workstation && ./bootstrap.sh --profile fresh
```

On a machine that is already set up (Nix and your applications installed),
adopt it instead. The rebuild leaves the login shell alone, so set it next
when the `shell` component is enabled:

```bash
cd ~/workstation && ./rebuild.sh --profile workstation --switch
cd ~/workstation && ./.dotsteward/cli.sh login-shell set --profile workstation
```

### 6. Verify

```bash
cd ~/workstation && ./.dotsteward/cli.sh e2e --profile workstation
```

Use the profile you activated (`fresh` after the bootstrap). Every finding
names its check. Until the repository is pushed, the remote check fails;
`--keep-going` runs every other check anyway.

## An existing instance on a new machine

Clone your instance into its checkout (`instance.checkout`, `~/workstation`
by default) and run the bootstrap; it installs the pinned Nix itself:

```bash
gh repo clone OWNER/workstation ~/workstation
cd ~/workstation && ./bootstrap.sh --profile fresh
```

On a machine that is already set up, install Nix when it is missing
(`./bootstrap.sh --install-nix-only`), then adopt it with `./rebuild.sh` as
in step 5. The new machine may use another user name and home than the
instance's `[identity]`: activation always uses the user who runs it.

## Undo

`rollback` sets the login shell back to `/bin/bash`, removes the managed
links (or returns to the previous Home Manager generation) and restores the
files it replaced from their backups. Settings files, Nix, packages and your
data stay.

```bash
cd ~/workstation && ./rollback.sh --latest --dry-run
cd ~/workstation && ./rollback.sh --latest --apply
```

## Next steps

Change the workstation by asking your coding agent: `dotsteward-maintain`
adds, removes or reconfigures components and writes changed settings back,
`dotsteward-update` refreshes every pinned version, and
`dotsteward-contribute` fixes the framework itself. [concepts.md](concepts.md)
explains the model and [cli.md](cli.md) every command.
