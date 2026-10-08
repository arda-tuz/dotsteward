# `dotsteward init`: tests/instance/init in
# the build sandbox. The Nix steps of init run against the nix stub, whose
# override (tests/instance/init/fake-nix.sh) locks the composed instance
# offline and evaluates it with lib.mkInstance of the framework under test
# against an isolated store, so every run ends as a real instance that
# passes the instance contract. One test runs init from the packaged CLI
# built here (DS_INIT_PACKAGED_CLI), as `nix run <framework>#dotsteward --
# init` does. Then ShellCheck over the command and the tests, and a lint of
# the Python module.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-init-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
      export DS_INIT_PACKAGED_CLI=${cli}/bin/dotsteward
    '';
  };
in
cli.mkTestCheck {
  name = "init";
  paths = [ "tests/instance/init" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    pkgs.ruff
    testEnv
  ];
  postCheck = ''
    shellcheck -x cli/commands/init.sh tests/instance/init/*.sh
    module=cli/python/dotsteward_cli/init.py
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF "$module"
    ruff format --no-cache --quiet --check --line-length 120 "$module"
  '';
}
