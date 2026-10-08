# The claude-code catalog component (tests/nix/components/claude-code): its
# contract values in an instance that enables it (manifest and Home Manager
# configuration on both systems, every method), the seed (schema, lock
# paths, well-formed pins), the declared pins run by `dotsteward pins
# check` on an instance that merged the seed, the install block driven
# through the official-binary method of the CLI, the plugins option (its
# validation, review rows and hook, end to end through the CLI against the
# claude stub) and the README verification record.
# Fixture instances are evaluated with nix-instantiate against an isolated
# store, so the sandbox needs Nix and the nixpkgs and home-manager sources;
# a setup hook exports their paths. shellcheck covers the plugins hook and
# the tests.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-claude-code-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "component-claude-code";
  paths = [ "tests/nix/components/claude-code" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    shellcheck -x modules/components/claude-code/plugins.sh tests/nix/components/claude-code/*.sh
  '';
}
