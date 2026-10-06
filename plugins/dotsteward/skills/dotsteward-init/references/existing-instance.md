# Existing instance

Details of section 4 of the skill: installing an instance the user already has on this machine, which may have another user name and home directory than the instance's other machines.

## Clone

Clone into the instance's canonical checkout, `instance.checkout` of its `workstation.toml` (`~/<instance.name>` by default): the settings alias and the publish fallback use that path. Without `gh`, clone the URL the user gives:

```bash
git clone "$remote" "$HOME/NAME"
```

The clone's `origin` must be exactly `instance.remote`, since the gate, the publish steps and the end-to-end checks compare the two. A clone over the other protocol (HTTPS instead of SSH, or the reverse) differs; set it with `git -C "$HOME/NAME" remote set-url origin "<instance.remote>"` when the user agrees, or clone again with the recorded URL.

## Nix

The instance pins its Nix version in `versions.lock.json` (and in its stage-0 mirror under `.dotsteward/`). `./bootstrap.sh --install-nix-only` installs exactly that version with the verified installer, only after the user agrees. A machine with Nix keeps it; compare its `nix --version` with the pin:

- the same version: either path of the next sections works;
- another version: `./bootstrap.sh --profile ...` refuses it, so use the rebuild path (a machine that is already set up), or let the user replace Nix themselves first.

## The context document

`./.dotsteward/cli.sh context --json` builds the CLI that the instance's `flake.lock` pins (the first run takes a while) and prints the facts of the instance on this machine. Read:

| Field | Meaning |
| --- | --- |
| `instance.path`, `instance.checkout` | where this clone is, and where the instance expects its canonical checkout; when they differ, offer to move the clone there before the setup |
| `instance.remote` | must equal `git remote get-url origin` |
| `identity.check_username`, `identity.check_home` | `[identity]`: the identity of sandbox builds, `homeConfigurations.<username>` and the gate |
| `identity.runtime_user`, `identity.runtime_home` | `$USER` and `$HOME`: the identity every activation uses |
| `identity.runtime_matches_check` | `true` when both pairs are equal |
| `profiles.bootstrap`, `profiles.check` | the fresh profile for `./bootstrap.sh` and the adopt profile for `./rebuild.sh` |
| `components` | the components and their methods, to tell the user what will be installed |

## Identity

`runtime_matches_check = false` is normal on a second machine and needs no file edit. Activation always runs as `$USER` with `$HOME`, the settings buffer stores only `~/` paths, and the gate builds the check identity in the sandbox, so nothing at run time depends on `[identity]`.

When the user wants the check identity to follow this machine anyway, that is a personal change of `workstation.toml`: after the setup, ask `dotsteward-maintain` to change `[identity]`, which validates and publishes it like any other change. Never edit `[identity]` by hand here, and never run `init` on an existing instance: its `--username` and `--home` flags are for new instances only.

## Setting up the machine

| Machine | Command | Profile |
| --- | --- | --- |
| Fresh (no applications yet) | `./bootstrap.sh --profile <profiles.bootstrap>` | fresh mode: backups, prerequisites, verified Nix, system packages, activation, login shell, end-to-end checks |
| Already set up | `./rebuild.sh --profile <profiles.check> --switch` | adopt mode: user-level parts only; system packages are reported as not managed |

The rebuild sets no login shell (it only moves one on a versioned Nix store path to the stable path). When the instance enables the `shell` component, set it on an adopted machine after the rebuild and before `e2e`, once the user agrees to the sudo prompt:

```bash
cd "$HOME/NAME" && ./.dotsteward/cli.sh login-shell set --profile <profiles.check>
```

Confirm with the user before either: activation replaces the files the instance manages with links into the generation. `./rollback.sh --latest --dry-run` shows what a rollback would undo. Preflight exit 3 (the adaptive route) stops the bootstrap before any write: the machine is off the fast path of `platform-prereqs.md`.

Then `./.dotsteward/cli.sh e2e --profile <the activated profile>` checks the commands, the managed links and files, the agent tools, the tracked settings, the login shell, the checkout and its remote. A finding names its check; fix the cause and run it again. An unclean checkout (`repo-clean`) usually means a file was edited during the setup: show `git status` to the user rather than discarding anything.
