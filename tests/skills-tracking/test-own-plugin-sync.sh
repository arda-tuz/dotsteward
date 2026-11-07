# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin between two machines, the way an own skill goes: a change that another
# machine published reaches this one with a pull and `agents install` (incoming: a backup,
# then the new copy), a change on both machines is a conflict that `skills diff` shows as
# three trees, and `skills resolve --theirs` backs the local copy up and installs the one of
# the remote.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
a_plugin=$(plugin_dir a shared-plugin)
helper=skills/shared-plugin-helper/SKILL.md
new_plugin a shared-plugin
tool_wrote a "$a_plugin/.claude-plugin/plugin.json"
settle_plugin a shared-plugin
ds_code a skills capture --now
new_machine b
b_plugin=$(plugin_dir b shared-plugin)
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_eq "$(remote_plugin shared-plugin | jq -r .directory_sha256)" "$(plugin_base b shared-plugin)"

# --- incoming: a's change reaches b with a pull ---------------------------------------------

printf '\nFrom machine a.\n' >>"$a_plugin/$helper"
tool_wrote a "$a_plugin/$helper" post-tool-use-edit
settle_plugin a shared-plugin
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents check --profile workstation
assert_contains "$DS_STDOUT$DS_STDERR" "plugin shared-plugin: incoming"
assert_not_contains "$(cat "$b_plugin/$helper")" "From machine a." "check changes nothing"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$b_plugin/$helper")" "From machine a."
[[ -d $b_plugin && ! -L $b_plugin ]] || ds_fail "the refreshed plugin stays a real directory"
assert_eq "$(remote_plugin shared-plugin | jq -r .directory_sha256)" "$(local_digest "$b_plugin")"
assert_eq "$(local_digest "$b_plugin")" "$(plugin_base b shared-plugin)"
backup=$(find "$(state_of b)/backups" -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tail -n 1)
[[ -n $backup ]] || ds_fail "the old copy is in a backup"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b shared-plugin .)"

# --- a change on both machines: a conflict, three trees, and --theirs -----------------------

printf '\nSecond from a.\n' >>"$a_plugin/$helper"
tool_wrote a "$a_plugin/$helper" post-tool-use-edit
settle_plugin a shared-plugin
ds_code a skills capture --now
tip=$(remote_tip)
printf '\nOnly on b.\n' >>"$b_plugin/$helper"
tool_wrote b "$b_plugin/$helper" post-tool-use-edit
settle_plugin b shared-plugin
EXPECT_STATUS=3 ds_code b skills capture --now --json
assert_json - '.conflicts == ["shared-plugin"]' <<<"$DS_STDOUT"
assert_eq "$tip" "$(remote_tip)" "no commit in a conflict"
assert_eq conflict "$(plugin_item b shared-plugin .state)"
assert_exit 0 ds b skills diff shared-plugin --json
document=$DS_STDOUT
assert_contains "$(cat "$(jq -r .local <<<"$document")/$helper")" "Only on b."
assert_contains "$(cat "$(jq -r .remote <<<"$document")/$helper")" "Second from a."
assert_not_contains "$(cat "$(jq -r .remote <<<"$document")/$helper")" "Only on b."
assert_contains "$(cat "$(jq -r .base <<<"$document")/$helper")" "From machine a."
assert_not_contains "$(cat "$(jq -r .base <<<"$document")/$helper")" "Second from a."
[[ -f $(jq -r .remote <<<"$document")/.claude-plugin/plugin.json ]] || ds_fail "the remote tree is the plugin"
assert_eq "$tip" "$(jq -r .remote_commit <<<"$document")"
ds_code b skills resolve shared-plugin --theirs
assert_contains "$(cat "$b_plugin/$helper")" "Second from a."
assert_not_contains "$(cat "$b_plugin/$helper")" "Only on b."
backup=$(find "$(state_of b)/backups" -mindepth 1 -maxdepth 1 -name '*-skills' | LC_ALL=C sort | tail -n 1)
assert_contains "$(cat "$backup/files$b_plugin/$helper")" "Only on b."
assert_eq "$(remote_plugin shared-plugin | jq -r .directory_sha256)" "$(plugin_base b shared-plugin)"
assert_eq "{}" "$(plugin_item b shared-plugin .)"
assert_eq "$tip" "$(remote_tip)"
