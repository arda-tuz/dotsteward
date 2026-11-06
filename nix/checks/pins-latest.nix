# Pins engine, latest research (tests/engines/pins/latest): `dotsteward pins
# latest` against a synthetic instance that declares every latest adapter,
# run offline in the build sandbox with loopback fakes (an HTTP server over
# fixture files, bare git remotes behind url.insteadOf, the gh and apt-cache
# stubs). Then shellcheck over the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "pins-latest";
  paths = [ "tests/engines/pins/latest" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/engines/pins/latest/*.sh
  '';
}
