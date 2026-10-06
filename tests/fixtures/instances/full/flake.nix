# The instance flake of the full fixture. The check never evaluates it: it
# calls lib.mkInstance with the framework under test as dotsteward and a
# stand-in herdr package. It and flake.lock exist so the offline pins check
# (checks.<system>.instance-contract) cross-checks the flake_inputs of
# versions.lock.json, the herdr input included, as in a real instance.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    home-manager = {
      url = "github:nix-community/home-manager/db7d5e2332710f5abb088f6b5de927d7f9511b35";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # dotsteward:inputs:begin
    herdr.url = "github:herdrdev/herdr/v0.9.3";
    # dotsteward:inputs:end
  };

  outputs = _: { };
}
