# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `txn publish` pushed the upgraded instance and the answer was lost (or
# the process died right then), so `dotsteward contribute upgrade` is red
# although origin already is the instance commit. Run again, as it says, the
# upgrade notices: e2e checks the instance against origin as it is, not
# against the publish base, which origin has left, and `txn publish`
# finds nothing to push. A remote that moved elsewhere stays red.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

pinned() {
  call_line dotsteward-launcher "$@"
  call_line "dotsteward-$1" "${@:2}"
}

# --- the answer of update publish is lost, then upgrade runs again --------------------------------

released_run add-feature
base=$(git -C "$ct_inst" rev-parse HEAD)
hub_knob txn-publish-lost any
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: txn publish failed; run upgrade again once it is fixed"
commit=$(git -C "$ct_inst" rev-parse HEAD)
[[ $commit != "$base" ]] || ds_fail "the upgrade made no commit"
assert_eq "$commit" "$(git -C "$rt_inst_bare" rev-parse refs/heads/main)" "origin main after the lost answer"
assert_eq upgrade "$(field .step)" "step after the lost answer"

reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_eq "$(
  pinned rebuild --profile main --switch
  pinned e2e --profile main
  pinned txn publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the upgrade that runs again"
state_json | assert_json - ".step == \"report\" and .instance_commit == \"$commit\""
assert_exit 0 run_contribute report
assert_contains "$DS_STDOUT" "[dotsteward] contribute run $(current_id): completed"

# --- the remote moved elsewhere: red, as before -----------------------------------------------------

write_flake github
released_run second-feature 0.1.2
base=$(git -C "$ct_inst" rev-parse HEAD)
stand_in_fail txn 'publish*'
assert_exit 1 run_contribute upgrade --tag v0.1.2
stand_in_clear txn
elsewhere=$DS_TEST_ROOT/elsewhere-instance
git clone -q "$rt_inst_bare" "$elsewhere"
git -C "$elsewhere" commit -q --allow-empty -m 'chore: a change of another machine'
git -C "$elsewhere" push -q origin HEAD:main
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.2
assert_contains "$DS_STDERR" "not the expected publish base $base"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: e2e failed on the upgraded instance"
assert_call_count 0 dotsteward-txn 'publish*'
