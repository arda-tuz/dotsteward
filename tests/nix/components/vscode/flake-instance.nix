# The vscode fixture instance evaluated inside the framework flake (used by
# nix/checks/component-vscode.nix): lib.mkInstance with the framework's own
# self, nixpkgs and home-manager and the instance root fixtures/instance as
# a store path.
#
#   { instance }
{
  self,
  dsLib,
}:
let
  root = "${./fixtures/instance}";
in
{
  instance = dsLib.mkInstance {
    inherit root;
    inputs = {
      self.outPath = root;
      inherit (self.inputs) nixpkgs home-manager;
      dotsteward = self;
    };
  };
}
