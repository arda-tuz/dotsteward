# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q5, `dotsteward contribute abort` (SPEC 9.4, recovery after a trial
# switch): ends the run (step done, outcome aborted); after a trial switch
# it first runs rebuild --switch and e2e without an override, so the live
# generation returns to the pinned framework. A recovery that fails keeps
# the run open; abort repeated resumes it (only the e2e once the rebuild
# passed). An open pull request is left alone and named. A finished run
# cannot be aborted.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

# --- without a trial switch: nothing to recover ----------------------------------------

checked_run plain
reset_calls
assert_exit 0 run_contribute abort
assert_contains "$DS_STDOUT" "[dotsteward] aborted run $(current_id) at step trial"
assert_eq "" "$(instance_calls)" "instance commands of a plain abort"
state_json | assert_json - '.step == "done" and .outcome == "aborted"'
assert_exit 1 run_contribute abort
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) is already finished"

# A new run with the same slug starts over (the aborted one is finished).
old=$(current_id)
git -C "$ct_clone" switch -q main
git -C "$ct_clone" branch -q -D fix/plain
sleep 1
start_run plain
[[ $(current_id) != "$old" ]] || ds_fail "start resumed the aborted run"

# --- after a trial switch: the recovery, then done -----------------------------------------

checked_run switched
mark_trialled full true
printf 'switched\n' >"$rt_live"
# A pull request is open (CI was red).
hub_knob checks fail
assert_exit 1 run_contribute publish
printf 'switched\n' >"$rt_live"
state_set '.trial_switched = true'
pr=$(field .pr)

# The recovery fails first: the run stays open.
stand_in_fail e2e '--profile main'
reset_calls
assert_exit 1 run_contribute abort
assert_contains "$DS_STDERR" "[dotsteward] ERROR: recovery: the live generation uses the pinned framework again, but its e2e failed"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: abort stopped: the recovery did not finish; run abort again once the problem is fixed"
assert_eq publish "$(field .step)" "step after a failed recovery"
assert_eq failed "$(field .recovery)" "recovery after a failed e2e"
stand_in_clear e2e

# The generation was switched back before the e2e failed: once e2e passes,
# abort runs the rest of the recovery (its e2e) and ends the run.
assert_eq false "$(field .trial_switched)" "trial_switched after the rebuild of a failed recovery"
assert_eq pinned "$(live)" "live framework after the rebuild of a failed recovery"
reset_calls
assert_exit 0 run_contribute abort --id "$(current_id)"
assert_eq "$(call_line dotsteward-e2e --profile main)" "$(instance_calls)" "calls of the resumed recovery"
assert_contains "$DS_STDOUT" "[dotsteward] recovery done: the live generation and its framework skills use the instance's pinned framework again"
assert_contains "$DS_STDOUT" "[dotsteward] the pull request $pr stays open; close it if it is no longer wanted"
assert_eq pinned "$(live)" "live framework after abort"
state_json | assert_json - '.step == "done" and .outcome == "aborted" and .trial_switched == false and .recovery == "done"'

# --- report refuses a run before its upgrade ---------------------------------------------------

checked_run early
assert_exit 1 run_contribute report
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) has no report yet; next: dotsteward contribute trial"

# An aborted run reports its outcome.
assert_exit 0 run_contribute report --id "$old"
assert_contains "$DS_STDOUT" "[dotsteward] contribute run $old: aborted"
