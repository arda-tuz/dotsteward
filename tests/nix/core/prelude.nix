# Scope of the expressions evaluated by tests/nix/core/helpers.sh.
#
# nixpkgs, homeManager and repo are absolute paths passed as strings
# (--argstr). The scope provides:
#   lib, dsLib, fixtures, testCatalog, repoRoot (the framework checkout path)
#   pkgsFor SYSTEM          nixpkgs for SYSTEM (no overlays, empty config)
#   loadToml NAME           fixtures/NAME.toml loaded with the test catalog
#   mkHome { ... }          a Home Manager configuration with modules/core,
#                           built the way mkInstance builds it (3.2 step 5)
#   homeOf ARGS             (mkHome ARGS).config; Home Manager fails the
#                           evaluation with "Failed assertions:" and the
#                           messages when an assertion fails
#   componentModules        fixtures/components.nix (synthetic components)
#   packageNames CONFIG     lib.getName of every home.packages entry
{
  nixpkgs,
  homeManager,
  repo,
}:
let
  nixpkgsPath = /. + nixpkgs;
  homeManagerPath = /. + homeManager;
  repoPath = /. + repo;

  lib = import (nixpkgsPath + "/lib");

  hmLib = import (homeManagerPath + "/lib") { inherit lib; };

  dsLib = import (repoPath + "/lib") {
    dotsteward = repoPath;
    nixpkgs = {
      inherit lib;
      outPath = nixpkgsPath;
    };
    home-manager = {
      lib = hmLib;
      outPath = homeManagerPath;
    };
  };

  fixtures = repoPath + "/tests/nix/core/fixtures";

  testCatalog = [
    "shell"
    "herdr"
    "claude-code"
    "codex"
    "opencode-pi"
    "vscode"
  ];

  pkgsFor =
    system:
    import nixpkgsPath {
      inherit system;
      config = { };
      overlays = [ ];
    };

  loadToml =
    name:
    dsLib.config.loadWith {
      catalog = testCatalog;
      instanceName = "workstation";
    } (fixtures + "/${name}.toml");

  # The arguments mkInstance passes (3.2 step 5): specialArgs inputs, pins,
  # profile, username, homeDirectory, packages and dotsteward = { cfg, root,
  # system, lib }; modules = [ core ] ++ component modules ++ extra modules.
  mkHome =
    {
      config ? "minimal",
      system ? "x86_64-linux",
      profile ? null,
      username ? "alice",
      homeDirectory ? "/home/alice",
      modules ? [ ],
      packages ? null,
      root ? fixtures + "/instance",
      dotstewardExtra ? { },
    }:
    let
      cfg = if builtins.isAttrs config then config else loadToml config;
      pkgs = pkgsFor system;
    in
    hmLib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inputs = { };
        pins = { };
        profile = if profile == null then cfg.profiles.default else profile;
        inherit username homeDirectory;
        packages = if packages == null then { dotsteward = dsLib.mkCli pkgs; } else packages;
        dotsteward = {
          inherit cfg root system;
          lib = dsLib;
        }
        // dotstewardExtra;
      };
      modules = [ (repoPath + "/modules/core") ] ++ modules;
    };
in
{
  inherit
    lib
    dsLib
    fixtures
    testCatalog
    pkgsFor
    loadToml
    mkHome
    ;

  repoRoot = repoPath;

  homeOf = args: (mkHome args).config;

  # The synthetic components of fixtures/components.nix.
  componentModules = [ (fixtures + "/components.nix") ];

  # Names (lib.getName) of home.packages.
  packageNames = config: map lib.getName config.home.packages;
}
