# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin that is for another machine only (machines) holds its name here too: a
# directory of that name on this machine is reported as name-taken, the way a skill is, and
# told in the session; it is neither captured nor touched by agents install, and --never
# answers it.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
new_plugin a only-a
tool_wrote a "$(plugin_dir a only-a)/.claude-plugin/plugin.json"
settle_plugin a only-a
ds_code a skills track only-a --here
assert_json - '.machines == ["a"]' <<<"$(remote_plugin only-a)"

new_machine b
new_plugin b only-a
printf '\nMade on b.\n' >>"$(plugin_dir b only-a)/skills/only-a-helper/SKILL.md"
assert_exit 0 ds b skills reconcile
assert_eq name-taken "$(plugin_item b only-a .state)"
assert_eq plugin "$(plugin_item b only-a .kind)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on b SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" "only-a"
# A file tool writing it changes nothing about that.
tool_wrote b "$(plugin_dir b only-a)/.claude-plugin/plugin.json"
assert_eq name-taken "$(plugin_item b only-a .state)"
tip=$(remote_tip)
settle_plugin b only-a
ds_code b skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$(plugin_dir b only-a)/skills/only-a-helper/SKILL.md")" "Made on b."
assert_exit 0 ds b skills reconcile --full
assert_eq name-taken "$(plugin_item b only-a .state)"
# --never: this machine keeps its own copy out of tracking.
ds_code b skills track only-a --never
assert_contains "$(remote_file hosts/b.toml)" "only-a"
assert_eq declined "$(plugin_item b only-a .state)"
assert_json - '.machines == ["a"]' <<<"$(remote_plugin only-a)"
