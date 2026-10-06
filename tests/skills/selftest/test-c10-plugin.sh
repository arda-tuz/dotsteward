# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C10: plugins/dotsteward/skills holds exactly dotsteward-init, and every
# plugin manifest and marketplace entry that exists carries VERSION.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

root=$SC_REPO_ROOT
plugin=$root/plugins/dotsteward
version=$(<"$root/VERSION")

st_expect_finding 'C10 plugins/dotsteward/skills: missing' sc_check_plugin "$root"
st_skill dotsteward-init "$plugin/skills" >/dev/null
# No manifests yet (they arrive with the distribution files): the set alone.
st_expect_clean sc_check_plugin "$root"

st_skill example-skill "$plugin/skills" >/dev/null
st_expect_finding 'C10 plugins/dotsteward/skills: holds [dotsteward-init example-skill], expected exactly [dotsteward-init]' \
  sc_check_plugin "$root"
rm -r "$plugin/skills/example-skill"
printf 'x\n' >"$plugin/skills/notes.md"
st_expect_finding 'holds [dotsteward-init notes.md], expected exactly [dotsteward-init]' sc_check_plugin "$root"
rm "$plugin/skills/notes.md"

write_manifests() {
  local v=$1
  mkdir -p "$plugin/.claude-plugin" "$plugin/.codex-plugin" "$root/.claude-plugin" "$root/.agents/plugins"
  jq -n --arg v "$v" '{name: "dotsteward", version: $v, license: "MIT"}' >"$plugin/.claude-plugin/plugin.json"
  jq -n --arg v "$v" '{name: "dotsteward", version: $v}' >"$plugin/.codex-plugin/plugin.json"
  jq -n --arg v "$v" '{name: "dotsteward", owner: {name: "dotsteward contributors"},
    plugins: [{name: "dotsteward", source: "./plugins/dotsteward", version: $v}]}' >"$root/.claude-plugin/marketplace.json"
  jq -n --arg v "$v" '{name: "dotsteward", plugins: [{name: "dotsteward", source: {path: "./plugins/dotsteward"}, version: $v}]}' \
    >"$root/.agents/plugins/marketplace.json"
}

write_manifests "$version"
st_expect_clean sc_check_plugin "$root"

write_manifests 9.9.9
st_run sc_check_plugin "$root"
for file in plugins/dotsteward/.claude-plugin/plugin.json plugins/dotsteward/.codex-plugin/plugin.json \
  .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  assert_contains "$ST_OUT" "C10 $file: version [9.9.9] differs from VERSION [$version]"
done

write_manifests "$version"
jq 'del(.version)' "$plugin/.claude-plugin/plugin.json" >"$DS_TEST_ROOT/p.json"
mv "$DS_TEST_ROOT/p.json" "$plugin/.claude-plugin/plugin.json"
st_expect_finding 'C10 plugins/dotsteward/.claude-plugin/plugin.json: version [] differs from VERSION' sc_check_plugin "$root"
write_manifests "$version"
# A marketplace entry without a version is fine (the plugin manifest has it).
jq 'del(.plugins[0].version)' "$root/.agents/plugins/marketplace.json" >"$DS_TEST_ROOT/m.json"
mv "$DS_TEST_ROOT/m.json" "$root/.agents/plugins/marketplace.json"
st_expect_clean sc_check_plugin "$root"
printf '{ not json\n' >"$root/.claude-plugin/marketplace.json"
st_expect_finding 'C10 .claude-plugin/marketplace.json: not valid JSON' sc_check_plugin "$root"
