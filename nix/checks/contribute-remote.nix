# Contribute, remote steps (tests/contribute/remote): `dotsteward contribute`
# trial (full and build-only), publish (owner: pull request, lint and privacy
# checks, main fast-forwarded to the checked commit and the tree check; fork:
# the fork's CI and main), release (release trains: semantic versions, main's
# CI green, grouped notes; the release workflow's tools/version.sh release),
# upgrade (to a release or to the merged commit on main, carrying unpublished
# instance commits), abort with the recovery after a trial switch, status
# (main's CI) and report, against the synthetic upstream and fork of the
# local tests behind a fake GitHub and a fake Nix, with recording stand-ins
# for the instance commands. Then shellcheck over the dispatcher, the remote
# and release libraries and the tests.
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
    shellcheck -x cli/commands/contribute.sh cli/lib/contribute-remote.sh cli/lib/release.sh tests/contribute/remote/*.sh
  '';
}
