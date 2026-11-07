# Maintain transactions (tests/apply): `dotsteward maintain begin` and `dotsteward apply` through the
# dispatcher against the synthetic instance of tests/upgrade, whose remote is a local bare repository
# behind the fake SSH transport: the gate and txn are real over the nix, curl and gh stubs, and
# rebuild, e2e, install, preflight, settings, pins, static, probes and scan are fakes that keep their
# contracts. The terminal is a real pty. Then shellcheck over the commands and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-apply";
  paths = [ "tests/apply" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/apply.sh cli/commands/maintain.sh tests/apply/*.sh tests/apply/fakes/*.sh
  '';
}
