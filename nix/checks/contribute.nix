# Contribute, local steps (tests/contribute/local): `dotsteward contribute`
# mode, setup, start, check and status against a synthetic framework
# upstream and fork (local bare repositories reached through the fake SSH
# transport) with the gh and nix stubs: the mode matrix, clone and fork
# setup, branches from upstream main, the run state file, the reproduction
# check and the framework gate with its privacy hard stops and the
# instance-leak scan, the running marker of the long steps with
# `status --wait`, and `contribute commit` with the commit-msg and
# pre-commit hooks. Then shellcheck over the command, its libraries, the
# commit hooks and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "contribute";
  paths = [ "tests/contribute/local" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/contribute.sh cli/lib/contribute-local.sh cli/lib/commit-rules.sh \
      .githooks/commit-msg .githooks/pre-commit tests/contribute/local/*.sh
  '';
}
