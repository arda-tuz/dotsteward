# Tracking (tests/track): `dotsteward add`, `dotsteward remove` and `dotsteward status` through the
# dispatcher against the synthetic instance of tests/upgrade, whose remote is a local bare repository
# behind the fake SSH transport: maintain begin, apply, the gate and txn are real over the nix, curl
# and gh stubs; rebuild, e2e, install, preflight, settings, pins, static, probes and scan are the
# fakes of tests/upgrade and tests/apply, dpkg-query and apt-cache the stubs of the harness. The
# terminal is a real pty. Then shellcheck over the commands and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-track";
  paths = [ "tests/track" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/add.sh cli/commands/remove.sh cli/commands/status.sh tests/track/*.sh
  '';
}
