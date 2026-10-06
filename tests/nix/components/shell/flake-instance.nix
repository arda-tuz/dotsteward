# The shell fixture instance evaluated inside the framework flake (used by
# nix/checks/component-shell.nix): the framework's own self as dotsteward,
# its locked nixpkgs and home-manager, and a store path string as the
# instance root, like inputs.self of an instance flake.
{
  self,
  dsLib,
}:
let
  root = "${./fixtures/instance}";
in
dsLib.mkInstance {
  inputs = {
    self.outPath = root;
    inherit (self.inputs) nixpkgs home-manager;
    dotsteward = self;
  };
}
