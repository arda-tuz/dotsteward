# Packages of example-app: checked (checks.<system>.example-app). Lock
# values are read with pinAt, so a missing key names the component.
{
  pkgs,
  pins,
  dsLib,
  ...
}:
{
  example-app = {
    package = pkgs.writeShellScriptBin "example-app" ''
      echo "example-app ${dsLib.pinAt pins "nix_packages.example-app.expected" "example-app"}"
    '';
    check = true;
  };
}
