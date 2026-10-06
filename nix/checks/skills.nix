# Skill contract (tests/skills, SPEC 9.1, 9.5, 12.4 C1-C10): the self-tests
# of the checks and of tools/gen-skills-manifest.sh, the contract of the
# three framework skills and the generated skills/manifest.json (C1-C9) and,
# once plugins/dotsteward/skills/dotsteward-init exists, the contract of the
# plugin skill and the plugin files (C1-C6, C10). The plugin directory is
# probed at evaluation time because that skill lands independently of the
# framework skills; `bash tests/run.sh tests/skills` always runs everything.
# Then shellcheck over the generator, the checks and their stand-in CLI.
{
  pkgs,
  lib,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
  hasPluginSkill = builtins.pathExists ../../plugins/dotsteward/skills/dotsteward-init;
in
cli.mkTestCheck {
  name = "skills";
  paths = [
    "tests/skills/selftest"
    "tests/skills/framework"
  ]
  ++ lib.optional hasPluginSkill "tests/skills/plugin";
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tools/gen-skills-manifest.sh tests/skills/lib/*.sh tests/skills/*/*.sh \
      tests/fixtures/skills-contract/cli/dotsteward
  '';
}
