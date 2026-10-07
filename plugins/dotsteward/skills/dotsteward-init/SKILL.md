---
name: dotsteward-init
description: "Set up a dotsteward workstation: create a new private instance repository from the template, or install an existing instance on this machine."
---

# dotsteward Init

Set up a dotsteward workstation on this machine. A dotsteward instance is the user's own private repository that describes their workstation (applications, command line tools, agent skills and settings) and reproduces it on any supported machine through the dotsteward framework. This skill has two flows:

- **New instance**: create the user's private instance repository from the framework template, publish it, and set up this machine from it.
- **Existing instance**: clone the user's instance repository and install it on this machine, which may use another user name and home directory than the instance's other machines.

This skill runs before an instance exists on the machine, so there is no instance context or overlay yet; it runs the new instance's gate once, before the first push. Once the instance is active, the framework skills it installs take over: `dotsteward-maintain` for every personal change, `dotsteward-update` for version refreshes, `dotsteward-contribute` for changes to the framework itself.

## Rules

- **Read-only until the user agrees.** Section 2 only reads. Nothing is installed, created or changed before the user has seen what will happen and agreed to it.
- **Explain sudo before using it.** Name every step that needs administrator rights (section 2) before the first write. Never run `sudo` silently, never answer installers on the user's behalf, and never set `DOTSTEWARD_ASSUME_YES` (it exists for CI runners only).
- **Sudo steps run in a terminal.** Commands that ask for sudo or an installer confirmation (`bootstrap.sh --install-nix-only`, `./bootstrap.sh --profile ...`, `login-shell set`, any `sudo apt-get` from `references/platform-prereqs.md`) need a terminal: when this shell has none (`[ -t 0 ]` fails) or `sudo -n true` fails, give the user the exact command, `cd` included, to run in their own terminal, wait for them to report the result, then continue with the read-only steps (`nix --version`, `context --json`, `e2e`).
- **Verified installers only.** Nix comes from the pinned installer of a dotsteward release, which `bootstrap.sh --install-nix-only` checks by size and SHA-256 before running it. Never `curl | sh`, never pipe any download into a shell.
- **One framework release per run.** The release chosen in section 3.1 serves the Nix install, `init` and the instance's pinned framework.
- **Private by default.** The instance repository is created private. It holds no secrets, tokens, keys or machine state.
- **Gate before push.** As the instance's `AGENTS.md` says, the tree is pushed only after `dotsteward gate` passed, the first push included (3.5).
- **Confirm before activation.** `./bootstrap.sh` and `./rebuild.sh --switch` change the home directory (managed files become links, applications are installed). Confirm with the user first and tell them how to undo it.
- **Decisions stay with the user:** the flow, installing Nix, the components and methods, the repository name and owner, keeping the repository local, and fresh versus adopt.
- Talk with the user in their language; commands, file contents and commit messages stay in English.

## 1. Choose the flow

Ask whether the user already has a dotsteward instance repository. With one (a GitHub `OWNER/NAME` or a clone URL), follow section 4. Without one, follow section 3. Both start with section 2.

## 2. Check the machine (read-only)

```bash
uname -sm
cat /etc/os-release          # Linux
sw_vers                      # macOS
free -m                      # Linux: memory
sysctl -n hw.memsize         # macOS: memory in bytes
command -v nix git gh curl xz
nix --version
gh auth status
df -Pk "$HOME" /
```

Compare the results with `references/platform-prereqs.md`: the supported platforms, the tools needed before Nix, the memory (at least 4 GiB) and the free space (at least 15 GiB). Report what is missing and what each part of the setup will need. Then explain the sudo needs before doing anything:

- the **Nix daemon** install (multi-user Nix: it creates `/nix`, build users and a system service);
- the **system packages** of a fresh machine (Ubuntu: one APT transaction for the base packages and the packages of the chosen components; macOS: the Xcode Command Line Tools);
- the **login shell** (adding the Nix profile's zsh to `/etc/shells` and making it the user's shell), when the instance enables the `shell` component.

A missing tool is installed only after the user agrees, as `references/platform-prereqs.md` describes.

## 3. New instance

Details, alternatives and failure handling: `references/new-instance.md`.

### 3.1 Choose the framework release

```bash
tag=$(gh release view --repo arda-tuz/dotsteward --json tagName --jq .tagName)
```

Without `gh`, `references/new-instance.md` reads the newest tag with `git ls-remote`. Show the tag to the user; it is used for the whole run.

### 3.2 Install Nix (only when it is missing)

When `command -v nix` found nothing and the user agrees, install the Nix version pinned by that release with its verified installer:

```bash
work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-init.XXXXXX")
git clone --depth 1 --branch "$tag" https://github.com/arda-tuz/dotsteward "$work/dotsteward"
"$work/dotsteward/template/bootstrap.sh" --install-nix-only
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix --version
```

The installer asks for sudo and for confirmation, so unless this shell has a terminal and cached sudo credentials, give the user `cd <the clone> && ./template/bootstrap.sh --install-nix-only` with the clone's real path to run in their own terminal (rules), and continue with the last two lines once they report it finished. The release can also be fetched with `gh release download` (`references/new-instance.md`). Remove `"$work"` afterwards. Never install Nix by `curl | sh` or by an installer the release did not pin.

### 3.3 Ask the choices

1. The components and their methods: present the table of `references/catalog.md` and let the user choose; the defaults are fine for most users.
2. The repository: name (default `workstation`) and owner (`gh api user --jq .login`, or an organization the user names), and whether it is created on GitHub now or kept local.
3. The systems (`x86_64-linux`, `aarch64-darwin` or both) and the directory of the checkout (default `~/<name>`).
4. The remote, exactly as `git remote get-url origin` will print it, in the protocol `gh` uses for clones:

   ```bash
   gh config get git_protocol
   ```

   `ssh` gives `git@github.com:OWNER/NAME.git`, `https` gives `https://github.com/OWNER/NAME.git`.

Profile names, `--allow-unfree` and the contribute mode keep their defaults unless the user asks (`references/new-instance.md`).

### 3.4 Create the instance

`init` needs a git identity (`git config user.name` and `git config user.email`); ask the user to set one when it is missing. Then, with `dir` the checkout directory and `remote` the URL of 3.3:

```bash
nix --extra-experimental-features 'nix-command flakes' run "github:arda-tuz/dotsteward/$tag" -- init \
  --dir "$dir" --remote "$remote" --components shell,claude-code \
  --framework-ref "$tag" --non-interactive --json
```

Add `--method COMPONENT=METHOD`, `--method-platform COMPONENT=linux:METHOD,darwin:METHOD` and `--systems` as chosen. `init` is all or nothing: exit 1 (a refusal or a failed step) and exit 2 (a usage error) leave the directory as it was; report the message, fix the cause, and run it again. On success the instance is committed on `main` and the JSON document lists the next steps.

### 3.5 Create the private repository, validate, push

Create the private repository without pushing, so that the remote exists:

```bash
gh repo create "OWNER/NAME" --private --source "$dir" --remote origin
git -C "$dir" remote get-url origin
gh repo view "OWNER/NAME" --json visibility --jq .visibility
```

The URL must equal `remote` exactly (else `git -C "$dir" remote set-url origin "$remote"`), and the visibility must be `PRIVATE`. When the user keeps the repository local, add only the remote (`git -C "$dir" remote add origin "$remote"`).

The instance's `AGENTS.md` rule holds from the first push on: the gate proves the tree before every push. Run it once, then push:

```bash
cd "$dir" && ./.dotsteward/cli.sh gate --scope maintain
git -C "$dir" push -u origin main
```

The gate needs no sudo. It runs the static checks, the pins check, `nix flake check` and the probes of the built generation; on a new machine the first run downloads and builds most of the workstation (the later bootstrap reuses it), so start it in the background (Claude Code `run_in_background`; Codex with a timeout of at least 45 minutes) and wait for it once. A failed step prints its log; report it and fix the cause before pushing (`references/new-instance.md`). A repository kept local is pushed once it exists. Until the push, `e2e` stops at `core:repo-remote` and the bootstrap that ends with it exits non-zero after everything else is installed; verify such a machine with `e2e --keep-going` (3.6, `references/new-instance.md`).

### 3.6 Set up this machine

Confirm with the user which path applies, then run it from the checkout; the bootstrap and `login-shell set` ask for sudo, so without a terminal or cached sudo credentials give them to the user to run in their own terminal (rules):

- **A fresh machine** (nothing installed yet): `bootstrap.sh` checks the machine (read-only preflight; exit 3 means the machine is off the supported fast path, and nothing was written), backs up every file the instance manages, installs the prerequisites, the pinned Nix and the system packages, activates the generation, sets the login shell and runs the end-to-end checks.

  ```bash
  cd "$dir" && ./bootstrap.sh --profile fresh
  ```

- **A machine that is already set up**, with Nix and the user's applications: adopt it.

  ```bash
  cd "$dir" && ./rebuild.sh --profile workstation --switch
  ```

  The rebuild does not change the login shell. When the instance enables the `shell` component, the end-to-end checks expect the Nix profile's zsh as the login shell, so set it next, once the user agrees (it asks for sudo, section 2; in the user's own terminal when the rules say so):

  ```bash
  cd "$dir" && ./.dotsteward/cli.sh login-shell set --profile workstation
  ```

`fresh` and `workstation` are the default profile names (`profiles.bootstrap` and `profiles.check`); use the names chosen at `init`. Then verify the machine with the profile that was activated (`profile` is `fresh` after the bootstrap, `workstation` after the rebuild); the bootstrap already ended with these checks, and running them again only reads:

```bash
cd "$dir" && ./.dotsteward/cli.sh e2e --profile "$profile"
```

Every finding names its check; fix the cause (usually a missing prerequisite or a component choice) and run the same command again. A repository kept local (3.5) cannot pass `core:repo-remote` before the push, and `e2e` stops at that check; verify it with `--keep-going` instead and treat a `core:repo-remote` finding as the only expected one until the push:

```bash
cd "$dir" && ./.dotsteward/cli.sh e2e --profile "$profile" --keep-going
```

### 3.7 Summary

Report the release, the repository and its visibility, the gate result, the components and methods, the profile that was activated and the end-to-end result. Tell the user how to undo the activation:

```bash
cd "$dir" && ./rollback.sh --latest --dry-run
```

From now on the user changes the workstation by asking their coding agent: `dotsteward-maintain` adds, removes or reconfigures components and writes changed settings back, `dotsteward-update` refreshes every pinned version, and `dotsteward-contribute` fixes the framework itself.

## 4. Existing instance

Details: `references/existing-instance.md`.

1. Clone the instance into its canonical checkout (`instance.checkout`, `~/<name>` by default):

   ```bash
   gh repo clone "OWNER/NAME" "$HOME/NAME"
   ```

2. When Nix is missing and the user agrees, install the Nix version the instance pins, with the same verified installer (it asks for sudo and for confirmation: in the user's own terminal unless this shell has one and cached sudo credentials, rules):

   ```bash
   cd "$HOME/NAME" && ./bootstrap.sh --install-nix-only
   ```

3. Read the facts of the instance on this machine:

   ```bash
   cd "$HOME/NAME" && ./.dotsteward/cli.sh context --json
   ```

   Show `identity.runtime_matches_check` with the check and runtime user and home. Explain: `[identity]` in `workstation.toml` is only for checks (sandbox builds, `homeConfigurations.<username>`, the gate); activation always uses the user who runs it (`$USER` and `$HOME`). Installing on a machine with another user name or home therefore needs no file edit. If the user wants the check identity to follow this machine, that is a normal personal change: after the setup, ask `dotsteward-maintain` to change `[identity]`.

4. Confirm the activation with the user, then set up the machine, using the profile names of the context document (the bootstrap asks for sudo: in the user's own terminal when the rules say so):

   ```bash
   cd "$HOME/NAME" && ./bootstrap.sh --profile fresh          # a fresh machine
   cd "$HOME/NAME" && ./rebuild.sh --profile workstation --switch   # a machine that is already set up
   ```

   After the rebuild, when the instance enables the `shell` component and the user agrees (it asks for sudo; in the user's own terminal when the rules say so), set the login shell, which the rebuild leaves alone and the end-to-end checks expect:

   ```bash
   cd "$HOME/NAME" && ./.dotsteward/cli.sh login-shell set --profile workstation
   ```

5. Verify it with the profile that was activated (`profile`):

   ```bash
   cd "$HOME/NAME" && ./.dotsteward/cli.sh e2e --profile "$profile"
   ```

6. Report as in 3.7: the instance, `runtime_matches_check`, the profile, the end-to-end result and the rollback command, then hand over to `dotsteward-maintain` for every later change.
