# What other machines changed (tests/incoming): `dotsteward incoming` with machines of
# their own, clones of a bare remote: the questions, install, ask later and never, the source
# machine, a first run that asks nothing; on a pseudo terminal and without one. Then
# shellcheck over the command and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-incoming";
  paths = [ "tests/incoming" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/incoming.sh tests/incoming/*.sh
  '';
}
