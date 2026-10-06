# Packages of the shell component (lib/packages.nix convention): starship,
# published as packages.<system>.starship of the instance and used by the
# component module through the package set.
{
  pkgs,
  pins,
  dsLib,
  ...
}:
{
  starship = import ./starship-package.nix { inherit pkgs pins dsLib; };
}
