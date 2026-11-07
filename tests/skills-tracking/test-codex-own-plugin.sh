# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin of Codex: a directory in ${CODEX_HOME:-~/.codex}/plugins with a
# .codex-plugin/plugin.json (or a plugin.json at its root), the place the Codex
# documentation gives a personal plugin. It follows the rules of an own plugin of Claude
# Code: tracked without a question, captured into agent/plugins with agents = ["codex"];
# another machine gets the directory from `agents install`, an entry in the personal
# marketplace ~/.agents/plugins/marketplace.json (source local, a path from the home) and
# `codex plugin add NAME@MARKETPLACE`, again after an incoming change, because Codex runs
# the copy in its cache. A local change there is never overwritten, a clone is a question,
# and the plugin cache of Codex is never a candidate. Without the codex component nothing of
# this happens.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

# The instance enables codex.
git clone -q "$remote" "$world/edit"
manifest=$world/edit/.dotsteward/manifest.$fixture_system.json
jq '.components = [{name: "codex", source: "catalog", method: "external", profiles: null,
  platforms: ["linux", "darwin"], options: {}, modes: {}, supported_methods: {}, install: {}}]' \
  "$manifest" >"$manifest.tmp"
mv -- "$manifest.tmp" "$manifest"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
ds a skills hooks install --agent codex >/dev/null
a_plugin=$(plugin_dir a codex-tool codex)
helper=skills/codex-tool-helper/SKILL.md
start=$(remote_tip)

# --- made here: tracked, no question --------------------------------------------------------

new_plugin a codex-tool codex
# The cache of Codex holds installed copies: never a candidate.
mkdir -p "$(home_of a)/.codex/plugins/cache/personal/codex-tool/0.1.0/.codex-plugin"
cp -- "$a_plugin/.codex-plugin/plugin.json" "$(home_of a)/.codex/plugins/cache/personal/codex-tool/0.1.0/.codex-plugin/"
assert_exit 0 ds a skills reconcile
assert_eq capture "$(plugin_item a codex-tool .state)"
assert_eq own "$(plugin_item a codex-tool .origin)"
assert_eq "{}" "$(plugin_item a cache .)"
settle_plugin a codex-tool codex
ds_code a skills capture --now --json
assert_json - '.captured == ["codex-tool"]' <<<"$DS_STDOUT"
assert_eq "$start" "$(git -C "$remote" rev-parse 'refs/heads/main^')"
assert_eq "chore(plugins): capture codex-tool" "$(git -C "$remote" log -1 --format=%s refs/heads/main)"
assert_json - '.name == "codex-tool" and .directory == "codex-tool" and .agents == ["codex"]' <<<"$(remote_plugin codex-tool)"
assert_eq "$(local_digest "$a_plugin")" "$(remote_plugin codex-tool | jq -r .directory_sha256)"
assert_eq "$(cat "$a_plugin/.codex-plugin/plugin.json")" "$(remote_file agent/plugins/codex-tool/.codex-plugin/plugin.json)"
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a codex-tool .)"
# A plugin.json at the root, as the documentation describes a portable plugin, counts too.
mkdir -p "$(home_of a)/.codex/plugins/portable-tool"
printf '{"name": "portable-tool", "version": "1.0.0"}\n' >"$(home_of a)/.codex/plugins/portable-tool/plugin.json"
assert_exit 0 ds a skills reconcile
assert_eq capture "$(plugin_item a portable-tool .state)"
# A clone of somebody else's is a question.
git init -q -b main "$world/codex-upstream"
mkdir -p "$world/codex-upstream/.codex-plugin"
printf '{"name": "cloned-tool", "version": "1.0.0"}\n' >"$world/codex-upstream/.codex-plugin/plugin.json"
git -C "$world/codex-upstream" add -A
git -C "$world/codex-upstream" commit -q -m "chore: a plugin"
git clone -q "$world/codex-upstream" "$(home_of a)/.codex/plugins/cloned-tool"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a cloned-tool .state)"
assert_eq downloaded "$(plugin_item a cloned-tool .origin)"
# A file tool of Codex writing below it is evidence, as for a skill.
printf '\nMore.\n' >>"$a_plugin/$helper"
EVENT_FILE=$a_plugin/$helper
on a bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|fe058fc9|g" -e "s|@FILE@|$2|g" "$1" |
  "$3" skills hook PostToolUse --agent codex' _ "$fixtures/codex/post-tool-use-apply-patch-update.json" \
  "$EVENT_FILE" "$DS_REPO_ROOT/cli/dotsteward"
assert_eq capture "$(plugin_item a codex-tool .state)"
settle_plugin a codex-tool codex
ds_code a skills capture --now --name codex-tool
assert_contains "$(remote_file agent/plugins/codex-tool/$helper)" "More."

# --- another machine: directory, personal marketplace, codex plugin add ---------------------

new_machine b
export FAKE_CODEX_LIST=$DS_TEST_ROOT/codex-list.json
printf '{"installed": [], "available": []}\n' >"$FAKE_CODEX_LIST"
b_plugin=$(plugin_dir b codex-tool codex)
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ -d $b_plugin && ! -L $b_plugin ]] || ds_fail "the other machine gets a real directory"
assert_eq "$(remote_plugin codex-tool | jq -r .directory_sha256)" "$(local_digest "$b_plugin")"
assert_eq "$(local_digest "$b_plugin")" "$(plugin_base b codex-tool)"
market=$(home_of b)/.agents/plugins/marketplace.json
assert_json "$market" '.name == "personal"
  and ([.plugins[] | select(.name == "codex-tool")] == [{name: "codex-tool",
    source: {source: "local", path: "./.codex/plugins/codex-tool"}, policy: {installation: "AVAILABLE"}}])'
assert_contains "$(cat "$DS_TEST_ROOT/agent-calls")" "codex plugin add codex-tool@personal"
assert_json "$FAKE_CODEX_LIST" '[.installed[].pluginId] == ["codex-tool@personal"]'
# In sync and enabled: nothing to do; check only reads.
: >"$DS_TEST_ROOT/agent-calls"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_not_contains "$(cat "$DS_TEST_ROOT/agent-calls")" "plugin add"
assert_exit 0 ds b agents check --profile workstation
assert_not_contains "$(cat "$DS_TEST_ROOT/agent-calls")" "plugin add"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b codex-tool .)"
# A marketplace file of the user keeps its name and its other plugins.
jq '.name = "mine" | .plugins += [{name: "other", source: {source: "local", path: "./elsewhere/other"}}]
  | .plugins |= map(select(.name != "codex-tool"))' "$market" >"$market.tmp"
mv -- "$market.tmp" "$market"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_json "$market" '.name == "mine" and ([.plugins[].name] == ["other", "codex-tool"])'
assert_contains "$(cat "$DS_TEST_ROOT/agent-calls")" "codex plugin add codex-tool@mine"

# --- incoming: the copy is refreshed and added again, so the cache of Codex takes it --------

printf '\nSecond from a.\n' >>"$a_plugin/$helper"
assert_exit 0 ds a skills reconcile --full
settle_plugin a codex-tool codex
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
: >"$DS_TEST_ROOT/agent-calls"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$b_plugin/$helper")" "Second from a."
assert_contains "$(cat "$DS_TEST_ROOT/agent-calls")" "codex plugin add codex-tool@mine"
# A local change there stays.
printf '\nOnly on b.\n' >>"$b_plugin/$helper"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$b_plugin/$helper")" "Only on b."
assert_exit 0 ds b skills reconcile --full
assert_eq capture "$(plugin_item b codex-tool .state)"

# --- without the codex component: nothing ---------------------------------------------------

new_machine c
git -C "$(clone_of c)" checkout -q "$start" -- .dotsteward
new_plugin c lonely-tool codex
assert_exit 0 ds c skills hooks install --agent codex
assert_exit 0 ds c skills reconcile
assert_eq "{}" "$(plugin_item c lonely-tool .)"
assert_exit 0 ds c agents install --profile workstation --skip-validation
[[ ! -e $(plugin_dir c codex-tool codex) ]] || ds_fail "no codex component: no Codex plugin"
