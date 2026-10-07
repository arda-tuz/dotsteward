# Platform prerequisites

What the machine checks of section 2 compare with.

## Supported platforms

| Nix system | Machine | Support |
| --- | --- | --- |
| `x86_64-linux` | Ubuntu 24.04 on x86_64 | primary: every framework check runs on it, and a fresh machine is installed end to end on CI runners |
| `aarch64-darwin` | macOS 14 or later on Apple silicon (arm64), standalone Home Manager | evaluated only: the framework checks evaluate every darwin configuration without building it, and a real Mac runs only in the framework's macOS smoke workflow |

These are the fast path of a new instance (`[platform]` in `workstation.toml`). On another machine (another distribution or release, another architecture, an older macOS) the bootstrap's read-only preflight takes the adaptive route, exit 3, and stops before any write. Tell the user that the machine is outside the supported set; do not work around the preflight.

An instance may list both systems (`--systems x86_64-linux,aarch64-darwin`); the first one is the primary system of its checks.

## Before Nix

| Need | Ubuntu 24.04 | macOS |
| --- | --- | --- |
| `git` | `sudo apt-get install git` | the Xcode Command Line Tools: `xcode-select --install`, then wait until the installation has finished |
| `curl` and certificates (the verified Nix download) | `sudo apt-get install ca-certificates curl` | built in |
| `xz` (the Nix installer unpacks a `.tar.xz`) | `sudo apt-get install xz-utils` | built in |
| `gh` (optional: release lookup, repository creation and clone) | after Nix: `nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#gh` | the same |

Install a missing tool only after the user agrees. A fresh machine bootstrap (`./bootstrap.sh --profile ...`) installs the Ubuntu base packages itself in one APT transaction, together with the packages of the chosen components, and stops on macOS with the hint above when the Command Line Tools are missing. `--install-nix-only` installs nothing but Nix, so it needs these tools first.

## Administrator rights

| Step | Why sudo | When |
| --- | --- | --- |
| Nix install | the multi-user installer creates `/nix`, the build users and the Nix daemon service (on macOS also an APFS volume) | only when Nix is missing |
| System packages | Ubuntu: one APT transaction (the base packages and the components' packages, such as a DEB install method) | fresh profiles only |
| Login shell | adds the Nix profile's zsh to `/etc/shells` and changes the user's shell (`chsh` on Ubuntu, `dscl` on macOS) | when the `shell` component is enabled |

Each of these asks for the password itself, and the Nix installer and APT also ask for confirmation, so they need a terminal: when the agent shell has none (`[ -t 0 ]` fails) or `sudo -n true` fails, the user runs the command, and any `sudo apt-get install` above, in their own terminal (see the rules of the skill). Nothing else needs sudo. A fresh machine bootstrap sets the login shell itself. A machine that is already set up and adopted by `./rebuild.sh --switch` needs sudo only for the login shell, which the rebuild does not set: run `./.dotsteward/cli.sh login-shell set --profile <check profile>` after the rebuild.

## Memory and free space

Memory: at least 4 GiB, 8 GiB or more recommended. Read it with `free -m` (Ubuntu) or `sysctl -n hw.memsize` (macOS). The gate derives its Nix parallelism from the memory and CPUs of the machine (`gate.nix_max_jobs` and `gate.nix_cores` in `docs/workstation-toml.md` of the framework), so a 4 GiB machine builds one derivation at a time on one core: slow, but without running out of memory. Below 4 GiB, tell the user that builds may fail and suggest a larger machine.

Free space: check the file systems of `$HOME` and `/nix` (the root file system on Ubuntu, a separate volume on macOS) with `df -Pk`. Plan for at least 15 GiB free: the first build fetches nixpkgs and the components, and the maintenance gate of the instance later refuses to run below 5 GiB (its default `gate.min_free_gib`).

## Accounts

- A GitHub account, logged in with `gh auth login`, to create or clone the private instance repository. SSH or HTTPS both work; `gh config get git_protocol` decides the form of the remote.
- A git identity (`git config --global user.name` and `user.email`, or a per-directory one): `init` commits the new instance with it.
- User name and home: Linux user names match `^[a-z_][a-z0-9_-]*$`, macOS short names `^[A-Za-z_][A-Za-z0-9_.-]*$`; the home directory must be an absolute, existing path without whitespace, quotes, `$` or backslash. Every command refuses other identities before it writes anything.
