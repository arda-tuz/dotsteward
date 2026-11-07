# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An update of an own plugin from another machine is never lost (review-c1 S4-B2). The
# scenario of the review: b never edited its copy, a published v2; b's agents install takes
# v2, nothing is a conflict, and --ours has nothing to answer. When the copy here cannot
# take the new one (a link out of the skill roots), the question says so and names
# --theirs, and --ours is refused: it would publish the older copy over the newer one.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
p=$(plugin_dir a shared)
helper=skills/shared-helper/SKILL.md
new_plugin a shared
tool_wrote a "$p/.claude-plugin/plugin.json"
settle_plugin a shared
ds_code a skills capture --now
new_machine b
bp=$(plugin_dir b shared)
ds_code b agents install --profile workstation --skip-validation
printf 'v2 line\n' >>"$p/$helper"
tool_wrote a "$p/$helper" post-tool-use-edit
settle_plugin a shared
ds_code a skills capture --now
assert_contains "$(remote_file "agent/plugins/shared/$helper")" "v2 line"
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$bp/$helper")" "v2 line"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b shared .)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on b SessionStart session-start
HOOK_ENV=()
assert_not_contains "$HOOK_OUT" "Changed here and in the repository"
assert_exit 1 ds b skills resolve shared --ours
assert_contains "$DS_STDERR" "no conflict"
find "$bp" -exec touch -h -d '2001-01-01' {} +
ds_code b skills capture --now
assert_contains "$(remote_file "agent/plugins/shared/$helper")" "v2 line"

# --- a copy that cannot take the new one: told as such, and --ours is refused ---------------

mkdir -p "$world/b-src"
mv -- "$bp" "$world/b-src/shared"
ln -s "$world/b-src/shared" "$bp"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_exit 0 ds b agents check --profile workstation
printf 'v3 line\n' >>"$p/$helper"
tool_wrote a "$p/$helper" post-tool-use-edit
settle_plugin a shared
ds_code a skills capture --now
tip=$(remote_tip)
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_not_contains "$(cat "$bp/$helper")" "v3 line"
assert_eq conflict "$(plugin_item b shared .state)"
assert_eq not-refreshed "$(plugin_item b shared .reason)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on b SessionStart session-start
HOOK_ENV=()
assert_not_contains "$HOOK_OUT" "Changed here and in the repository: shared"
assert_contains "$HOOK_OUT" "skills resolve <name> --theirs"
assert_exit 1 ds b skills resolve shared --ours
assert_contains "$DS_STDERR" "--theirs"
assert_eq "$tip" "$(remote_tip)"
assert_contains "$(remote_file "agent/plugins/shared/$helper")" "v3 line"
ds_code b skills resolve shared --theirs
assert_contains "$(cat "$bp/$helper")" "v3 line"
[[ -L $bp ]] || ds_fail "the link stays a link"
assert_eq "{}" "$(plugin_item b shared .)"
