# Component contract

Every component, a catalog one in the framework or a private one in `components/<name>/default.nix` of the instance, is a Home Manager module that sets `dotsteward.components.<name>`. The framework reads the evaluated declarations through the manifest, so the CLI (installer methods, settings engine, probes, hooks, E2E runner, rollback, stage-0) never needs component-specific code. The authoritative option types are `lib/contract.nix` of the framework source; `docs/component-contract.md` and `docs/writing-components.md` there explain them in prose.

## Contents

1. Enabling and scoping
2. Fields by concern
3. Methods
4. Hooks and their environment
5. A private component

## Enabling and scoping

- `[components.<name>]` in `workstation.toml`: `enable`, `source` (`catalog` for catalog names, else `instance`), `method` or `method_by_platform = { linux = "...", darwin = "..." }`, `profiles` (where the component is active; the only profile-scoping mechanism) and `options` (free-form, read by the module as `config.dotsteward.components.<name>.options`).
- `[components] order` decides the order of hooks, checks and the system-install transaction.
- A private component's module receives `pins`, `packages`, `profile`, `dotsteward` (with `lib.pinAt`) and the usual Home Manager arguments. Read lock values with `dotsteward.lib.pinAt pins "<lock path>" "<component>"`, so a missing key names the component.
- Instance packages: `components/<name>/package.nix` returns `{ <attr> = { package = <derivation>; check = true; }; }`; it is called with `pkgs`, `pins`, `inputs`, `system`, `lib`, `packages`, `dsLib` and `root`. `check = true` adds the package to the flake checks.

## Fields by concern

| Concern | Fields |
| --- | --- |
| Platforms and methods | `platforms`, `method` (use `lib.mkDefault` for the component's default), `supportedMethods.linux`, `supportedMethods.darwin` |
| Installation | `install.nix.packages`; `install.official-binary` (`pin`, `asset` per platform, `member`, `dest`, `versionArgv`, `versionRegex`, `policy` `at-least` or `exact`, `verify`); `install.deb` (`pin`, `packageNames`, `architecture`, `verifyAfterInstall`, `apt`); `install.app-archive` (`pin`, `appName`, `dest`); `install.external` (`command`, `versionArgv`, `minimum`). Only the block of the resolved method is read. |
| Pins | `pins.rules` (kinds such as `derive`, `download-pin`, `skills-lock-mirror`, `minimum-version`, `no-literal`), `pins.latest` (row `id` and `adapter`, for example `github-release`, `npm`, `apt-index`, `official-manifest`, `manual`), `pins.resolvedVersions`, `pins.flakeInputs` |
| Settings | `settingsTargets.<name>` (`path` as a home path or per platform, `format` `json`, `toml` or `jsonc`, `createIfMissing`, `createMode`, `backup`, `reload`), `reloadHooks.<name>` (`command`, `timeout`, `env`, `unsetEnv`, `requireCommand`, `onSuccess`, `onFailure`) |
| Checks | `probes` (`command`, `kind` `version`, `presence` or `features`, `argv`, `extract`, `expected` as `versions:<lock path>`, `needles`, `profiles`); `checks.commands` (commands E2E requires); `checks.e2e` (hook scripts with `phase` `early`, `main` or `late`); `checks.agents`; `checks.floors` (`command`, `argv`, `minimum`, `compare`) |
| Machine safety | `bootstrap.backupPaths`, `bootstrap.snapshots`, `bootstrap.prerequisites.apt`; `rebuild.adoptPaths`; `rollback.managedLinks`, `rollback.forceLinkedRestore` |
| Agents | `agentRulesTargets` (home-relative path, `force`), `skillLayout` (`legacyRoots`, `linkRoots`, `excludedSubtrees`) |
| Preflight | `preflight.detectors.<name>` (`argv`, `matchLine`), referenced from `[platform.linux.fast_path] detectors` |
| Updates | `gate.updatePaths` (extended regular expressions added to the update-scope allowlist; never the settings buffer) |
| Docs | `docs` (the component's README; required for catalog components) |

## Methods

| Method | `fresh` profile | `adopt` profile | Check |
| --- | --- | --- | --- |
| `nix` | package in `home.packages` | same | probes |
| `official-binary` | verified download into `dest` (user level); `at-least` keeps a newer self-updated binary | same | version per policy |
| `deb` (Linux) | one verified apt transaction in the system-install phase | not managed | `dpkg` floor |
| `app-archive` (macOS) | verified archive into `~/Applications` | not managed | bundle version |
| `external` | nothing (the user installs it) | same | optional presence and floor |

`dotsteward install --profile <profile> --check-only` checks every method of a profile without installing anything.

## Hooks and their environment

`hooks.preActivate`, `hooks.systemInstall`, `hooks.postInstall`, `hooks.forbid`, `hooks.agentsInstall`, `hooks.agentsMigrate`, `hooks.agentsPost` and `hooks.desktopApply` are lists of `{ name; script; profiles ? null; }`. Scripts are copied into the store and run with `DOTSTEWARD_LIB` (the directory of the framework's `lib.sh` helpers), `DOTSTEWARD_INSTANCE`, `DOTSTEWARD_STATE_ROOT`, `DOTSTEWARD_PROFILE`, `DOTSTEWARD_PROFILE_MODE`, `DOTSTEWARD_PLATFORM`, `DOTSTEWARD_COMPONENT`, `DOTSTEWARD_CHECK_ONLY` (0 or 1) and `DOTSTEWARD_ASSUME_YES`. A hook must be idempotent, must change nothing when `DOTSTEWARD_CHECK_ONLY=1`, and fails its phase with a non-zero exit. `dotsteward component run <name> <hook>` runs one hook by hand with the same environment.

## A private component

A synthetic command `example-term` installed from its official release on Linux and from nixpkgs on macOS, with one settings target and one E2E check:

```nix
# components/example-term/default.nix
{ lib, packages, ... }:
{
  dotsteward.components.example-term = {
    method = lib.mkDefault "official-binary";
    supportedMethods = {
      linux = [ "official-binary" "nix" ];
      darwin = [ "nix" ];
    };
    install = {
      nix.packages = [ packages.example-term ];
      official-binary = {
        pin = "agent_tools.example-term";
        asset = {
          linux = "example-term-{version}-x86_64-linux.tar.gz";
          darwin = "example-term-{version}-aarch64-darwin.tar.gz";
        };
        member = "example-term";
        dest = "~/.local/bin/example-term";
        versionArgv = [ "--version" ];
        versionRegex = "example-term ([0-9.]+)";
        policy = "at-least";
        verify = "sha256";
      };
    };
    settingsTargets.example-term = {
      path = {
        linux = "~/.config/example-term/config.toml";
        darwin = "~/Library/Application Support/example-term/config.toml";
      };
      format = "toml";
      createIfMissing = true;
    };
    checks = {
      commands = [ "example-term" ];
      e2e = [ { name = "example-term-smoke"; script = ./e2e-smoke.sh; } ];
    };
    bootstrap.backupPaths = [ "~/.config/example-term/config.toml" ];
    gate.updatePaths = [ "components/example-term/[^/]+" ];
  };
}
```

Then enable it with `[components.example-term] enable = true` (and `profiles` when it belongs to some profiles only), add `agent_tools.example-term` to `versions.lock.json` with the official URL, size and SHA-256, run `dotsteward sync`, stage everything and run the gate.
