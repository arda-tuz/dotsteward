# Core Home Manager modules (tests/nix/core): identity, profiles, nix.conf,
# agent rules, skills, the CLI and its local-maintained-files alias, files,
# components, the login shell, .zshrc blocks and the manifest; plus the
# evaluation of mkNpmBundle. The tests evaluate Home Manager configurations
# with nix-instantiate against an isolated store, so the sandbox needs Nix
# itself and the nixpkgs and home-manager sources; a setup hook exports
# their paths.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-nix-core-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "nix-core";
  paths = [ "tests/nix/core" ];
  nativeBuildInputs = [
    pkgs.nix
    testEnv
  ];
}
