# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The claude-code plugins option end to end: an instance lists Claude Code
# plugins in [components.claude-code] options; lib.mkInstance adds the
# component's agentsPost hook, and `dotsteward agents install|check` runs it
# against the claude stub. install adds a missing marketplace (when the
# entry names one) with `claude plugin marketplace add`, installs a missing
# plugin at user scope with `claude plugin install` and enables a disabled
# one; both modes then verify it: listed at user scope and enabled, its
# install directory present, at least the lock minimum (minimumAt, with the
# plugin manifest agreeing with the listed version), every required file
# present. check never adds anything.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

# The isolated store, once per test file (evaluations run in command
# substitutions, whose setup would be lost).
nix_core_init

cc_hermetic_path
ds_use_stubs claude

spec=example-plugin@example-market
repo=example-org/example-marketplace
cache=$HOME/.claude/plugins/cache/example-market/example-plugin
minimum_at=agent_tools.example-plugin.minimum_version

# plugin_tree DIR VERSION [FILE...]: a plugin directory: its manifest
# .claude-plugin/plugin.json with VERSION and each relative FILE.
plugin_tree() {
  local dir=$1 version=$2 file
  shift 2
  rm -rf -- "$dir"
  mkdir -p "$dir/.claude-plugin"
  jq -n --arg version "$version" '{ name: "example-plugin", version: $version }' >"$dir/.claude-plugin/plugin.json"
  for file in "$@"; do
    mkdir -p "$(dirname -- "$dir/$file")"
    printf 'synthetic plugin file\n' >"$dir/$file"
  done
}

# listed VERSION [ENABLED [SCOPE [DIR]]]: `claude plugin list --json` shows
# the plugin at VERSION (enabled at user scope by default), installed in DIR
# (default: the cache directory of VERSION).
listed() {
  jq -cn --arg spec "$spec" --arg version "$1" --argjson enabled "${2:-true}" --arg scope "${3:-user}" \
    --arg dir "${4:-$cache/$1}" \
    '[{ id: $spec, version: $version, scope: $scope, enabled: $enabled, installPath: $dir }]' |
    ds_stub_set claude plugins -
}

# market NAME REPO: `claude plugin marketplace list --json` shows NAME from
# the GitHub repository REPO.
market() {
  jq -cn --arg name "$1" --arg repo "$2" \
    '[{ name: $name, source: "github", repo: $repo, installLocation: "/home/user/.claude/plugins/marketplaces/\\($name)" }]' |
    ds_stub_set claude marketplaces -
}

# reset_claude: no marketplace added, no plugin installed, no canned lists,
# an empty call log.
reset_claude() {
  rm -rf -- "$DS_STUB_STATE/claude" "$HOME/.claude/plugins"
  : >"$DS_CALL_LOG"
}

agents() {
  cc_cli "$inst" agents "$1" --profile workstation
}

inst=$(cc_instance plugins "method = \"external\"
options = { plugins = [
  { spec = \"$spec\", marketplace = \"$repo\", minimumAt = \"$minimum_at\", requiredFiles = [\"skills/alpha/SKILL.md\", \"hooks/hooks.json\"] },
] }")
cc_lock_set "$inst" agent_tools.example-plugin '{"minimum_version": "1.2.0"}'
cc_mirror "$inst"

# --- check never installs -----------------------------------------------------------

# The skill layout is in place (the agents layout step checks it before the
# hooks run); only the marketplace and the plugin are missing.
mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
ds_stub_set claude marketplace-name example-market
before=$(cc_home_state)
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude marketplace example-market ($repo) is not added; run 'dotsteward agents install --profile workstation'"
assert_contains "$DS_STDERR" "component claude-code hook plugins failed (exit 1)"
assert_call_count 0 claude 'plugin marketplace add*'
assert_call_count 0 claude 'plugin install*'
assert_eq "$before" "$(cc_home_state)" "check changes nothing"

# --- install adds the marketplace and the plugin, then verifies it -------------------

ds_stub_set claude plugin-version 1.2.0
ds_stub_set claude plugin-files "skills/alpha/SKILL.md hooks/hooks.json"
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "claude marketplace example-market: adding $repo with claude plugin marketplace add"
assert_contains "$DS_STDOUT" "claude plugin $spec: installing with claude plugin install"
assert_contains "$DS_STDOUT" "claude plugin $spec 1.2.0 verified"
assert_call_count 1 claude "plugin marketplace add $repo"
assert_call_count 1 claude "plugin install $spec --scope user"
assert_json "$cache/1.2.0/.claude-plugin/plugin.json" '.version == "1.2.0"'
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "claude plugin $spec 1.2.0 verified"
assert_exit 0 agents install
assert_call_count 1 claude "plugin marketplace add $repo"
assert_call_count 1 claude "plugin install $spec --scope user"

# --- marketplace problems, in both modes ------------------------------------------------

# The marketplace name is taken by another repository: never replaced.
market example-market other-org/other-marketplace
for mode in check install; do
  assert_exit 1 agents "$mode"
  assert_contains "$DS_STDERR" "claude marketplace example-market is added from github other-org/other-marketplace, not from github $repo"
done
assert_call_count 1 claude "plugin marketplace add $repo"

# The repository declares another marketplace name than the spec.
reset_claude
ds_stub_set claude marketplace-name other-market
assert_exit 1 agents install
assert_contains "$DS_STDERR" "claude plugin marketplace add $repo did not add the marketplace example-market"
assert_call_count 0 claude 'plugin install*'

# --- verification failures, in both modes ----------------------------------------------

reset_claude
market example-market "$repo"

# Older than the lock minimum: refused, never upgraded silently.
listed 1.1.0
plugin_tree "$cache/1.1.0" 1.1.0 skills/alpha/SKILL.md hooks/hooks.json
for mode in check install; do
  assert_exit 1 agents "$mode"
  assert_contains "$DS_STDERR" "claude plugin $spec 1.1.0 is older than the minimum 1.2.0 ($minimum_at in versions.lock.json)"
done
assert_call_count 0 claude 'plugin install*'

# A newer version passes the minimum; a missing required file fails.
listed 1.3.0
plugin_tree "$cache/1.3.0" 1.3.0 skills/alpha/SKILL.md
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec 1.3.0 lacks the file hooks/hooks.json ($cache/1.3.0/hooks/hooks.json)"
plugin_tree "$cache/1.3.0" 1.3.0 skills/alpha/SKILL.md hooks/hooks.json
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "claude plugin $spec 1.3.0 verified"

# The listed version and the plugin's own manifest disagree.
plugin_tree "$cache/1.3.0" 1.3.1 skills/alpha/SKILL.md hooks/hooks.json
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec is listed as 1.3.0 but $cache/1.3.0/.claude-plugin/plugin.json says 1.3.1"

# A marketplace revision as the version cannot be held to a minimum.
listed 0123456789ab
plugin_tree "$cache/0123456789ab" 0123456789ab skills/alpha/SKILL.md hooks/hooks.json
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec reports the version 0123456789ab, which minimumAt cannot compare (a dotted version is needed)"

# No install directory.
listed 1.5.0
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec has no install directory: $cache/1.5.0"

# A plugin at another scope does not count: check fails, install installs
# it at user scope.
listed 1.3.0 true project
plugin_tree "$cache/1.3.0" 1.3.0 skills/alpha/SKILL.md hooks/hooks.json
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec is not installed and enabled at user scope; run 'dotsteward agents install --profile workstation'"
assert_call_count 0 claude 'plugin install*'

# A disabled plugin: check fails, install enables it and fails when it stays
# disabled.
listed 1.3.0 false
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin $spec is not installed and enabled at user scope"
assert_exit 1 agents install
assert_contains "$DS_STDOUT" "claude plugin $spec: enabling with claude plugin enable"
assert_call_count 1 claude "plugin enable $spec --scope user"
assert_contains "$DS_STDERR" "claude plugin $spec is still not installed and enabled at user scope after claude plugin enable"
assert_call_count 0 claude 'plugin install*'

# An install that fails (a marketplace may declare a command that needs a
# person's confirmation): the hook reports it and never confirms for them.
reset_claude
market example-market "$repo"
ds_stub_route claude "plugin install $spec --scope user" --exit 1 --stderr 'Error: confirmation required'
assert_exit 1 agents install
assert_contains "$DS_STDERR" "claude plugin install $spec --scope user failed; a plugin whose marketplace asks for a confirmation is installed once by hand"
assert_not_contains "$(<"$DS_CALL_LOG")" "--yes"
assert_not_contains "$(<"$DS_CALL_LOG")" "--accept-command"
ds_stub_clear_routes claude

# --- claude missing --------------------------------------------------------------------

no_claude() {
  PATH=${PATH#"$DS_TEST_ROOT/bin:"} agents check
}
assert_exit 1 no_claude
assert_contains "$DS_STDERR" "required command not found: claude"

# --- Minimal entries ------------------------------------------------------------------------

# Without a marketplace, minimumAt and required files: the marketplace must
# be known to Claude Code already, and any installed version passes, a
# marketplace revision included.
reset_claude
inst=$(cc_instance minimal "method = \"external\"
options = { plugins = [{ spec = \"$spec\" }] }")
cc_mirror "$inst"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "claude plugin install $spec --scope user failed"
assert_call_count 0 claude 'plugin marketplace add*'
ds_stub_set claude builtin-marketplaces example-market
ds_stub_set claude plugin-version 0123456789ab
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "claude plugin $spec 0123456789ab verified"
assert_exit 0 agents check
assert_call_count 0 claude 'plugin marketplace add*'
