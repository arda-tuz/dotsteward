# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# One name, one own plugin (review-c2 C2-B2): an own plugin of Codex with the name of a tracked
# own plugin of Claude Code is name-taken (reason other-agent), said in the session and in
# skills status; a file tool writing it never touches the copy of the repository, nothing
# goes back and forth, agents install and agents check stay green. And a write of a skill
# whose place an own plugin of the lock names goes to the skill (C2-m1): the plugin stays
# name-taken, the skill is tracked by the evidence of the write.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

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
new_plugin a dual
tool_wrote a "$(plugin_dir a dual)/.claude-plugin/plugin.json"
settle_plugin a dual
ds_code a skills capture --now
claude_tree=$(git -C "$remote" rev-parse refs/heads/main:agent/plugins/dual)
tip=$(remote_tip)

new_plugin a dual codex
codex_copy=$(plugin_dir a dual codex)
on a bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|fe058fc9|g" -e "s|@FILE@|$2|g" "$1" |
  "$3" skills hook PostToolUse --agent codex' _ "$fixtures/codex/post-tool-use-apply-patch-update.json" \
  "$codex_copy/.codex-plugin/plugin.json" "$DS_REPO_ROOT/cli/dotsteward"
settle_plugin a dual codex
ds_code a skills capture --now
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "the Codex copy never reaches the repository"
assert_eq "$claude_tree" "$(git -C "$remote" rev-parse refs/heads/main:agent/plugins/dual)"
assert_json - '.agents == ["claude"]' <<<"$(remote_plugin dual)"
assert_eq "{}" "$(plugin_item a dual .)" "the Claude plugin is in sync"
taken=$(jq -c '[.items[] | select(.kind == "plugin" and .name == "dual" and .state == "name-taken")]' "$(state_of a)/skills/pending.json")
assert_json - 'length == 1 and .[0].reason == "other-agent"' <<<"$taken"
assert_eq "$codex_copy" "$(jq -r '.[0].path' <<<"$taken")"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" "dual"
assert_not_contains "$HOOK_OUT" "another skill,"
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "name-taken: other-agent ($codex_copy)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
assert_exit 0 ds a agents check --profile workstation
new_machine b
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_exit 0 ds b agents check --profile workstation
[[ -f $(plugin_dir b dual)/.claude-plugin/plugin.json ]] || ds_fail "b gets the Claude plugin"
# Renamed away, the name is free again.
mv -- "$codex_copy" "$(home_of a)/.codex/plugins/dual-codex"
sed -i 's/"name": "dual"/"name": "dual-codex"/' "$(home_of a)/.codex/plugins/dual-codex/.codex-plugin/plugin.json"
assert_exit 0 ds a skills reconcile --full
assert_eq 0 "$(jq '[.items[] | select(.state == "name-taken")] | length' "$(state_of a)/skills/pending.json")"
assert_eq capture "$(plugin_item a dual-codex .state)"

# --- C2-m1: a write of b's skill at the place of the plugin goes to the skill ----------------

b_skill=$(home_of b)/.claude/skills/tool
new_plugin a tool
tool_wrote a "$(plugin_dir a tool)/.claude-plugin/plugin.json"
settle_plugin a tool
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
mkdir -p "$b_skill"
printf -- '---\nname: tool\ndescription: A skill of b.\n---\n' >"$b_skill/SKILL.md"
assert_exit 0 ds b skills reconcile --full
assert_eq name-taken "$(plugin_item b tool .state)"
tool_wrote b "$b_skill/SKILL.md"
assert_eq name-taken "$(plugin_item b tool .state)"
assert_eq capture "$(jq -r '.items["skill:tool"].state' "$(state_of b)/skills/pending.json")"
assert_eq own "$(jq -r '.items["skill:tool"].origin' "$(state_of b)/skills/pending.json")"
