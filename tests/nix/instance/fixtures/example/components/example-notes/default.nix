# example-notes: the APT packages example-notes, example-notes-data from the sources of the machine,
# updated with plain apt upgrade. Written by dotsteward add; the instance owns it from here.
{ lib, ... }:
{
  dotsteward.components.example-notes = {
    platforms = [ "linux" ];
    method = lib.mkDefault "deb";
    supportedMethods.linux = [ "deb" ];
    install.deb = {
      pin = null;
      apt = [ "example-notes" "example-notes-data" ];
    };
    checks.commands = [ "example-notes" ];
  };
}
