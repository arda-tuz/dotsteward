# The instance flake. lib.mkInstance of the dotsteward framework builds every
# output from workstation.toml, versions.lock.json, home.nix and components/.
#
# nixpkgs and home-manager are the revisions the pinned framework release was
# tested with; dotsteward follows both, so one nixpkgs serves the framework
# and the instance. `dotsteward init` writes the flake inputs of the chosen
# components between the dotsteward:inputs markers; keep the markers.
{
  description = "dotsteward instance";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    home-manager = {
      url = "github:nix-community/home-manager/db7d5e2332710f5abb088f6b5de927d7f9511b35";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dotsteward = {
      url = "github:arda-tuz/dotsteward/v0.0.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # dotsteward:inputs:begin
    # dotsteward:inputs:end
  };

  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
