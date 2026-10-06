# Scope of the expressions evaluated by
# tests/nix/components/opencode-pi/helpers.sh: the core prelude
# (tests/nix/core/prelude.nix) plus the opencode-pi catalog component.
#
#   dir                    modules/components/opencode-pi
#   seed, seedLock         its seed.json and the seed's versions_lock
#   cfgWith ARGS           an instance configuration with the profiles
#                          workstation (adopt) and fresh (fresh) and
#                          opencode-pi enabled; ARGS: systems (default
#                          x86_64-linux and aarch64-darwin), table (extra
#                          [components.opencode-pi] keys, e.g.
#                          method_by_platform)
#   cfg                    cfgWith { }
#   packagesFor SYSTEM PINS
#                          the attributes of the component's package.nix,
#                          evaluated with the package context of mkInstance
#   piFor SYSTEM           the Pi package (derivation) built from the seed
#                          lock
#   home ARGS              the Home Manager configuration (config) with
#                          modules/core and the component, set up like
#                          mkInstance does; ARGS: system, profile, enable,
#                          profiles, pins, config, modules (all optional)
#   component ARGS         (home ARGS).dotsteward.components.opencode-pi
#   hookNames HOOKS        a hook list with each script reduced to its file
#                          name
{
  nixpkgs,
  homeManager,
  repo,
}:
let
  core = import (/. + repo + "/tests/nix/core/prelude.nix") { inherit nixpkgs homeManager repo; };
  inherit (core) lib dsLib;

  dir = core.repoRoot + "/modules/components/opencode-pi";
  seed = builtins.fromJSON (builtins.readFile (dir + "/seed.json"));
  seedLock = seed.versions_lock;

  cfgWith =
    {
      systems ? [
        "x86_64-linux"
        "aarch64-darwin"
      ],
      table ? { },
    }:
    dsLib.config.resolve { catalog = core.testCatalog; } {
      schema_version = 1;
      identity.username = "alice";
      instance.remote = "git@github.com:alice/workstation.git";
      nix = {
        inherit systems;
        state_version = "25.11";
      };
      profiles = {
        names = [
          "workstation"
          "fresh"
        ];
        default = "workstation";
        check = "workstation";
        bootstrap = "fresh";
        workstation.mode = "adopt";
        fresh.mode = "fresh";
      };
      components.opencode-pi = {
        enable = true;
      }
      // table;
    };

  cfg = cfgWith { };

  packagesFor =
    system: pins:
    import (dir + "/package.nix") {
      pkgs = core.pkgsFor system;
      inherit
        pins
        system
        lib
        dsLib
        cfg
        ;
      inputs = { };
      root = core.fixtures + "/instance";
      packages = { };
    };

  piFor = system: (packagesFor system seedLock).pi.package;

  home =
    {
      system ? "x86_64-linux",
      profile ? "workstation",
      enable ? true,
      profiles ? null,
      pins ? seedLock,
      config ? cfg,
      modules ? [ ],
    }:
    let
      platformName = dsLib.platform.platformOf system;
      method = dsLib.config.methodFor config "opencode-pi" platformName;
    in
    core.homeOf {
      inherit config system profile;
      homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/alice" else "/home/alice";
      packages = {
        dotsteward = dsLib.mkCli (core.pkgsFor system);
      }
      // lib.mapAttrs (_: entry: entry.package) (packagesFor system pins);
      modules = [
        (dir + "/default.nix")
        {
          dotsteward.components.opencode-pi = {
            inherit enable;
          }
          // lib.optionalAttrs (profiles != null) { inherit profiles; }
          // lib.optionalAttrs (method != null) { inherit method; };
        }
      ]
      ++ modules;
    };

  component = args: (home args).dotsteward.components.opencode-pi;

  hookNames = map (hook: hook // { script = baseNameOf hook.script; });
in
core
// {
  inherit
    dir
    seed
    seedLock
    cfgWith
    cfg
    packagesFor
    piFor
    home
    component
    hookNames
    ;
}
