# E2E runner and component hooks (tests/cli/e2e): `dotsteward e2e` (check
# list, flag matrix, repository checks against a bare remote through a fake
# SSH transport, managed links and agent-rule bytes, dotsteward.files,
# settings integration, login shell, hook phases, framework skills sync,
# keep-going JSON, --generation, manifest shape refusals) and `dotsteward
# component run` against a synthetic instance and temporary homes, then
# shellcheck over both commands and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-e2e";
  paths = [ "tests/cli/e2e" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/e2e.sh cli/commands/component.sh tests/cli/e2e/*.sh
  '';
}
