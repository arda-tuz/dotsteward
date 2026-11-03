# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# A red `dotsteward contribute release` runs no recovery after a trial
# switch: the change is merged, and the merged commit has the tested tree,
# so the trial framework of the live generation is what main has, and a
# switch back to the instance's pinned framework would only be undone by
# the upgrade. The run stays at release with the machine as it is; release
# runs again once the cause is fixed, and abort or report (a run that ends
# at publish) still run the recovery when they end the run.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

# switched_run SLUG VERSION: a run published after a full trial that
# switched the live generation to the trial framework.
switched_run() {
  checked_run "$@"
  mark_trialled full true
  printf 'trial\n' >"$rt_live"
  assert_exit 0 run_contribute publish
}

recovery_calls() {
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
}

# --- main's CI is red: the release is red, the trial switch stays --------------------------------

switched_run add-feature 0.1.1
merged=$(field .merged_sha)
hub_knob main-ci-ci.yml failure
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: ci.yml on main at ${merged:0:12} concluded with failure: "
assert_contains "$DS_STDOUT" "[dotsteward] the live generation keeps the trial framework: the change is merged with the tested tree, so no recovery runs"
assert_not_contains "$DS_STDOUT" "recovery done"
assert_eq "" "$(instance_calls)" "instance commands of a red release"
assert_eq trial "$(live)" "live framework after a red release"
state_json | assert_json - '.step == "release" and .tag == null and .trial_switched == true and .recovery == null'

# Once main's CI is green, release runs again; the upgrade will switch to it.
rm -f -- "$rt_hub/knobs/main-ci-ci.yml"
reset_calls
assert_exit 0 run_contribute release
assert_eq "" "$(instance_calls)" "instance commands of the release"
assert_eq trial "$(live)" "live framework after the release"
state_json | assert_json - '.step == "upgrade" and .tag == "v0.1.1" and .trial_switched == true'

# --- a red release that the user ends with abort: the recovery runs then -------------------------

state_set '.step = "done"'
switched_run second-feature 0.1.2
hub_knob main-ci none
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no run of ci.yml privacy.yml appeared on main of $CT_UPSTREAM_SLUG"
assert_eq "" "$(instance_calls)" "instance commands of a red release without main's CI"
assert_eq trial "$(live)" "live framework after a red release without main's CI"
reset_calls
assert_exit 0 run_contribute abort
assert_eq "$(recovery_calls)" "$(instance_calls)" "calls of the recovery of abort"
assert_eq pinned "$(live)" "live framework after abort"
state_json | assert_json - '.step == "done" and .outcome == "aborted" and .trial_switched == false and .recovery == "done"'
