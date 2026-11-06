# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# A red `dotsteward contribute upgrade` runs no recovery after a trial
# switch: the change is merged with the tested tree, so the trial framework
# of the live generation is what main has, and a switch back to the
# instance's pinned framework would only be undone by the next try of the
# upgrade. The run stays at its step with the machine as it is, and upgrade
# runs again once the cause is fixed: its own rebuild --switch replaces the
# trial generation. abort still runs the recovery, as for a red release.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

keeps_trial="[dotsteward] the live generation keeps the trial framework: the change is merged with the tested tree, so no recovery runs; run the step again once the cause is fixed, or end the run with abort, which returns the machine to the pinned framework"

# switched_run SLUG VERSION: a run published after a full trial that switched
# the live generation to the trial framework.
switched_run() {
  checked_run "$@"
  mark_trialled full true
  printf 'trial\n' >"$rt_live"
  assert_exit 0 run_contribute publish
}

# no_recovery: the last command switched nothing back and recorded no
# recovery.
no_recovery() {
  assert_call_count 0 dotsteward-rebuild '--profile main --switch'
  assert_call_count 0 dotsteward-e2e '--profile main'
  assert_not_contains "$DS_STDERR" "recovery"
  assert_not_contains "$DS_STDOUT" "recovery:"
  assert_eq trial "$(live)" "live framework after a red upgrade"
  state_json | assert_json - '.trial_switched == true and (.recovery // null) == null'
}

# --- the upgrade to a release, red at each step before its switch -------------------------------

switched_run add-feature 0.1.1
assert_exit 0 run_contribute release
base=$(git -C "$ct_inst" rev-parse HEAD)

# update prepare: the instance is unchanged.
stand_in_fail update 'prepare*'
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: update prepare failed; the instance is unchanged"
assert_contains "$DS_STDOUT" "$keeps_trial"
no_recovery
assert_eq upgrade "$(field .step)" "step after a red prepare"
stand_in_clear update

# The gate: the changes stay uncommitted, which would refuse a recovery.
stand_in_fail gate '--scope maintain'
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: the gate failed on the upgraded instance; the changes stay uncommitted (staged), nothing is published"
assert_contains "$DS_STDOUT" "$keeps_trial"
no_recovery
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD)" "no commit after a red gate"
stand_in_clear gate

# The switch of the upgrade itself: run again, not switched back.
stand_in_fail rebuild '--profile main --switch'
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: rebuild --switch failed; run upgrade again once it is fixed"
assert_contains "$DS_STDOUT" "$keeps_trial"
assert_call_count 1 dotsteward-rebuild '--profile main --switch'
assert_not_contains "$DS_STDERR" "recovery"
assert_eq trial "$(live)" "live framework after a red switch of the upgrade"
state_json | assert_json - '.trial_switched == true and (.recovery // null) == null and .instance_commit != null'
stand_in_clear rebuild

# Once the cause is fixed, the same upgrade moves the machine on.
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_eq pinned "$(live)" "live framework after the upgrade"
state_json | assert_json - '.step == "report" and .trial_switched == false and (.recovery // null) == null'
assert_exit 0 run_contribute report
assert_contains "$DS_STDOUT" "  recovery after the trial switch: none"
git -C "$ct_inst" push -q origin HEAD:main

# --- the upgrade to the merged commit, at step release ---------------------------------------------

switched_run second-feature 0.1.1
stand_in_fail gate '--scope maintain'
reset_calls
assert_exit 1 run_contribute upgrade --main
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: the gate failed on the upgraded instance"
assert_contains "$DS_STDOUT" "$keeps_trial"
no_recovery
assert_eq release "$(field .step)" "step after a red upgrade --main"
stand_in_clear gate
reset_calls
assert_exit 0 run_contribute upgrade --main
assert_eq pinned "$(live)" "live framework after the upgrade to the merged commit"
assert_exit 0 run_contribute report
git -C "$ct_inst" push -q origin HEAD:main

# --- a red upgrade that the user ends with abort: the recovery runs then --------------------------

switched_run third-feature 0.1.1
stand_in_fail update 'prepare*'
reset_calls
assert_exit 1 run_contribute upgrade --main
assert_contains "$DS_STDOUT" "or end the run with abort or report, which return the machine to the pinned framework"
no_recovery
stand_in_clear update
reset_calls
assert_exit 0 run_contribute abort
assert_eq "$(
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
)" "$(instance_calls)" "calls of the recovery of abort"
assert_eq pinned "$(live)" "live framework after abort"
state_json | assert_json - '.step == "done" and .outcome == "aborted" and .trial_switched == false and .recovery == "done"'
