# Skill contract (tests/skills): the self-tests of the checks and of
# tools/gen-skills-manifest.sh, the contract of the three framework skills and
# the generated skills/manifest.json, once all four exist, and, once
# plugins/dotsteward/skills/dotsteward-init exists, the contract of the plugin
# skill and the plugin files. Both are probed at evaluation time because those
# skills land after their contract tests: the framework skills together with
# their manifest, the plugin skill independently of them; `bash tests/run.sh
# tests/skills` always runs everything. Then shellcheck over the generator, the
# checks and their stand-in CLI.
{
  pkgs,
  lib,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
  hasFrameworkSkills = lib.all builtins.pathExists [
    ../../skills/dotsteward-maintain
    ../../skills/dotsteward-update
    ../../skills/dotsteward-contribute
    ../../skills/manifest.json
  ];
  hasPluginSkill = builtins.pathExists ../../plugins/dotsteward/skills/dotsteward-init;
in
cli.mkTestCheck {
  name = "skills";
  paths = [
    "tests/skills/selftest"
  ]
  ++ lib.optional hasFrameworkSkills "tests/skills/framework"
  ++ lib.optional hasPluginSkill "tests/skills/plugin";
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tools/gen-skills-manifest.sh tests/skills/lib/*.sh tests/skills/*/*.sh \
      tests/fixtures/skills-contract/cli/dotsteward
  '';
}
