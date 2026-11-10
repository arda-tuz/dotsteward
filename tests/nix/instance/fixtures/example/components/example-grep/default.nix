# example-grep: the nixpkgs package ripgrep, in the Home Manager profile. Written by dotsteward add;
# the instance owns it from here.
{ lib, pkgs, ... }:
{
  dotsteward.components.example-grep = {
    method = lib.mkDefault "nix";
    supportedMethods = {
      linux = [ "nix" ];
      darwin = [ "nix" ];
    };
    install.nix.packages = [ pkgs.ripgrep ];
    checks.commands = [ "rg" ];
  };
}
