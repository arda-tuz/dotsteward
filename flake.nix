{
  description = "dotsteward: reproducible agent workstations with Nix and Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    home-manager = {
      url = "github:nix-community/home-manager/db7d5e2332710f5abb088f6b5de927d7f9511b35";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: import ./nix/outputs.nix inputs;
}
