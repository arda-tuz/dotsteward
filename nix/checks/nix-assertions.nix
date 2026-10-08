# Evaluation guards: each failure case of the fixture instances,
# evaluated inside this flake, must fail (builtins.tryEval); the messages
# are checked by tests/nix/instance/assertions with nix-instantiate. A case
# that evaluates successfully fails this check at evaluation time, naming
# the case.
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
    name = "dotsteward-nix-assertions-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };

  fixtures = import ../../tests/nix/instance/flake-instances.nix { inherit self dsLib lib; };
  inherit (fixtures) instance example;

  activation = i: i.homeConfigurations.alice.activationPackage.drvPath;

  # Each value is a string whose evaluation must throw.
  cases = {
    unknown-profile =
      (example.lib.mkHome {
        username = "alice";
        homeDirectory = "/home/alice";
        profile = "unknown-profile";
      }).activationPackage.drvPath;
    username-mismatch = activation (instance {
      homeModules = [ { home.username = lib.mkForce "mallory"; } ];
    });
    unknown-component = activation (instance {
      case = "unknown-component";
    });
    unsupported-system =
      (instance { case = "unsupported-system"; }).dotstewardManifest.aarch64-darwin.system;
    unsupported-method = activation (instance {
      case = "unsupported-method";
    });
    missing-pin = activation (instance {
      case = "missing-pin";
    });
    missing-follows-nixpkgs = activation (instance {
      inputs.nixpkgs = self.inputs.nixpkgs // {
        outPath = "/nonexistent/nixpkgs";
      };
    });
    missing-follows-home-manager = activation (instance {
      inputs.home-manager = self.inputs.home-manager // {
        outPath = "/nonexistent/home-manager";
      };
    });
    unknown-key = activation (instance {
      case = "unknown-key";
    });
  };

  # The same instances without the fault evaluate: the guards are specific.
  controls = {
    example = activation example;
    linux-only-on-linux =
      (instance { case = "unsupported-system"; }).dotstewardManifest.x86_64-linux.system;
  };

  succeeded = lib.filter (name: (builtins.tryEval cases.${name}).success) (lib.attrNames cases);
  failedControls = lib.filter (name: !(builtins.tryEval controls.${name}).success) (
    lib.attrNames controls
  );
in
if succeeded != [ ] then
  throw "nix-assertions: these cases evaluated without the expected failure: ${lib.concatStringsSep ", " succeeded}"
else if failedControls != [ ] then
  throw "nix-assertions: these control evaluations failed: ${lib.concatStringsSep ", " failedControls}"
else
  cli.mkTestCheck {
    name = "nix-assertions";
    paths = [ "tests/nix/instance/assertions" ];
    nativeBuildInputs = [
      pkgs.nix
      testEnv
    ];
  }
