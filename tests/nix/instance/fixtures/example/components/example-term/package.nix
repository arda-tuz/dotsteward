# Packages of example-term: refers to example-app through the package
# fixpoint; not a check.
{ pkgs, packages, ... }:
{
  example-term = pkgs.writeShellScriptBin "example-term" ''
    exec ${packages.example-app}/bin/example-app "$@"
  '';
}
