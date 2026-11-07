# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin developed elsewhere and linked into ~/.claude/skills (review-c1 S4-M2). Where
# it lives says nothing about whose it is, so without a file tool's evidence it is a
# question, not tracked by itself. Answered with --own, its content is captured; on this
# machine the link stays, and agents install and agents check take a link with the content
# of the lock as in sync, with a note, never a finding.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
mkdir -p "$world/src"
new_plugin a linked
mv -- "$(plugin_dir a linked)" "$world/src/linked"
ln -s "$world/src/linked" "$(plugin_dir a linked)"
find "$world/src/linked" -exec touch -h -d '2001-01-01' {} +
tip=$(remote_tip)
assert_exit 0 ds a skills reconcile --full
assert_eq ask "$(plugin_item a linked .state)"
assert_eq unknown "$(plugin_item a linked .origin)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "a question publishes nothing"
EXPECT_STATUS=1 ds_code a skills track linked --all
assert_contains "$DS_STDERR" "--own"
ds_code a skills track linked --all --own
assert_json - '.name == "linked" and .agents == ["claude"]' <<<"$(remote_plugin linked)"
assert_eq "$(local_digest "$world/src/linked")" "$(remote_plugin linked | jq -r .directory_sha256)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
assert_contains "$DS_STDOUT$DS_STDERR" "link"
assert_exit 0 ds a agents check --profile workstation
[[ -L $(plugin_dir a linked) ]] || ds_fail "the link stays"
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a linked .)"
# Another machine gets a real directory.
new_machine b
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ -d $(plugin_dir b linked) && ! -L $(plugin_dir b linked) ]] || ds_fail "a real directory on b"
