# Update (tests/cli/update): `dotsteward update prepare|publish|status`
# against a synthetic instance whose remote is a local bare repository
# reached through the fake SSH transport, with the nix, curl and gh stubs
# (arguments and repository guards, prepare records and warnings, the
# publish refusals in order, the subject policy, the remote checks, already
# published, the canonical checkout, status, and the whole transaction with
# the gate), then shellcheck over the command and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-update";
  paths = [ "tests/cli/update" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/update.sh tests/cli/update/*.sh
  '';
}
