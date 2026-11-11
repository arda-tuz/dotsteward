# The darwin suites on Linux: the test suites of the checks of nix/darwin-checks.nix, which
# CI `macos-smoke` runs on a Mac only on release tags and nightly, run again on x86_64-linux
# with the platform forced to darwin (DS_TEST_PLATFORM of tests/lib/harness.sh, the CLI's
# DOTSTEWARD_PLATFORM). A fixture that assumes Linux instead of asking the platform the CLI
# sees (the mirror .dotsteward/manifest.x86_64-linux.json written by name, a kernel name read
# with uname) fails here, in every gate, before a release turns `macos-smoke` red. The suites
# are darwinSuites of nix/check-sources.nix (darwin-eval, privacy and skeleton stay out: see
# there), run as their checks run them, without their postCheck (shellcheck, ruff and the
# packaged CLI's own checks are the same on both platforms). What this cannot see is a Mac
# itself: a helper that reads /proc, or a tool only Linux has, still shows only on a Mac.
{
  self,
  pkgs,
  system,
  lib,
  dsLib,
}:
let
  cli = dsLib.mkCli pkgs;
  suites = map (
    name:
    import (./. + "/${name}.nix") {
      inherit
        self
        pkgs
        system
        lib
        dsLib
        ;
    }
  ) (import ../check-sources.nix { inherit lib; }).darwinSuites;
in
cli.mkTestCheck {
  name = "darwin-platform";
  paths = lib.concatMap (suite: suite.paths) suites;
  nativeBuildInputs = lib.unique (lib.concatMap (suite: suite.nativeBuildInputs) suites);
  keepShebangs = lib.unique (lib.concatMap (suite: suite.keepShebangs) suites);
  platform = "darwin";
}
