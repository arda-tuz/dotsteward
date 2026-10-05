# Assembles the framework flake outputs. Checks and catalog components are
# discovered from directories, so adding one never edits this file:
# - every nix/checks/<name>.nix becomes checks.x86_64-linux.<name>; each file
#   is a function { self, pkgs, system, lib, dsLib } -> derivation;
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

  checksFor =
    system:
    lib.listToAttrs (
      map (file: {
        name = lib.removeSuffix ".nix" file;
        value = import (./checks + "/${file}") {
          inherit
            self
            system
            lib
            dsLib
            ;
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

  # Only the Linux sandbox runs checks during development; darwin gets
  # evaluation-safe checks only (none yet).
  checks = {
    x86_64-linux = checksFor "x86_64-linux";
    aarch64-darwin = { };
  };

  # nixfmt in RFC style; nixpkgs now ships it as `nixfmt` (`nixfmt-rfc-style`
  # is a deprecated alias that warns on evaluation).
  formatter = forAllSystems (system: (pkgsFor system).nixfmt);
}
