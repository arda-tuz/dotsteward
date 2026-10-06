# Scope of the expressions evaluated by tests/nix/instance/helpers.sh.
#
# nixpkgs, homeManager and repo are absolute paths passed as strings
# (--argstr); repo is the framework checkout under test (a temporary copy in
# the catalog tests). The scope provides:
#   lib, dsLib, manifestLib (lib/manifest.nix on its own),
#   fixtures (tests/nix/instance/fixtures),
#   minimalRoot (tests/fixtures/instances/minimal),
#   exampleRoot (fixtures/example), repoRoot
#   nixpkgsInput, homeManagerInput  flake-input stand-ins (outPath, lib)
#   inputsFor ROOT          { self, nixpkgs, home-manager, dotsteward } with
#                           follows in place
#   instance ARGS           lib.mkInstance of ARGS; ARGS takes root (default
#                           exampleRoot), case (a fixtures/cases/<name>.toml
#                           used as config), inputs (merged over inputsFor
#                           root) and every other mkInstance argument
#   example, minimal        instance { } and instance { root = minimalRoot; }
#   homeOf INSTANCE SYSTEM PROFILE
#                           the Home Manager config of the check identity
#   storeless VALUE         VALUE with string contexts discarded (JSON output)
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

  nixpkgsInput = {
    outPath = nixpkgs;
    inherit lib;
  };

  homeManagerInput = {
    outPath = homeManager;
    lib = hmLib;
  };

  dsLib = import (repoPath + "/lib") {
    dotsteward = repoPath;
    nixpkgs = nixpkgsInput;
    home-manager = homeManagerInput;
  };

  # lib/manifest.nix on its own: mirror and stage-0 rendering.
  manifestLib = import (repoPath + "/lib/manifest.nix") {
    dotsteward = repoPath;
    nixpkgs = nixpkgsInput;
    home-manager = homeManagerInput;
    inherit lib dsLib;
  };

  fixtures = repoPath + "/tests/nix/instance/fixtures";
  minimalRoot = repoPath + "/tests/fixtures/instances/minimal";
  exampleRoot = fixtures + "/example";

  storeless =
    value:
    if builtins.isString value then
      builtins.unsafeDiscardStringContext value
    else if builtins.isList value then
      map storeless value
    else if builtins.isAttrs value then
      builtins.mapAttrs (_: storeless) value
    else
      value;

  inputsFor = root: {
    self = root;
    nixpkgs = nixpkgsInput;
    home-manager = homeManagerInput;
    dotsteward = {
      outPath = repo;
      inputs = {
        nixpkgs = nixpkgsInput;
        home-manager = homeManagerInput;
      };
    };
  };

  instance =
    args:
    let
      root = args.root or exampleRoot;
      caseConfig = lib.optionalAttrs (args ? case) { config = fixtures + "/cases/${args.case}.toml"; };
    in
    dsLib.mkInstance (
      removeAttrs args [
        "case"
        "inputs"
      ]
      // caseConfig
      // {
        inherit root;
        inputs = inputsFor root // args.inputs or { };
      }
    );
in
{
  inherit
    lib
    dsLib
    manifestLib
    fixtures
    minimalRoot
    exampleRoot
    nixpkgsInput
    homeManagerInput
    inputsFor
    instance
    storeless
    ;

  repoRoot = repoPath;

  example = instance { };
  minimal = instance { root = minimalRoot; };

  homeOf =
    inst: system: profile:
    (inst.lib.mkHome {
      username = "alice";
      homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/alice" else "/home/alice";
      inherit profile system;
    }).config;
}
