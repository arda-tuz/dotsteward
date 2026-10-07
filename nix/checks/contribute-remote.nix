# Contribute, remote steps (tests/contribute/remote): `dotsteward contribute`
# trial (full and build-only), publish (owner: pull request, checks, main
# fast-forwarded to the checked commit and the tree check; fork: the fork's
# CI and main), release, upgrade, abort with the recovery after a trial switch, and
# report, against the synthetic upstream and fork of the local tests behind a
# fake GitHub and a fake Nix, with recording stand-ins for the instance
# commands. Then shellcheck over the dispatcher, the remote library and the
# tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "contribute-remote";
  paths = [ "tests/contribute/remote" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/contribute.sh cli/lib/contribute-remote.sh tests/contribute/remote/*.sh
  '';
}
