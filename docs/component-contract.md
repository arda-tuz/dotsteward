# Component contract

Every component, a catalog component in this repository or a private
component in `components/<name>/default.nix` of an instance, is a Home
Manager module that sets `dotsteward.components.<name>`. This page lists
every option of that contract. The authoritative types are in
`lib/contract.nix`; a test keeps this page in step with them.
[writing-components.md](writing-components.md) shows how to write a
component, and [concepts.md](concepts.md#components) explains the idea.

The framework reads the evaluated values through the manifest
(`manifest.json` in every generation, mirrored as
`.dotsteward/manifest.<system>.json` in the instance), so the CLI never
needs code specific to one component.

## Conventions

- Every option has a default except `method`, the fields of an install
  block and the `format` of a settings target. Lists default to `[ ]`,
  attribute sets to `{ }` and nullable options to `null`.
- A **home path** is a `~/...` string. A **host path** is a home path or an
  absolute path. A **lock path** is a dot-separated key path of
  `versions.lock.json`, for example `agent_tools.example-term` (see
  [pins-engine.md](pins-engine.md#lock-paths-and-templates)).
- Contract values never depend on the active profile: one manifest
  describes every profile of a system. Scope a component with `profiles`
  (set from `workstation.toml`) and a hook or probe with its own
  `profiles`.
- A field of a list element or of a named attribute is shown as
  `checks.e2e.*.name` or `settingsTargets.<name>.path`.

## Identity and scope

| Option | Type | Meaning |
| --- | --- | --- |
| `enable` | bool, default `false` | Set by `lib.mkInstance` from `[components.<name>] enable`. |
| `profiles` | null or list of profile names | Profiles where the component is active; `null` means every profile. It is the only way to scope a component to profiles. |
| `platforms` | list of `linux`, `darwin`; default both | Platforms the component supports. |
| `method` | one of the install methods | The resolved method: `method_by_platform` of the instance, then `method`, then the component default (set it with `lib.mkDefault`). |
| `supportedMethods` | `{ linux; darwin; }` | The methods the component implements on each platform. |
| `supportedMethods.linux` | list of methods | Methods on Linux. |
| `supportedMethods.darwin` | list of methods | Methods on macOS. |
| `options` | attribute set | `[components.<name>].options` of `workstation.toml`, set by `lib.mkInstance`. The module validates its own options. |
| `docs` | null or path | The component's `README.md`; required for catalog components. |

## Installation

`install` holds one block per method. Only the block of the resolved
`method` is read, so the other blocks may stay empty.

| Option | Type | Meaning |
| --- | --- | --- |
| `install` | attribute set of blocks | The install blocks. |
| `install.nix` | block | Method `nix`. |
| `install.nix.packages` | list of packages | Added to `home.packages`. |
| `install.official-binary` | block | Method `official-binary`: a vendor release downloaded into the home directory. |
| `install.official-binary.pin` | lock path | The release object: version, URL, size and SHA-256. |
| `install.official-binary.asset` | `{ linux; darwin; }` | Release asset name template per platform. |
| `install.official-binary.asset.linux` | string | Asset on Linux. |
| `install.official-binary.asset.darwin` | string | Asset on macOS. |
| `install.official-binary.member` | string | The archive member to install. |
| `install.official-binary.dest` | home path | The destination, usually `~/.local/bin/<command>`. A symlink there is an error. |
| `install.official-binary.versionArgv` | list of strings | Arguments that print the version. |
| `install.official-binary.versionRegex` | string | Regular expression whose first group is the version. |
| `install.official-binary.policy` | `at-least` or `exact` | `at-least` keeps a newer binary the application installed itself. |
| `install.official-binary.verify` | `sha256` or `sha256+sigstore` | Download verification. |
| `install.deb` | block | Method `deb` (Ubuntu, system level). |
| `install.deb.pin` | null or lock path | The DEB download with its minimum version; `null` installs plain APT packages only. |
| `install.deb.packageNames` | list of strings | Package names (aliases allowed) asserted in the downloaded DEB. |
| `install.deb.architecture` | null or string | The architecture asserted in the DEB. |
| `install.deb.verifyAfterInstall` | bool, default `true` | Check the version floor after installing. |
| `install.deb.apt` | list of strings | Plain APT packages installed in the same transaction. |
| `install.app-archive` | block | Method `app-archive` (macOS, system level). |
| `install.app-archive.pin` | lock path | The archive download. |
| `install.app-archive.appName` | string | The application bundle name. |
| `install.app-archive.dest` | home path, default `~/Applications` | The destination directory. |
| `install.external` | block | Method `external`: installed by something else. |
| `install.external.command` | null or string | A command expected on `PATH`. |
| `install.external.versionArgv` | null or list of strings | Arguments that print the version. |
| `install.external.minimum` | null or lock path | The minimum version. |

### Method semantics

| Method | `fresh` profile | `adopt` profile | `dotsteward install --check-only` |
| --- | --- | --- | --- |
| `nix` | the packages join `home.packages` | same | the probes cover it |
| `official-binary` | verified download (HTTPS, size, SHA-256, optional sigstore), the member installed with mode 0755 into `dest`, version re-checked | same (user level) | version per `policy`, else exit 1 with a rebuild hint |
| `deb` | one APT transaction: verified DEBs only where the installed version is below the floor, never a downgrade, then the floors re-checked | `not-managed` | `dpkg --compare-versions` against the floor |
| `app-archive` | verified zip or disk image into `dest`; an existing bundle is backed up first | `not-managed` | `CFBundleShortVersionString` of the bundle |
| `external` | nothing | nothing | optional presence and floor |

The system-install transaction installs the `deb` components in the order
of `[components] order`.

## Pins

| Option | Type | Meaning |
| --- | --- | --- |
| `pins` | attribute set | Contributions to the pins engine. |
| `pins.rules` | list of rules | Consistency rules of `dotsteward pins check` and `pins sync`. Each rule has a `kind`; the other fields depend on it. |
| `pins.rules.*.kind` | rule kind | One of the kinds of [pins-engine.md](pins-engine.md#rule-kinds). |
| `pins.latest` | list of declarations | Sources of `dotsteward pins latest`. |
| `pins.latest.*.id` | string | The report row id, for example `agent_tools.<name>`. |
| `pins.latest.*.adapter` | adapter name | One of the adapters of [pins-engine.md](pins-engine.md#latest-adapters); the other fields depend on it. |
| `pins.resolvedVersions` | attribute set of strings | Versions Nix resolves, contributed to `lib.pinnedVersions` and compared with `nix_packages.<name>.resolved`. |
| `pins.flakeInputs` | list of strings | Instance flake inputs the component needs. |

Versions, URLs and hashes are read from the lock with
`dotsteward.lib.pinAt pins "<lock path>" "<component>"`, never written into
Nix files.

## Settings

Settings targets are files the application rewrites itself. The settings
engine synchronizes the tracked entries of each target; Home Manager never
links them. [settings-buffer.md](settings-buffer.md) describes the engine.

| Option | Type | Meaning |
| --- | --- | --- |
| `settingsTargets` | attribute set of targets | Targets by name; the name is part of every entry's identity, so keep it stable. |
| `settingsTargets.<name>.path` | home path or `{ linux; darwin; }` | The file, the same on both platforms or one per platform. |
| `settingsTargets.<name>.format` | `json`, `toml` or `jsonc` | The file format. A JSONC file with comments or trailing commas is never rewritten. |
| `settingsTargets.<name>.createIfMissing` | bool | Create the file when an entry applies and the file is missing; otherwise the entry stays `deferred`. |
| `settingsTargets.<name>.createMode` | file mode, default `0644` | Mode of a created file. |
| `settingsTargets.<name>.backup` | bool, default `true` | Back up the file before the first write and in the first bootstrap. Use `false` for files that hold account data. |
| `settingsTargets.<name>.reload` | null, a `reloadHooks` name or an inline hook | Runs once after a write to the file. |
| `reloadHooks` | attribute set of hooks | Named reload hooks. |
| `reloadHooks.<name>.command` | list of strings | The argv; `{home}` expands to the home directory. |
| `reloadHooks.<name>.timeout` | positive integer, default `15` | Seconds before the reload is abandoned with a warning. |
| `reloadHooks.<name>.env` | attribute set of strings | Environment variables set for the command. |
| `reloadHooks.<name>.unsetEnv` | list of strings | Environment variables removed for the command. |
| `reloadHooks.<name>.requireCommand` | null or string | Skip the reload when this command is missing. |
| `reloadHooks.<name>.onSuccess` | `log` or `silent`, default `silent` | Report a successful reload. |
| `reloadHooks.<name>.onFailure` | `warn` or `silent`, default `warn` | Report a failed reload. |

## Probes and checks

Probes run in the gate on the check profile's generation and in
`dotsteward probes`; checks run in `dotsteward e2e` and
`dotsteward agents check`.

| Option | Type | Meaning |
| --- | --- | --- |
| `probes` | list of probes | CLI probes. |
| `probes.*.command` | string | The command under test, looked up on `PATH`. |
| `probes.*.kind` | `version`, `presence` or `features` | `version`: the extracted version equals `expected`; `presence`: the command exits 0; `features`: the output contains every needle. |
| `probes.*.argv` | list of strings, default `[ "--version" ]` | Arguments. |
| `probes.*.env` | attribute set of strings | Environment variables. |
| `probes.*.extract` | extractor, default `first-line` | `first-line`, `field:<label>`, `prefix:<text>`, `printf-vd` or `regex:<re>`. |
| `probes.*.expected` | null or reference | `versions:<lock path>` or `skills:<skills lock path>`. |
| `probes.*.needles` | list of strings | Strings the output must contain (`features`). |
| `probes.*.profiles` | null or list of profile names | Profiles where the probe runs. |
| `checks` | attribute set | Check contributions. |
| `checks.commands` | list of strings | Commands the end-to-end checks require on `PATH`. |
| `checks.e2e` | list of hooks | End-to-end hook scripts. |
| `checks.agents` | list of hooks | Discovery steps of `dotsteward agents check`. |
| `checks.floors` | list of floors | Minimum versions of installed commands. |
| `checks.floors.*.command` | string | The command whose version is checked. |
| `checks.floors.*.argv` | list of strings | Arguments that print the version. |
| `checks.floors.*.minimum` | string | The minimum version, or the lock path that holds it. |
| `checks.floors.*.compare` | `dpkg` or `semver` | How versions compare. |

## Hooks

A hook is `{ name; script; profiles ? null; phase ? "main"; }`:

| Field | Meaning |
| --- | --- |
| `name` | Unique within the component and the list. |
| `script` | An executable in the component directory (`./check.sh`); it is copied into the Nix store. |
| `profiles` | Profiles where the hook runs; `null` means every profile. |
| `phase` | `early`, `main` or `late`; the order of the end-to-end checks (`checks.e2e` only). |

| Option | When the hooks run |
| --- | --- |
| `hooks` | The phase hooks below. |
| `hooks.preActivate` | `rebuild`, after the build and before activation. |
| `hooks.systemInstall` | First bootstrap (`fresh` profile), after the generic DEB and APT transaction. |
| `hooks.postInstall` | First bootstrap (`fresh` profile), after `systemInstall`. |
| `hooks.forbid` | First bootstrap (`fresh` profile), guards that refuse an unsupported machine. |
| `hooks.agentsInstall` | Agents phase, before the skill layout. |
| `hooks.agentsMigrate` | Agents phase, after stale skill links are swept. |
| `hooks.agentsPost` | Agents phase, before validation. |
| `hooks.desktopApply` | First bootstrap (`fresh` profile), after the login shell is set. |

A hook script runs with `DOTSTEWARD_LIB` (the directory of the framework's
shell helpers), `DOTSTEWARD_INSTANCE`, `DOTSTEWARD_STATE_ROOT`,
`DOTSTEWARD_PROFILE`, `DOTSTEWARD_PROFILE_MODE`, `DOTSTEWARD_PLATFORM`,
`DOTSTEWARD_COMPONENT`, `DOTSTEWARD_CHECK_ONLY` (`0` or `1`) and
`DOTSTEWARD_ASSUME_YES`. It must be idempotent, change nothing when
`DOTSTEWARD_CHECK_ONLY=1`, and fail its phase with a non-zero exit status.
`dotsteward component run <name> <hook>` runs one hook by hand with the
same environment.

## Machine safety

| Option | Type | Meaning |
| --- | --- | --- |
| `bootstrap` | attribute set | Contributions to the first bootstrap (stage 0). |
| `bootstrap.backupPaths` | list of host paths | Files backed up before anything changes. |
| `bootstrap.snapshots` | list of snapshots | Command outputs saved before anything changes. |
| `bootstrap.snapshots.*.name` | string | The snapshot name. |
| `bootstrap.snapshots.*.argv` | list of strings | The command whose output is saved. |
| `bootstrap.snapshots.*.requireCommand` | null or string | Skip the snapshot when this command is missing. |
| `bootstrap.prerequisites` | attribute set | Packages installed before Nix. |
| `bootstrap.prerequisites.apt` | list of strings | APT packages installed before Nix (Ubuntu). |
| `rebuild` | attribute set | Rebuild contributions. |
| `rebuild.adoptPaths` | list of host paths | Existing files that activation may replace; they are backed up first. |
| `rollback` | attribute set | Rollback contributions. |
| `rollback.managedLinks` | list of host paths | Home Manager links that `dotsteward rollback` checks and removes. |
| `rollback.forceLinkedRestore` | list of restores | Files that rollback restores as regular files. |
| `rollback.forceLinkedRestore.*.path` | host path | The file. |
| `rollback.forceLinkedRestore.*.mode` | file mode, default `0664` | Its mode after the restore. |
| `preflight` | attribute set | Preflight contributions. |
| `preflight.detectors` | attribute set of detectors | Named detectors that `[platform.linux.fast_path] detectors` may reference. |
| `preflight.detectors.<name>.argv` | list of strings | The detector command. |
| `preflight.detectors.<name>.matchLine` | string | The output line that means "detected". |

## Agents

| Option | Type | Meaning |
| --- | --- | --- |
| `agentRulesTargets` | list of targets | Where the instance's agent rules file is linked. |
| `agentRulesTargets.*.path` | path relative to the home directory | The link. |
| `agentRulesTargets.*.force` | bool, default `false` | Replace an existing file. |
| `skillLayout` | attribute set | How the agents installer lays out skills. |
| `skillLayout.legacyRoots` | list of host paths | Old skill roots that are searched and swept. |
| `skillLayout.linkRoots` | attribute set | Skill link roots by path. |
| `skillLayout.linkRoots.<name>.targetPrefix` | string | The relative link target prefix of that root. |
| `skillLayout.excludedSubtrees` | list of strings | Subtrees the installer never touches. |

## Updates

| Option | Type | Meaning |
| --- | --- | --- |
| `gate` | attribute set | Gate contributions. |
| `gate.updatePaths` | list of extended regular expressions | Paths an update-scope transaction may change for this component (see [update-policy.md](update-policy.md)). They never match the settings buffer. |
