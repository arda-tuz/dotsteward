# Fixture instances evaluated inside the framework flake (used by
# nix/checks/nix-instance.nix, nix-assertions.nix and manifest-consistent.nix).
#
# Unlike the nix-instantiate tests, these use the real flake inputs: the
# framework's own self (with its rev and narHash) as dotsteward, its locked
# nixpkgs and home-manager, and an instance root that is a store path string
# like inputs.self of an instance flake.
#
#   instance { root ? "example" | "minimal" | ROOT, case ? null, inputs ? { },
#              ... }        ROOT: any other instance root, such as a
#                           derivation (a fixture copy with generated files)
#   roots.<name>            the fixture roots as store path strings
#   minimal, example
{
  self,
  dsLib,
  lib,
}:
let
  roots = {
    minimal = "${../../fixtures/instances/minimal}";
    example = "${./fixtures/example}";
  };

  inputsFor = root: {
    self = {
      outPath = root;
    };
    inherit (self.inputs) nixpkgs home-manager;
    dotsteward = self;
  };

  instance =
    args:
    let
      given = args.root or "example";
      root = if lib.isString given && roots ? ${given} then roots.${given} else "${given}";
      caseConfig = lib.optionalAttrs ((args.case or null) != null) {
        config = ./fixtures/cases + "/${args.case}.toml";
      };
    in
    dsLib.mkInstance (
      removeAttrs args [
        "root"
        "case"
        "inputs"
      ]
      // caseConfig
      // {
        inputs = inputsFor root // args.inputs or { };
      }
    );
in
{
  inherit instance roots;
  minimal = instance { root = "minimal"; };
  example = instance { };
}
