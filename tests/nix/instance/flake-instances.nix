# Fixture instances evaluated inside the framework flake (used by
# nix/checks/nix-instance.nix, nix-assertions.nix and manifest-consistent.nix).
#
# Unlike the nix-instantiate tests, these use the real flake inputs: the
# framework's own self (with its rev and narHash) as dotsteward, its locked
# nixpkgs and home-manager, and an instance root that is a store path string
# like inputs.self of an instance flake.
#
#   instance { root ? "example" | "minimal", case ? null, inputs ? { }, ... }
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
      root = roots.${args.root or "example"};
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
  inherit instance;
  minimal = instance { root = "minimal"; };
  example = instance { };
}
