# Pins engine, the writer (tests/engines/pins/apply): `dotsteward pins apply`
# against the synthetic instance of the pins check tests, run offline in the
# build sandbox with bare git remotes behind url.insteadOf and the fake nix, npm
# and sampletool of the test directory. Then shellcheck over the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "pins-apply";
  paths = [ "tests/engines/pins/apply" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/engines/pins/apply/*.sh
  '';
}
