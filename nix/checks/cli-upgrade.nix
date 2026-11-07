# Upgrade (tests/upgrade): `dotsteward upgrade` through the dispatcher against a synthetic instance
# whose remote is a local bare repository behind the fake SSH transport: the gate and txn publish are
# real over the nix, curl and gh stubs, the sudo and apt-get stubs are real to the command, and
# rebuild, e2e, pins, static, probes and the apt helper are fakes that keep their contracts. The
# terminal is a real pty. Then shellcheck over the tests. Real apt and real sudo are in
# tests/apt-worlds and tests/container, which need the host or Docker.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-upgrade";
  paths = [ "tests/upgrade" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/upgrade.sh tests/upgrade/*.sh
  '';
}
