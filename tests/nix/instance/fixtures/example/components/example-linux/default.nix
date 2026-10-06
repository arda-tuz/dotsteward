# A Linux-only component (enabled only by the unsupported-system case).
{ lib, ... }:
{
  dotsteward.components.example-linux = {
    platforms = [ "linux" ];
    method = lib.mkDefault "external";
    supportedMethods.linux = [ "external" ];
  };
}
