# Writing components

A component makes one application or tool reproducible: how it is installed
on each platform, which versions are pinned and where they come from, which
settings files the user may change locally, what is backed up and rolled
back, and how the result is checked. This page walks through writing one.
[component-contract.md](component-contract.md) lists every option.

The `dotsteward-maintain` skill writes and changes private components for
you and validates the result with the gate; read on to do it by hand or to
review what the skill wrote.

## Private or catalog

- A **private component** lives in your instance, in
  `components/<name>/`. Anything outside the catalog is a private
  component; it is never sent to the framework.
- A **catalog component** lives in this repository, in
  `modules/components/<name>/`, and is shared by every user. The catalog is
  deliberately small (see [catalog.md](catalog.md)); proposing a new one is
  an explicit framework change through [contribute.md](contribute.md).

Both use exactly the same contract.

## Files

| File | Private | Catalog | Content |
| --- | --- | --- | --- |
| `default.nix` | required | required | A Home Manager module that sets `dotsteward.components.<name>` and any ordinary Home Manager options. |
| `package.nix` | optional | optional | Packages built with Nix: a function of `{ pkgs, pins, inputs, system, lib, dsLib, root, cfg, packages }` returning an attribute set. Each value is a derivation, or `{ package = <derivation>; check = true; }` to also build it in `nix flake check`; it joins the package set as `packages.<attribute>`. |
| `README.md` | optional | required | What the component installs, its methods, settings targets and options; set `docs = ./README.md;`. |
| `maintenance.md` | optional | required | How to update its pins: sources of truth, lock entries that move together, exact checks. The update skill reads it. |
| `seed.json` | none | required | The lock entries and flake inputs `dotsteward init` writes into a new instance (`schema/seed.schema.json`). |
| scripts | optional | optional | Hooks and end-to-end checks the module names (`script = ./check.sh;`). |

A catalog component also has a Nix check, `nix/checks/component-<name>.nix`,
and its tests in `tests/nix/components/<name>/`.

## Module arguments

A component module receives the usual Home Manager arguments (`config`,
`lib`, `pkgs`) and:

| Argument | Content |
| --- | --- |
| `pins` | The parsed `versions.lock.json` of the instance. |
| `packages` | The package set of the instance: catalog packages and every `package.nix` attribute. |
| `inputs` | The instance flake inputs. |
| `profile` | The profile being built. Ordinary Home Manager options may depend on it; contract values must not. |
| `username`, `homeDirectory` | The check identity. Activation uses the runtime identity, so never bake these into files that end up on another machine. |
| `dotsteward` | `system`, `cfg` (the evaluated `workstation.toml`), `root` (the instance source) and `lib` (the dotsteward library, including `pinAt`). |

## Step by step

1. **Choose the methods.** Prefer `nix` when nixpkgs or an upstream flake
   provides the tool. Use `official-binary` for a vendor release that
   updates itself, `deb` or `app-archive` for desktop applications that
   need a system install, and `external` when the user installs it. Set
   the default with `method = lib.mkDefault "...";` and list what you
   support in `supportedMethods`.
2. **Pin the versions.** Add the lock entries to `versions.lock.json` with
   the official URL, size and SHA-256 (or the flake input to `flake.nix`).
   Read them in Nix with
   `dotsteward.lib.pinAt pins "<lock path>" "<component>"`; a missing key
   then names the component.
3. **Declare pin rules** in `pins.rules` so `dotsteward pins check` proves
   the lock is consistent, and `pins.latest` so `dotsteward pins latest`
   finds new stable releases ([pins-engine.md](pins-engine.md)).
4. **Declare settings targets** for files the application rewrites itself
   (`settingsTargets`), with a reload hook when a running process must
   re-read the file ([settings-buffer.md](settings-buffer.md)). Never link
   such a file from the Nix store.
5. **Declare checks**: a probe per command (version, presence or
   features), `checks.commands`, and end-to-end hooks for behaviour a
   probe cannot see.
6. **Declare machine safety**: every file the component may replace goes
   into `bootstrap.backupPaths`, `rebuild.adoptPaths` or
   `rollback.managedLinks`, so a rollback restores the machine.
7. **Allow updates**: when a version update changes files beyond the lock
   files, add those paths to `gate.updatePaths`.
8. **Enable it** in `workstation.toml`, stage everything and validate:

   ```sh
   git add -A
   dotsteward sync
   dotsteward pins check
   dotsteward static
   dotsteward gate --scope maintain
   ```

## A minimal private component

A synthetic command `example-term`, installed from its official release on
Linux and from nixpkgs on macOS, with one settings target and one
end-to-end check:

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
    pins.rules = [
      { kind = "download-pin"; at = "agent_tools.example-term"; }
    ];
    pins.latest = [
      {
        id = "agent_tools.example-term";
        adapter = "github-release";
        repo = "example-org/example-term";
      }
    ];
    settingsTargets.example-term = {
      path = {
        linux = "~/.config/example-term/config.toml";
        darwin = "~/Library/Application Support/example-term/config.toml";
      };
      format = "toml";
      createIfMissing = true;
    };
    probes = [ { command = "example-term"; kind = "presence"; } ];
    checks = {
      commands = [ "example-term" ];
      e2e = [ { name = "example-term-smoke"; script = ./e2e-smoke.sh; } ];
    };
    bootstrap.backupPaths = [ "~/.config/example-term/config.toml" ];
    gate.updatePaths = [ "components/example-term/[^/]+" ];
  };
}
```

```toml
# workstation.toml
[components.example-term]
enable = true
```

A new instance carries a fuller annotated example in
`components/example/default.nix.disabled`; the catalog components in
`modules/components/` are real ones to learn from.

## Rules

- Contract values never depend on `profile`; scope with `profiles`.
- No version, URL or hash literal in Nix files: `dotsteward pins check`
  rejects SRI hashes and placeholder hashes in the instance's `flake.nix`,
  `home.nix` and `components/**/*.nix`.
- Nix sees only tracked files: `git add -A` before any Nix command.
- Hook scripts are idempotent and change nothing when
  `DOTSTEWARD_CHECK_ONLY=1`.
- No secrets, account data, caches or machine identifiers in the
  repository; settings keys that look like credentials are refused.
- Catalog components additionally keep framework text generic: English,
  ASCII, no personal data and no application names outside the catalog
  ([privacy.md](privacy.md)).
