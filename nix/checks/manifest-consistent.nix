# D20: an instance's checks.<system>.manifest-consistent passes when the
# manifest of every profile equals the check profile's and fails at
# evaluation when a contract option depends on the profile. The consistent
# fixture instances' checks are built (evaluated inside this flake); the
# violating one must fail (builtins.tryEval); the messages are checked by
# tests/nix/instance/consistency with nix-instantiate.
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
    name = "dotsteward-manifest-consistent-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };

  fixtures = import ../../tests/nix/instance/flake-instances.nix { inherit self dsLib lib; };
  inherit (fixtures) instance minimal example;

  violation = instance {
    homeModules = [
      (
        { profile, ... }:
        {
          dotsteward.components.example-app.checks.commands = lib.mkIf (profile == "fresh") [
            "fresh-only"
          ];
        }
      )
    ];
  };

  violationCaught =
    !(builtins.tryEval violation.checks.x86_64-linux.manifest-consistent.drvPath).success
    && !(builtins.tryEval violation.checks.aarch64-darwin.manifest-consistent.drvPath).success;
in
if !violationCaught then
  throw "manifest-consistent: a profile-dependent contract option was not detected"
else
  cli.mkTestCheck {
    name = "manifest-consistent";
    paths = [ "tests/nix/instance/consistency" ];
    nativeBuildInputs = [
      pkgs.nix
      testEnv
    ];
    postCheck = ''
      for check in ${minimal.checks.x86_64-linux.manifest-consistent} \
        ${example.checks.x86_64-linux.manifest-consistent}; do
        [[ -e $check ]] || exit 1
      done
      # darwin is evaluated, not built.
      : ${builtins.unsafeDiscardStringContext example.checks.aarch64-darwin.manifest-consistent.drvPath}
    '';
  }
