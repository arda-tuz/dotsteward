# Assembles the framework flake outputs. Checks and catalog components are
# discovered from directories, so adding one never edits this file:
# - every nix/checks/<name>.nix becomes checks.x86_64-linux.<name>; each file
#   is a function { self, pkgs, system, lib, dsLib } -> derivation, where
#   self and dsLib are the checks' view without the commit (checkSelf); the
#   ones listed in darwinChecks below are checks.aarch64-darwin.<name> as well;
# - every directory of modules/components/ is a catalog component
#   (lib.catalog, homeModules.<name>).
inputs@{
  self,
  nixpkgs,
  home-manager,
  ...
}:
let
  inherit (nixpkgs) lib;

  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];
  forAllSystems = lib.genAttrs systems;
  pkgsFor = system: nixpkgs.legacyPackages.${system};

  dsLib = import ../lib {
    dotsteward = self;
    inherit (inputs) nixpkgs home-manager;
  };

  # What the checks see of the framework: self without the attributes that
  # name the fetched source rather than its files (the revision, the narHash
  # and the modification time), and a library built from that view. The CLI
  # the checks build has no source-info and the manifests of their fixture
  # instances no framework revision, so every check depends on the tree
  # alone: two commits with the same tree have the same checks, and an
  # empty, amended or rebased commit rebuilds none of them.
  # packages.<system>.dotsteward keeps the revision and narHash.
  checkSelf = builtins.removeAttrs self [
    "rev"
    "shortRev"
    "dirtyRev"
    "dirtyShortRev"
    "narHash"
    "lastModified"
    "lastModifiedDate"
    "revCount"
    "sourceInfo"
  ];
  checkLib = import ../lib {
    dotsteward = checkSelf;
    inherit (inputs) nixpkgs home-manager;
  };

  checkFiles =
    if builtins.pathExists ./checks then
      lib.sort lib.lessThan (
        lib.attrNames (
          lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
            builtins.readDir ./checks
          )
        )
      )
    else
      [ ];

  # The checks that also run on a Mac (built by the checks job of
  # .github/workflows/macos-smoke.yml on release tags and nightly): their
  # tests are platform independent and mean something on darwin, and their
  # definitions build nothing for Linux. The others stay Linux-only: they
  # build x86_64-linux generations, need Linux tools (APT, dpkg, the bash
  # 3.2 build of the stage-0 tests) or test the Linux platform layer.
  darwinChecks = [
    "darwin-eval" # the darwin platform layer and the darwin instance contract, natively
    "harness" # the stubs and helpers that every test check runs on
    "privacy" # the scanner behind the pre-push hook and contribute check
    "settings" # the settings engine in a darwin home
    "settings-jsonc" # the JSONC reader of the settings engine
    "skeleton" # the dispatcher and the packaged CLI with its darwin toolchain
  ];

  checksFor =
    system:
    lib.listToAttrs (
      map (file: {
        name = lib.removeSuffix ".nix" file;
        value = import (./checks + "/${file}") {
          inherit system lib;
          self = checkSelf;
          dsLib = checkLib;
          pkgs = pkgsFor system;
        };
      }) checkFiles
    );
in
{
  lib = dsLib;

  homeModules =
    lib.optionalAttrs (builtins.pathExists ../modules/core) { core = ../modules/core; }
    // dsLib.catalog;

  templates = lib.optionalAttrs (builtins.pathExists ../template) {
    default = {
      path = ../template;
      description = "dotsteward instance";
    };
  };

  packages = forAllSystems (
    system:
    let
      cli = dsLib.mkCli (pkgsFor system);
    in
    {
      dotsteward = cli;
      default = cli;
    }
  );

  apps = forAllSystems (system: {
    default = {
      type = "app";
      program = lib.getExe self.packages.${system}.dotsteward;
      meta.description = "dotsteward command line interface";
    };
  });

  # Every check runs on x86_64-linux; aarch64-darwin gets darwinChecks.
  checks = {
    x86_64-linux = checksFor "x86_64-linux";
    aarch64-darwin = lib.getAttrs darwinChecks (checksFor "aarch64-darwin");
  };

  # nixfmt in RFC style; nixpkgs now ships it as `nixfmt` (`nixfmt-rfc-style`
  # is a deprecated alias that warns on evaluation).
  formatter = forAllSystems (system: (pkgsFor system).nixfmt);
}
