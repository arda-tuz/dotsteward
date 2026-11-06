# Machine names and scopes (tests/cli/host): `dotsteward host` and `dotsteward
# skills effective` against a synthetic instance whose remote is a local bare
# repository reached through the fake SSH transport, and what the commands make of
# the answer: what `agents` installs and misses, what `e2e` lists, the message of a
# tree newer than the CLI. Then shellcheck over the commands and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-host";
  paths = [ "tests/cli/host" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/host.sh cli/commands/skills.sh tests/cli/host/*.sh
  '';
}
