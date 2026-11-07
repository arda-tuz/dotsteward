# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The directory of an own plugin is taken on another machine by a skill of that machine
# (review-c1 S4-M1, S4-M4). agents install and agents check stay green and leave the skill
# alone; the plugin is name-taken there, said in the session; the skill is still a skill
# that tracking asks about. A plugin that is for another machine only keeps nothing out
# here but its own kind: a skill of that name is a skill.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
new_machine b
b_skill=$(home_of b)/.claude/skills/tool
mkdir -p "$b_skill"
printf -- '---\nname: tool\ndescription: A skill of b.\n---\nb content\n' >"$b_skill/SKILL.md"
new_plugin a tool
tool_wrote a "$(plugin_dir a tool)/.claude-plugin/plugin.json"
settle_plugin a tool
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$DS_STDOUT$DS_STDERR" "tool"
assert_exit 0 ds b agents check --profile workstation
assert_eq "b content" "$(tail -n 1 "$b_skill/SKILL.md")"
[[ ! -e $b_skill/.claude-plugin ]] || ds_fail "the plugin does not land in the skill"
assert_exit 0 ds b skills reconcile --full
assert_eq name-taken "$(plugin_item b tool .state)"
assert_eq ask "$(jq -r '.items["skill:tool"].state // "none"' "$(state_of b)/skills/pending.json")"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on b SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" "tool"
# Renamed away: the plugin comes, the question goes.
mv -- "$b_skill" "$(home_of b)/.claude/skills/b-tool"
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ -f $(plugin_dir b tool)/.claude-plugin/plugin.json ]] || ds_fail "the plugin is installed once the name is free"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b tool .)"

# --- a plugin for a only, and a skill of b with that name -----------------------------------

new_plugin a only-a
tool_wrote a "$(plugin_dir a only-a)/.claude-plugin/plugin.json"
settle_plugin a only-a
ds_code a skills track only-a --here
mkdir -p "$(home_of b)/.claude/skills/only-a"
printf -- '---\nname: only-a\ndescription: A skill of b.\n---\n' >"$(home_of b)/.claude/skills/only-a/SKILL.md"
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b skills reconcile --full
assert_eq ask "$(jq -r '.items["skill:only-a"].state // "none"' "$(state_of b)/skills/pending.json")"
assert_eq "{}" "$(plugin_item b only-a .)"
assert_exit 0 ds b agents check --profile workstation
