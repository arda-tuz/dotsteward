# Pins engine, check and sync (tests/engines/pins/check): `dotsteward pins
# check|sync` and `dotsteward sync` against a synthetic instance that
# declares every rule kind, run offline in the build sandbox (stub nix for
# --nix and the mirror evaluation). Then shellcheck over the commands and
# the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "pins-check";
  paths = [ "tests/engines/pins/check" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/pins.sh cli/commands/generate.sh cli/commands/sync.sh tests/engines/pins/check/*.sh
  '';
}
