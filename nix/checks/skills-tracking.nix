# Skill tracking (tests/skills-tracking): the hooks in an agent's configuration
# driven with recorded payloads of real sessions, what they say and when, the
# origin of a new skill, the debounce and the capture to a bare remote; then
# shellcheck over the command, the component hooks and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "skills-tracking";
  paths = [ "tests/skills-tracking" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/skills.sh modules/components/claude-code/skill-hooks.sh \
      modules/components/codex/skill-hooks.sh tests/skills-tracking/*.sh
  '';
}
