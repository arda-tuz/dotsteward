# Agents installer (tests/agents): cli/lib/skills.sh and the `dotsteward
# agents install|check` command against a synthetic instance, temporary
# homes and the generic stubs (skill layout, framework skills, refresh,
# sweep, official-binary phase, component hooks, validation, keep-going
# JSON), then shellcheck over the engine, the command and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "agents";
  paths = [ "tests/agents" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/lib/skills.sh cli/commands/agents.sh tests/agents/*.sh
  '';
}
