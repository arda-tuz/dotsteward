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

stub_root='{ dotsteward.skills.frameworkRoot = fixtures + "/framework/skills"; }'

# skills ARGS: the skill home.file entries (name -> source) and assertions.
skills() {
  core_json "let c = homeOf ($1); root = c.dotsteward.skills.hmRoot; in {
    files = lib.mapAttrs (_: f: \"\${f.source}\") (lib.filterAttrs (n: _: lib.hasPrefix \"\${root}/\" n) c.home.file);
    framework = c.dotsteward.skills.framework;
  }"
}

# The framework skills link into the framework source itself (3.3, the 9.4
# invariant): with the framework flake's source, a store path string with
# context ("${self}"), each link source is "${self}/skills/<name>", not a
# copy of the skill. homeManaged skills are linked next to them.
framework='"${fixtures + "/framework"}"'
actual=$(nix_core_read_write=1 core_json "let c = homeOf { config = \"workstation\"; framework = $framework; modules = [ { dotsteward.skills.homeManaged.example-skill = fixtures + \"/instance/skills/example-skill\"; } ]; }; in {
  framework = c.dotsteward.skills.framework;
  files = lib.mapAttrs (_: f: { source = toString f.source; context = builtins.hasContext (toString f.source); }) (lib.filterAttrs (n: _: lib.hasPrefix \".codex/skills/\" n) c.home.file);
}")
json_check "$actual" '.framework' '["dotsteward-maintain","dotsteward-update"]'
json_check "$actual" '.files | keys' '[".codex/skills/dotsteward-maintain",".codex/skills/dotsteward-update",".codex/skills/example-skill"]'
source_dir=$(core_raw "$framework")
json_check "$actual" '.files[".codex/skills/dotsteward-maintain"]' "$(jq -cS -n --arg s "$source_dir/skills/dotsteward-maintain" '{source: $s, context: true}')"
json_check "$actual" '.files[".codex/skills/dotsteward-update"]' "$(jq -cS -n --arg s "$source_dir/skills/dotsteward-update" '{source: $s, context: true}')"
# An instance skill directory (a path) is linked as its own store copy.
json_check "$actual" '.files[".codex/skills/example-skill"]' \
  "$(jq -cS -n --arg s "$(core_raw "toString (fixtures + \"/instance/skills/example-skill\")")" '{source: $s, context: false}')"
assert_eq "$(core_json '"${fixtures + "/instance/skills/example-skill"}"')" \
  "$(skills "{ config = \"workstation\"; modules = [ $stub_root { dotsteward.skills.homeManaged.example-skill = fixtures + \"/instance/skills/example-skill\"; } ]; }" | jq '.files[".codex/skills/example-skill"]')" \
  "the store copy of an instance skill"

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
