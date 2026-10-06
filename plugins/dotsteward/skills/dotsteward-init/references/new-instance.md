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

## Installing Nix

Only when `command -v nix` finds nothing, and only after the user agrees. The release's `template/bootstrap.sh --install-nix-only` reads the installer pin (URL, size, SHA-256 and the expected Nix version) from the `versions.lock.json` beside it, downloads the installer over HTTPS, refuses it on any size or digest difference, runs the official multi-user installer (which asks for sudo and creates the Nix daemon), and checks `nix --version` against the pin. It does nothing else: no backups, no packages, no instance.

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

`gh repo create` with `--source` adds the remote `origin` in the protocol of `gh config get git_protocol` and pushes `main`. Afterwards the remote must be byte-equal to the `--remote` given to `init`, because the gate, the publish steps and the end-to-end checks compare `instance.remote` with `git remote get-url origin`:

```bash
test "$(git -C "$dir" remote get-url origin)" = "$remote" || git -C "$dir" remote set-url origin "$remote"
```

Kept local on request: add the remote now, so that the instance and its clone agree:

```bash
git -C "$dir" remote add origin "$remote"
```

When the user wants it published later, create the empty private repository and push:

```bash
gh repo create "OWNER/NAME" --private
git -C "$dir" push -u origin main
```

Until the push, the `core:repo-remote` check of `e2e` fails (the remote is unreachable or differs); every other check works.

## Setting up the machine

| Machine | Command | Profile mode | What happens |
| --- | --- | --- | --- |
| Fresh (no Nix, no applications) | `./bootstrap.sh --profile <bootstrap profile>` | fresh | preflight, backups, prerequisites, verified Nix, system packages, activation, login shell, end-to-end checks |
| Already set up (Nix present) | `./rebuild.sh --profile <check profile> --switch` | adopt | build, activation of the user-level parts, settings, agent tools; system packages are reported as not managed |

The rebuild sets no login shell: it only moves a login shell on a versioned Nix store path to the stable one. When the instance enables the `shell` component, `e2e` checks that the Nix profile's zsh is the login shell (`core:login-shell`), so on an adopted machine set it after the rebuild, once the user agrees to the sudo prompt:

```bash
cd "$dir" && ./.dotsteward/cli.sh login-shell set --profile <check profile>
```

Without the `shell` component the command only reports that the instance does not manage the login shell, and `e2e` has no login-shell check.

Before either, tell the user that activation replaces the managed files with links into the generation, and that `./rollback.sh --latest --dry-run` shows what a rollback would undo (`--apply` undoes it). A build failure changes nothing in the home directory; report the failing step from the output.

Preflight exit 3 (the adaptive route) means the machine is off the fast path of `platform-prereqs.md`; the bootstrap stopped before any write. Report the preflight document and do not work around it.
