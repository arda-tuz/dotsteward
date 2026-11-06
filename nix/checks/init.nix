# `dotsteward init`: tests/instance/init in
# the build sandbox. The Nix steps of init run against the nix stub, whose
# override (tests/instance/init/fake-nix.sh) locks the composed instance
# offline and evaluates it with lib.mkInstance of the framework under test
# against an isolated store, so every run ends as a real instance that
# passes the instance contract. One test runs init from the packaged CLI
# built here (DS_INIT_PACKAGED_CLI), as `nix run <framework>#dotsteward --
# init` does. Then ShellCheck over the command and the tests.
#
# The suite is the longest of the framework, so its test files run as two
# halves (in file name order), two derivations that Nix builds in parallel;
# the check passes when both do.
{
  self,
  pkgs,
  lib,
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

  testFiles = lib.sort lib.lessThan (
    lib.attrNames (
      lib.filterAttrs (
        name: type: type == "regular" && lib.hasPrefix "test-" name && lib.hasSuffix ".sh" name
      ) (builtins.readDir ../../tests/instance/init)
    )
  );
  half = (lib.length testFiles + 1) / 2;

  part =
    name: files: postCheck:
    cli.mkTestCheck {
      name = "init-${name}";
      source = "init";
      paths = map (file: "tests/instance/init/${file}") files;
      nativeBuildInputs = [
        pkgs.nix
        pkgs.shellcheck
        testEnv
      ];
      inherit postCheck;
    };

  first = part "1" (lib.take half testFiles) ''
    shellcheck -x cli/commands/init.sh tests/instance/init/*.sh
  '';
  second = part "2" (lib.drop half testFiles) "";
in
pkgs.runCommand "dotsteward-check-init" { } ''
  echo "both halves of tests/instance/init passed: ${first} ${second}"
  touch "$out"
''
