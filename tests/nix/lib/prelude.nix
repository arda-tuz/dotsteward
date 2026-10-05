# Scope of the expressions evaluated by tests/nix/lib/helpers.sh.
#
# nixpkgs and repo are absolute paths passed as strings (--argstr), so paths
# with any characters work.
{ nixpkgs, repo }:
let
  nixpkgsPath = /. + nixpkgs;
  repoPath = /. + repo;

  lib = import (nixpkgsPath + "/lib");

  dsLib = import (repoPath + "/lib") {
    dotsteward = repoPath;
    nixpkgs = {
      inherit lib;
      outPath = nixpkgsPath;
    };
    home-manager = null;
  };

  fixtures = repoPath + "/tests/nix/lib/fixtures";

  # The catalog used by the configuration tests: the six public catalog
  # names, independent of which catalog directories exist in this tree.
  testCatalog = [
    "shell"
    "herdr"
    "claude-code"
    "codex"
    "opencode-pi"
    "vscode"
  ];

  toPath = file: if builtins.isPath file then file else /. + file;
in
{
  inherit
    lib
    dsLib
    fixtures
    testCatalog
    ;

  # loadToml FILE: loads a workstation.toml (path or absolute path string)
  # with the test catalog.
  loadToml = file: dsLib.config.loadWith { catalog = testCatalog; } (toPath file);

  # loadFixture NAME: loads fixtures/NAME.toml with the test catalog.
  loadFixture = name: dsLib.config.loadWith { catalog = testCatalog; } (fixtures + "/${name}.toml");

  # errorsOfToml FILE: validation messages of a workstation.toml, no throw.
  errorsOfToml =
    file:
    dsLib.config.errors { catalog = testCatalog; } (
      builtins.fromTOML (builtins.readFile (toPath file))
    );

  # evalComponents MODULES: evaluates the component contract option
  # (dotsteward.components) with MODULES and returns its value.
  evalComponents =
    modules:
    (lib.evalModules {
      modules = [ { options.dotsteward.components = dsLib.contract.componentsOption; } ] ++ modules;
    }).config.dotsteward.components;
}
