# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# A build-only upgrade keeps the trial switch of the run (it does not switch), and its `txn
# publish` pushed the instance but the answer was lost. `dotsteward contribute abort` then runs
# the recovery: rebuild --switch, and an e2e that checks the instance against origin as it is
# (the published commit, which txn publish rewrote to name the machine), not against the publish
# base that origin has left, so abort ends the run. A remote that moved elsewhere still holds the
# e2e to the base.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

checked_run add-feature 0.1.1
mark_trialled full true
printf 'trial\n' >"$rt_live"
assert_exit 0 run_contribute publish
assert_exit 0 run_contribute release
base=$(git -C "$ct_inst" rev-parse HEAD)

hub_knob txn-publish-lost any
assert_exit 1 run_contribute upgrade --tag v0.1.1 --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: txn publish failed; run upgrade again once it is fixed"
published=$(git -C "$rt_inst_bare" rev-parse refs/heads/main)
[[ $published != "$base" ]] || ds_fail "the lost publish pushed nothing"
assert_eq "$published" "$(git -C "$ct_inst" rev-parse HEAD)" "HEAD after the lost answer"
state_json | assert_json - '.trial_switched == true and .step == "upgrade"'

reset_calls
assert_exit 0 run_contribute abort
assert_call_count 1 dotsteward-rebuild '--profile main --switch'
assert_call_count 1 dotsteward-e2e '--profile main'
assert_call_count 0 dotsteward-e2e '--profile main --expected-remote-base*'
assert_eq pinned "$(live)" "live framework after abort"
state_json | assert_json - '.recovery == "done" and .trial_switched == false'
