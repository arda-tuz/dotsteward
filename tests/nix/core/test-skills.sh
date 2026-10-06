# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core skills: framework skills and instance home-managed skills
# linked under the Home Manager skill root.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# The skill root comes from [skills] hm_root.
assert_core_eq '".agents/skills"' '(homeOf { }).dotsteward.skills.hmRoot'
assert_core_eq '".codex/skills"' '(homeOf { config = "workstation"; }).dotsteward.skills.hmRoot'

# The framework skills default to those present in the framework's skills/
# directory, among the three framework skill names.
expected='[]'
if [[ -d $DS_REPO_ROOT/skills ]]; then
  expected=$(for name in dotsteward-contribute dotsteward-maintain dotsteward-update; do
    [[ ! -d $DS_REPO_ROOT/skills/$name ]] || printf '%s\n' "$name"
  done | jq -R . | jq -cs .)
fi
assert_core_eq "$expected" 'lib.sort lib.lessThan (homeOf { }).dotsteward.skills.framework'

stub_root='{ dotsteward.skills.frameworkRoot = fixtures + "/framework-skills"; }'

# skills ARGS: the skill home.file entries (name -> source) and assertions.
skills() {
  core_json "let c = homeOf ($1); root = c.dotsteward.skills.hmRoot; in {
    files = lib.mapAttrs (_: f: \"\${f.source}\") (lib.filterAttrs (n: _: lib.hasPrefix \"\${root}/\" n) c.home.file);
    framework = c.dotsteward.skills.framework;
  }"
}

# Framework skills present in the framework root are linked; homeManaged
# skills are linked next to them.
actual=$(skills "{ config = \"workstation\"; modules = [ $stub_root { dotsteward.skills.homeManaged.example-skill = fixtures + \"/instance/skills/example-skill\"; } ]; }")
json_check "$actual" '.framework' '["dotsteward-maintain","dotsteward-update"]'
json_check "$actual" '.files | keys' '[".codex/skills/dotsteward-maintain",".codex/skills/dotsteward-update",".codex/skills/example-skill"]'
# The links point at the store copies of the skill directories.
expected=$(core_json '{
  ".codex/skills/dotsteward-maintain" = "${fixtures + "/framework-skills/dotsteward-maintain"}";
  ".codex/skills/dotsteward-update" = "${fixtures + "/framework-skills/dotsteward-update"}";
  ".codex/skills/example-skill" = "${fixtures + "/instance/skills/example-skill"}";
}')
json_check "$actual" '.files' "$(jq -cS . <<<"$expected")"

# An explicit framework list is honoured.
actual=$(skills "{ modules = [ $stub_root { dotsteward.skills.framework = [ \"dotsteward-update\" ]; } ]; }")
json_check "$actual" '.files | keys' '[".agents/skills/dotsteward-update"]'

# Unknown and missing framework skills, and name collisions, fail assertions.
assert_core_fails "(homeOf { modules = [ $stub_root { dotsteward.skills.framework = [ \"dotsteward-unknown\" ]; } ]; }).home.file" \
  "- dotsteward: unknown framework skill dotsteward-unknown (known: dotsteward-contribute, dotsteward-maintain, dotsteward-update)"
assert_core_fails "(homeOf { modules = [ $stub_root { dotsteward.skills.framework = [ \"dotsteward-contribute\" ]; } ]; }).home.file" \
  "- dotsteward: framework skill dotsteward-contribute is missing from "
assert_core_fails "(homeOf { modules = [ $stub_root { dotsteward.skills.homeManaged.dotsteward-update = fixtures + \"/instance/skills/example-skill\"; } ]; }).home.file" \
  "- dotsteward: skill dotsteward-update is both a framework skill and a home-managed skill"

# The skill root must stay home relative.
assert_core_fails '(homeOf { modules = [ { dotsteward.skills.hmRoot = lib.mkForce "/abs/skills"; } ]; }).dotsteward.skills.hmRoot' \
  "dotsteward.skills.hmRoot"
