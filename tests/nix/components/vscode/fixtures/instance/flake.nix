# The instance flake of the vscode fixture. Tests never evaluate it: they
# call lib.mkInstance with constructed inputs. It and flake.lock exist so
# `dotsteward pins check` cross-checks the flake_inputs of versions.lock.json
# as in a real instance.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    home-manager = {
      url = "github:nix-community/home-manager/db7d5e2332710f5abb088f6b5de927d7f9511b35";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = _: { };
}
