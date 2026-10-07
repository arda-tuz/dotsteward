# New instance

Details of section 3 of the skill: creating the user's private instance repository from the framework template and setting up this machine from it.

## The framework release

The newest release of the framework is the default; the user may name an older tag. With `gh`:

```bash
tag=$(gh release view --repo arda-tuz/dotsteward --json tagName --jq .tagName)
```

Without `gh` (or before `gh` is logged in), the newest version tag:

```bash
tag=$(git ls-remote --tags --refs --sort=-version:refname https://github.com/arda-tuz/dotsteward 'v*' | head -n 1 | sed 's|.*refs/tags/||')
```

The same tag is used three times: the Nix installer comes from it, `nix run` runs its CLI, and `init --framework-ref` pins it in the new instance's `flake.nix`. Later framework upgrades are the job of `dotsteward-update`.

## Another framework source

Instead of a GitHub release, the user may name another framework source: a local checkout of the framework (to try a change before it is released), a fork, or a branch. The rule of one source per run stays: the Nix install, `nix run` and the pin of `init` all use it. From a local checkout (`framework` is its absolute path):

```bash
framework=/path/to/dotsteward
"$framework/template/bootstrap.sh" --install-nix-only
nix --extra-experimental-features 'nix-command flakes' run "path:$framework#dotsteward" -- init \
  --dir "$dir" --remote "$remote" --components shell,claude-code \
  --framework-url "path:$framework" --non-interactive --json
```

Run the Nix install line only when Nix is missing (as in the section below). `--framework-url` takes the whole flake reference of the instance's dotsteward input and excludes `--framework-ref`. Its forms:

| Source | `--framework-url` | `nix run` |
| --- | --- | --- |
| A local checkout as it is, uncommitted changes included | `path:/abs/dotsteward` | `path:/abs/dotsteward#dotsteward` |
| A committed branch of a local clone | `git+file:///abs/dotsteward?ref=BRANCH` | the same with `#dotsteward` |
| A fork or a branch on GitHub | `github:OWNER/dotsteward/BRANCH` or `git+https://github.com/OWNER/dotsteward?ref=BRANCH` | the same with `#dotsteward` |

A `path:` or `git+file:` source exists only on this machine: the instance builds here, but a clone on another machine cannot fetch its framework. Use such a pin to try a change; before the instance is set up anywhere else, move its dotsteward input to a release (`dotsteward-update` upgrades the framework of an installed instance). A GitHub fork or branch works everywhere, but it does not follow the releases either.

## Installing Nix

Only when `command -v nix` finds nothing, and only after the user agrees. The release's `template/bootstrap.sh --install-nix-only` reads the installer pin (URL, size, SHA-256 and the expected Nix version) from the `versions.lock.json` beside it, downloads the installer over HTTPS, refuses it on any size or digest difference, runs the official multi-user installer (which asks for sudo and for confirmation, and creates the Nix daemon; without a terminal it cannot ask, so the user runs it in their own terminal, see the rules of the skill), and checks `nix --version` against the pin. It does nothing else: no backups, no packages, no instance.

Fetching the release with `gh` instead of `git clone`:

```bash
work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-init.XXXXXX")
gh release download "$tag" --repo arda-tuz/dotsteward --archive tar.gz --dir "$work"
tar -xzf "$work"/dotsteward-*.tar.gz -C "$work"
"$work"/dotsteward-*/template/bootstrap.sh --install-nix-only
```

After the installer, load Nix into the current shell (new terminals load it themselves) and check the version:

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix --version
```

When `nix` is still not found, ask the user to open a new terminal. When the installer fails, report its output and stop; never fall back to another installer. Remove the temporary directory at the end:

```bash
rm -rf -- "$work"
```

A machine that already has Nix keeps it. `init` and `rebuild` work with the installed version, but `./bootstrap.sh --profile ...` refuses a Nix version other than the instance's pin; on such a machine use the rebuild path of section 3.6.

`gh` itself may be missing on a fresh machine. Once Nix exists, run it without installing it system-wide, and log in when `gh auth status` failed:

```bash
nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#gh
gh auth login
```

## Choices and the `init` flags

| Choice | Flag | Default |
| --- | --- | --- |
| Checkout directory | `--dir DIR` (missing or empty) | none: ask; `~/<name>` is the convention |
| Remote, exactly as `git remote get-url origin` prints it | `--remote URL` | none: from the owner, the name and `gh config get git_protocol` |
| Repository name | `--name N` | the name of the directory |
| Canonical checkout on every machine | `--checkout PATH` | the directory, as `~/...` below the home directory |
| Components | `--components a,b,c` (catalog names) | none |
| Method for every platform | `--method COMPONENT=METHOD` (repeatable) | the component's default |
| Method per platform | `--method-platform COMPONENT=linux:METHOD,darwin:METHOD` (repeatable) | the component's default |
| Systems | `--systems x86_64-linux,aarch64-darwin` (first one primary) | `x86_64-linux` |
| Profiles | `--profiles ADOPT_NAME,FRESH_NAME` | `workstation,fresh` |
| Unfree nixpkgs packages | `--allow-unfree` | off |
| How framework fixes are published | `--contribute fork` or `--contribute owner` | `fork` |
| Framework release | `--framework-ref TAG` | the release whose CLI runs |

The components and their methods come from `catalog.md` (in this directory); show the user its sections, recommend the defaults, and pass a method only when the user picks another one. The check identity (`[identity]`) defaults to the user running `init`; `--username` and `--home` exist for a different check identity only.

The adopt profile (first name) is the check and default profile: it manages the user's files on a machine that is already set up. The fresh profile (second name) is the bootstrap profile: it also installs system packages on a new machine.

`init` refuses (exit 1) a directory that is neither missing, empty nor filled by `nix flake init -t`, an unsafe user name or home, a missing git identity, and any failed step (`nix flake lock`, the mirror sync, the pins check); a usage error is exit 2. In every case the directory is left as it was. It never writes outside `--dir`.

## Repository

`gh repo create` with `--source`, `--remote origin` and without `--push` creates the empty private repository and adds the remote `origin` in the protocol of `gh config get git_protocol`. Afterwards the remote must be byte-equal to the `--remote` given to `init`, because the gate, the publish steps and the end-to-end checks compare `instance.remote` with `git remote get-url origin`:

```bash
test "$(git -C "$dir" remote get-url origin)" = "$remote" || git -C "$dir" remote set-url origin "$remote"
```

Kept local on request: add the remote now, so that the instance and its clone agree:

```bash
git -C "$dir" remote add origin "$remote"
```

When the user wants it published later, create the empty private repository and push the tree the gate proved (run the gate again first when the tree changed since):

```bash
gh repo create "OWNER/NAME" --private
git -C "$dir" push -u origin main
```

Until the push, `e2e` stops at `core:repo-remote` (code `remote-unreachable` or `remote-mismatch`), and the checks after it (`core:repo-skill-count`, late component hooks, `core:framework-skills`) do not run. This includes the `e2e` that ends `./bootstrap.sh`: the bootstrap then exits non-zero after everything else is installed (the login shell is already set), without its final `bootstrap complete` line. Verify such a machine with `--keep-going`, which runs every check, and treat a `core:repo-remote` finding as the only expected one until the push (`profile` is the profile that was activated):

```bash
cd "$dir" && ./.dotsteward/cli.sh e2e --profile "$profile" --keep-going
```

After the push, run `e2e` once more without `--keep-going`; it must pass.

## The gate before the first push

The instance's `AGENTS.md` asks for a passed gate before every push, and the first push is no exception. Right after `init` the branch has never been pushed, so `origin/main` does not exist yet; the gate then validates against `HEAD` and says so in its first line:

```bash
cd "$dir" && ./.dotsteward/cli.sh gate --scope maintain
```

Use the maintain scope: the update scope is for version refreshes. The gate holds its lock and answers from its memo when the same tree already passed. Its Nix parallelism follows the memory and CPUs of the machine (`gate.nix_max_jobs` and `gate.nix_cores`), so a 4 GiB machine builds one derivation at a time; `./.dotsteward/cli.sh context --json` shows the values. A failure names its step and prints the end of `validate.log` (the full log is under the state directory, `./.dotsteward/cli.sh update status`): `preflight` means the binary cache did not answer or `/nix/store` has less than 5 GiB free; `static` and `pins` point at a file of the instance; `flake-check` and `cli-probes` at a build. Report the cause; a defect of the framework itself goes to `dotsteward-contribute` once the instance is installed. Do not push before the gate passed, and never work around it.

## Setting up the machine

| Machine | Command | Profile mode | What happens |
| --- | --- | --- | --- |
| Fresh (no Nix, no applications) | `./bootstrap.sh --profile <bootstrap profile>` | fresh | preflight, backups, prerequisites, verified Nix, system packages, activation, login shell, end-to-end checks |
| Already set up (Nix present) | `./rebuild.sh --profile <check profile> --switch` | adopt | build, activation of the user-level parts, settings, agent tools; system packages are reported as not managed |

The rebuild sets no login shell: it only moves a login shell on a versioned Nix store path to the stable one. When the instance enables the `shell` component, `e2e` checks that the Nix profile's zsh is the login shell (`core:login-shell`), so on an adopted machine set it after the rebuild, once the user agrees to the sudo prompt (in their own terminal when the agent shell has none, see the rules of the skill):

```bash
cd "$dir" && ./.dotsteward/cli.sh login-shell set --profile <check profile>
```

Without the `shell` component the command only reports that the instance does not manage the login shell, and `e2e` has no login-shell check.

Before either, tell the user that activation replaces the managed files with links into the generation, and that `./rollback.sh --latest --dry-run` shows what a rollback would undo (`--apply` undoes it). A build failure changes nothing in the home directory; report the failing step from the output.

Preflight exit 3 (the adaptive route) means the machine is off the fast path of `platform-prereqs.md`; the bootstrap stopped before any write. Report the preflight document and do not work around it.
