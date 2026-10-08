# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The codex plugins option end to end: an instance
# lists Codex plugins in [components.codex] options; lib.mkInstance adds the
# component's agentsPost hook, and `dotsteward agents install|check` runs it
# against the codex stub. install adds a missing plugin with `codex plugin
# add`; both modes then verify it: listed as installed and enabled, its
# manifest version equals the listed one, at least the lock minimum
# (minimumAt), every required skill directory has a SKILL.md. check never
# adds anything.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs codex

spec=example-plugin@example-market
cache=$HOME/.codex/plugins/cache/example-market/example-plugin
minimum_at=agent_tools.example-plugin.minimum_version

# plugin_tree DIR VERSION [SKILL...]: a plugin directory: its manifest
# .codex-plugin/plugin.json with VERSION and skills/<SKILL>/SKILL.md.
plugin_tree() {
  local dir=$1 version=$2 skill
  shift 2
  rm -rf -- "$dir"
  mkdir -p "$dir/.codex-plugin"
  jq -n --arg version "$version" '{ name: "example-plugin", version: $version }' >"$dir/.codex-plugin/plugin.json"
  for skill in "$@"; do
    mkdir -p "$dir/skills/$skill"
    printf -- '---\nname: %s\ndescription: Synthetic plugin skill.\n---\n' "$skill" >"$dir/skills/$skill/SKILL.md"
  done
}

# listed VERSION [ENABLED [SOURCE_JSON]]: `codex plugin list --json` shows
# the plugin installed at VERSION (enabled by default), with SOURCE_JSON as
# its source when given.
listed() {
  jq -cn --arg spec "$spec" --arg version "$1" --argjson enabled "${2:-true}" --argjson source "${3:-null}" \
    '{ installed: [{ pluginId: $spec, name: "example-plugin", marketplaceName: "example-market",
      version: $version, installed: true, enabled: $enabled }
      + (if $source == null then {} else { source: $source } end)] }' |
    ds_stub_set codex plugins -
}

# reset_codex: no plugin installed, no canned list.
reset_codex() {
  rm -rf -- "$DS_STUB_STATE/codex" "$HOME/.codex/plugins"
}

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

inst=$(codex_instance plugins '["x86_64-linux"]' "method = \"external\"
options = { plugins = [
  { spec = \"$spec\", minimumAt = \"$minimum_at\", requiredSkillDirectories = [\"alpha-skill\", \"beta-skill\"] },
] }")
codex_lock_set "$inst" agent_tools.example-plugin '{"minimum_version": "1.2.0"}'
codex_mirror "$inst"

# --- check never installs -----------------------------------------------------------

# The skill layout is in place (the agents layout step checks it before the
# hooks run); only the plugin is missing.
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
before=$(codex_home_state)
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec is not installed and enabled; run 'dotsteward agents install --profile workstation'"
assert_contains "$DS_STDERR" "component codex hook plugins failed (exit 1)"
assert_call_count 0 codex 'plugin add*'
assert_eq "$before" "$(codex_home_state)" "check changes nothing"

# --- install adds the plugin, then verifies it ---------------------------------------

ds_stub_set codex plugin-version 1.2.0
ds_stub_set codex plugin-skills "alpha-skill beta-skill"
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex plugin $spec: installing with codex plugin add"
assert_contains "$DS_STDOUT" "codex plugin $spec 1.2.0 verified"
assert_call_count 1 codex "plugin add $spec"
assert_json "$cache/1.2.0/.codex-plugin/plugin.json" '.version == "1.2.0"'
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex plugin $spec 1.2.0 verified"
assert_exit 0 agents install
assert_call_count 1 codex "plugin add $spec"

# --- verification failures, in both modes ----------------------------------------------

# Older than the lock minimum: refused, never upgraded silently.
listed 1.1.0
plugin_tree "$cache/1.1.0" 1.1.0 alpha-skill beta-skill
for mode in check install; do
  assert_exit 1 agents "$mode"
  assert_contains "$DS_STDERR" "codex plugin $spec 1.1.0 is older than the minimum 1.2.0 ($minimum_at in versions.lock.json)"
done
assert_call_count 1 codex "plugin add $spec"

# A newer version passes the minimum; a missing required skill fails.
listed 1.3.0
plugin_tree "$cache/1.3.0" 1.3.0 alpha-skill
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec 1.3.0 lacks the skill beta-skill ($cache/1.3.0/skills/beta-skill/SKILL.md)"
plugin_tree "$cache/1.3.0" 1.3.0 alpha-skill beta-skill
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex plugin $spec 1.3.0 verified"

# The listed version and the plugin's own manifest disagree.
plugin_tree "$cache/1.3.0" 1.3.1 alpha-skill beta-skill
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec is listed as 1.3.0 but $cache/1.3.0/.codex-plugin/plugin.json says 1.3.1"

# No plugin directory.
listed 1.5.0
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec 1.5.0 has no plugin manifest at $cache/1.5.0/.codex-plugin/plugin.json"

# A version that is not a plain version string never becomes a path.
listed "../1.3.0"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec reports an invalid version: ../1.3.0"

# A disabled plugin is missing: check fails, install runs codex plugin add
# and fails when the plugin is still not installed and enabled.
listed 1.3.0 false
plugin_tree "$cache/1.3.0" 1.3.0 alpha-skill beta-skill
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin $spec is not installed and enabled"
assert_call_count 1 codex "plugin add $spec"
assert_exit 1 agents install
assert_call_count 2 codex "plugin add $spec"
assert_contains "$DS_STDERR" "codex plugin $spec is still not installed and enabled after codex plugin add"

# A plugin with a local source is read where the list says it lives.
local_dir=$DS_TEST_ROOT/local-plugin
listed 2.0.0 true "$(jq -cn --arg path "$local_dir" '{ source: "local", path: $path }')"
plugin_tree "$local_dir" 2.0.0 alpha-skill beta-skill
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex plugin $spec 2.0.0 verified"

# --- CODEX_HOME, codex missing ---------------------------------------------------------

reset_codex
ds_stub_set codex plugin-version 1.2.0
ds_stub_set codex plugin-skills "alpha-skill beta-skill"
export CODEX_HOME=$DS_TEST_ROOT/codex-home
assert_exit 0 agents install
assert_json "$CODEX_HOME/plugins/cache/example-market/example-plugin/1.2.0/.codex-plugin/plugin.json" '.version == "1.2.0"'
[[ ! -e $cache ]] || ds_fail "the plugin was installed outside CODEX_HOME"
unset CODEX_HOME
assert_exit 1 agents check
assert_contains "$DS_STDERR" "has no plugin manifest at $cache/1.2.0/.codex-plugin/plugin.json"

no_codex() {
  PATH=${PATH#"$DS_TEST_ROOT/bin:"} agents check
}
assert_exit 1 no_codex
assert_contains "$DS_STDERR" "required command not found: codex"

# --- Minimal entries ------------------------------------------------------------------------

# Without minimumAt and required skills, any installed version passes.
reset_codex
inst=$(codex_instance minimal '["x86_64-linux"]' "method = \"external\"
options = { plugins = [{ spec = \"$spec\" }] }")
codex_mirror "$inst"
ds_stub_set codex plugin-version 0.0.1
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex plugin $spec 0.0.1 verified"
assert_call_count 4 codex "plugin add $spec"
