# Platforms

dotsteward manages a home directory on two Nix systems:

| System | Machine | Status |
| --- | --- | --- |
| `x86_64-linux` | Ubuntu 24.04 on x86_64 | primary platform: every framework check runs on it, and a fresh machine is installed end to end in CI |
| `aarch64-darwin` | macOS 14 or later on Apple silicon, standalone Home Manager | evaluated on every framework check (`checks.darwin-eval`), run on a real Mac by the macOS smoke workflow |

An instance chooses its systems in `workstation.toml`; the first entry is the
primary system (the one `homeConfigurations.<username>` describes):

```toml
[nix]
systems = ["aarch64-darwin"]                    # a Mac only
# systems = ["x86_64-linux", "aarch64-darwin"]  # one instance, both platforms
```

The running platform is read from the kernel (`uname -s`). The environment
variable `DOTSTEWARD_PLATFORM` (`linux` or `darwin`) overrides it; tests use it
to exercise the other platform's code paths.

## Identity and home

The check identity (`[identity]`) is used only for sandbox builds and checks:
`identity.home` (default `/home/<username>`) on Linux, `identity.darwin_home`
(default `/Users/<username>`) on darwin. At run time dotsteward always uses
`$USER` and `$HOME`, so an instance installs on a machine with another user
name without any edit. User names must match `^[a-z_][a-z0-9_-]*$` on Linux and
`^[A-Za-z_][A-Za-z0-9_.-]*$` (macOS short names) on darwin; `$HOME` must be an
absolute existing directory without whitespace, quotes, `$` or backslash.

## One toolchain on both platforms

Every bash command of the CLI runs with the same tools first on `PATH`: bash,
GNU coreutils, findutils, grep, sed, awk, jq, git, flock, curl and Python
(the CLI package's toolchain). GNU behaviour is therefore identical on macOS;
nothing in the framework depends on the BSD variants. Platform tools come
from the system:

| Platform | System tools dotsteward calls |
| --- | --- |
| Linux | `sudo`, `apt-get`, `dpkg`, `dpkg-query`, `dpkg-deb`, `getent`, `chsh` |
| darwin | `sudo`, `sw_vers`, `dscl`, `xcode-select`, `ditto`, `hdiutil` |

Before Nix exists, `bootstrap.sh` (stage 0) runs with the system's own bash
3.2 and BSD tools on macOS, without `jq`.

## Before Nix: prerequisites and the fast path

`./bootstrap.sh --profile <bootstrap profile>` first runs the read-only
preflight. It compares the machine with the instance's fast path
(`[platform]` in `workstation.toml`):

| Platform | Fast path (defaults) | Facts read |
| --- | --- | --- |
| Linux | `os_id = "ubuntu"`, `os_version = "24.04"`, `architecture = "x86_64"`, plus the optional `desktop_contains` and `detectors` | `/etc/os-release` (parsed, never executed), `uname -m`, `XDG_CURRENT_DESKTOP` |
| darwin | `min_version = "14"`, `architecture = "arm64"` | `sw_vers -productVersion` (at least `min_version`, compared as dotted numbers), `uname -m` |

A machine off the fast path takes the adaptive route (preflight exit 3).

Stage 0 then installs the prerequisites. On Ubuntu these are the base APT
packages and the `bootstrap.prerequisites.apt` of the enabled components, in
one APT transaction. On macOS the only prerequisite is the Xcode Command Line
Tools (they provide `git`); stage 0 checks them and stops with a hint when they
are missing, before any download:

```sh
xcode-select --install
# finish the installation, then run bootstrap again:
./bootstrap.sh --profile fresh
```

The preflight on macOS probes the instance remote only when the Command Line
Tools are installed, since `/usr/bin/git` would otherwise open the installer
dialog.

## Install methods per platform

| Method | Linux | darwin | Level | In an `adopt` profile |
| --- | --- | --- | --- | --- |
| `nix` | yes | yes | user (Home Manager) | installed |
| `official-binary` | yes | yes (its own release asset and pin) | user (`~/.local/bin`) | installed |
| `deb` | yes | no | system (one APT transaction) | not managed |
| `app-archive` | no | yes | system (`~/Applications`) | not managed |
| `external` | yes | yes | nothing is installed | as in `fresh` |

Each component lists the methods it supports per platform, and its default.
An instance picks another one for all platforms with `method`, or per
platform with `method_by_platform`:

```toml
[components.vscode]
enable = true
method_by_platform = { linux = "deb", darwin = "app-archive" }
```

A method the component does not support on a platform of `nix.systems` fails
the evaluation with the supported list. The catalog on darwin:

| Component | darwin default | Also supported on darwin |
| --- | --- | --- |
| `shell` (zsh, starship) | `nix` | |
| `herdr` | `nix` | |
| `claude-code` | `official-binary` (`darwin-arm64` build) | `external` |
| `codex` | `official-binary` (`codex-aarch64-apple-darwin`) | `external` |
| `opencode-pi` | `official-binary` for OpenCode (`opencode-darwin-arm64.zip`); Pi from Nix | `external` |
| `vscode` | `app-archive` (the official `darwin-arm64` archive) | `external` |

Each component's `README.md` (`modules/components/<name>/README.md`) records
its darwin pins, settings paths and what was verified for darwin.

## The app-archive method (darwin)

`app-archive` installs an application bundle from a pinned official archive.
The component's install block names the lock entry, the bundle and the
destination directory:

```nix
install.app-archive = {
  pin = "desktop_packages.vscode-darwin-arm64"; # entry of versions.lock.json
  appName = "Visual Studio Code.app";            # the bundle at the archive's root
  dest = "~/Applications";                       # the default
};
```

The lock entry holds `minimum_version` (or `version`), `url`, `size` and
`sha256`. In a `fresh` profile, `dotsteward install --profile <profile>`
(bootstrap's system-install phase) does this for each `app-archive`
component:

1. Reads the installed version: `CFBundleShortVersionString` of
   `<dest>/<appName>/Contents/Info.plist` (XML or binary property list). When
   it is at least `minimum_version`, nothing happens: applications update
   themselves, and a newer bundle is kept, never downgraded.
2. Downloads the archive over HTTPS only and checks its exact size, then its
   SHA-256, against the lock.
3. Recognises the archive by its content, not by its URL: a zip, or a disk
   image (by its UDIF trailer). A zip is extracted with `ditto`; a disk image
   is attached read-only, without Finder and without opening it, at a mount
   point inside the temporary directory, the bundle is copied out with
   `ditto`, and the image is detached (with `-force` when the first detach
   fails).
4. Checks the bundle: `<appName>` must be a directory at the archive's root,
   and its version must be at least `minimum_version`. Nothing has changed so
   far; any refusal stops here.
5. Moves an existing bundle into a private backup,
   `<state root>/backups/<UTC timestamp>/files/<absolute path>`, then copies
   the new bundle into place with `ditto` (symlinks, modes and extended
   attributes kept) and reads its version again. When the copy fails, the
   partial copy is removed and the previous bundle is moved back.

A symlink or a regular file at `<dest>/<appName>` is never replaced. dotsteward
never answers interactive prompts of a disk image (standard input is closed),
and a volume that cannot be detached is reported with the command to detach
it by hand; its temporary directory is then left in place.

`dotsteward install --profile <profile> --check-only` reports each bundle as
`satisfied` (the installed version is at least `minimum_version`) or `failed`
(missing, without a readable version, or older). In an `adopt` profile the
method is `not-managed`: dotsteward neither installs nor checks the bundle.

The component's pins rules keep the lock entry consistent (`dotsteward pins
check`; VS Code declares a `download-pin` rule on the vendor's
version-addressed URL), and its `latest` declarations let `dotsteward pins
latest` report a newer release (VS Code reads the vendor's update service).

## Settings paths

A component's settings target may name one path for every platform or one per
platform:

```nix
settingsTargets.vscode-settings = {
  path = {
    linux = "~/.config/Code/User/settings.json";
    darwin = "~/Library/Application Support/Code/User/settings.json";
  };
  format = "jsonc";
  createIfMissing = true;
};
```

The evaluation of a system selects its entry; a per-platform table without an
entry for a system of `nix.systems` is an evaluation error. The settings
buffer stores only `~/` paths, so it is the same file on both platforms.

## Login shell

The login shell is the stable profile path `$HOME/.nix-profile/bin/zsh` (a
versioned `/nix/store` path could be removed by garbage collection). Setting
it needs `sudo` on both platforms:

| Step | Linux | darwin |
| --- | --- | --- |
| Read the current shell | `getent passwd <user>` | `dscl . -read /Users/<user> UserShell` |
| List the shell | appended to `/etc/shells` | appended to `/etc/shells` |
| Remove a line this system added | `/etc/shells` rewritten, `root:root`, 0644 | `/etc/shells` rewritten, `root:wheel`, 0644 |
| Set the shell | `chsh -s <path> <user>` | `dscl . -create /Users/<user> UserShell <path>` |
| Shell after `dotsteward rollback` | `/bin/bash` | `/bin/zsh` |

## The platform layer

`cli/lib/lib.sh` loads `cli/lib/platform-linux.sh` or
`cli/lib/platform-darwin.sh` for the running platform. Both provide the same
interface, which the commands and component hooks (they source
`$DOTSTEWARD_LIB/lib.sh`) can use:

| Function | Linux | darwin |
| --- | --- | --- |
| `platform_os_id`, `platform_os_version` | `ID` and `VERSION_ID` of os-release | `macos` and the `sw_vers` product version |
| `platform_architecture` | `uname -m` | `uname -m` |
| `platform_shells_file`, `platform_shells_contains`, `platform_shells_add`, `platform_shells_remove` | `/etc/shells` | `/etc/shells` |
| `platform_login_shell [USER]`, `platform_set_login_shell PATH [USER]` | `getent`, `chsh` | `dscl` |

Linux adds `os_release_value`, the dpkg helpers (`dpkg_installed`,
`dpkg_version`, `dpkg_version_at_least`, `package_provides`, `deb_field`) and
the APT helpers (`apt_update`, `apt_install`). darwin adds `sw_vers_value`,
`xcode_clt_installed`, `require_xcode_clt`, `app_bundle_version BUNDLE` and the
`app-archive` method (`platform_app_archive_check`,
`platform_app_archive_install`). A hook that needs one platform's helpers
checks `DOTSTEWARD_PLATFORM` first.

Tests replace the system facts through injection points, so no test reads the
host's files: `DOTSTEWARD_ETC_SHELLS` (the shells file),
`DOTSTEWARD_OS_RELEASE` (os-release), `DOTSTEWARD_PASSWD_CMD` (a replacement
for the user database lookup; it answers before `getent` or `dscl`) and
`DOTSTEWARD_SW_VERS` (a replacement for `sw_vers`). `DOTSTEWARD_MEMORY_MIB` and
`DOTSTEWARD_CPU_COUNT` replace the memory and CPU count behind the gate's
derived Nix parallelism ([workstation.toml](workstation-toml.md#gate)).

## What is verified where

| What | Linux | darwin |
| --- | --- | --- |
| CLI and platform layer | the framework checks (`nix flake check`) | `checks.darwin-eval` runs the darwin platform tests (`tests/cli/darwin`) on Linux, with the user database, `sudo` and `dscl` stubs and doubles of `ditto` and `hdiutil` |
| Full instance with every catalog component | `checks.template-full` builds every check of the full fixture and runs its probes | `checks.darwin-eval` evaluates every check of the full darwin fixture for `aarch64-darwin` (the activation packages of every profile, the Pi package and the instance checks are instantiated, never built) and runs its instance contract (static with the instance privacy scan, pins check, settings validate) |
| Real machine | the clean-install workflow installs a fresh Ubuntu runner end to end | the macOS smoke workflow (Nix install, `init` with darwin methods, `rebuild`, `e2e` for the catalog) |

Real activation never runs on a developer's machine as part of the tests; it
runs only on CI runners and in virtual machines.
