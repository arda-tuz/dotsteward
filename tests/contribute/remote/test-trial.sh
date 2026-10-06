# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q4, `dotsteward contribute trial` (SPEC 9.4 step 7, D9): the instance's
# gate (maintain scope), rebuild --switch and e2e, each with
# --framework-override git+file://<clone>?rev=<checked commit> on the
# current profile (else profiles.check); trial_switched is set before the
# switch. --build-only runs gate and rebuild --build-only only. A red step
# publishes nothing and, after a switch, runs the recovery: rebuild --switch
# and e2e without an override, so the live generation returns to the pinned
# framework. An inherited DOTSTEWARD_FRAMEWORK_OVERRIDE never reaches the
# instance commands. Refusals: no passed check, a moved or dirty branch.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
ref="git+file://$ct_clone?rev=$sha"

trial_calls() {
  call_line dotsteward-gate --scope maintain --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --switch --framework-override "$ref"
  call_line dotsteward-e2e --profile main --framework-override "$ref"
}

recovery_calls() {
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
}

# --- refusals -----------------------------------------------------------------------

# Before the framework gate passed.
state_set '.step = "fix" | .test_sha = null | .tested_tree = null'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) has not passed the framework gate; run: dotsteward contribute check"
assert_eq "" "$(instance_calls)" "instance commands before the check"
mark_checked

# A commit after the check.
clone_commit later.txt later 'feat: a later change'
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: fix/add-feature moved after the framework gate (HEAD"
assert_contains "$DS_STDERR" "checked ${sha:0:12}); run: dotsteward contribute check"
git -C "$ct_clone" reset -q --hard "$sha"

# Uncommitted work in the clone.
printf 'draft\n' >"$ct_clone/draft.txt"
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the clone $ct_clone has uncommitted changes"
rm -f "$ct_clone/draft.txt"

# Another branch checked out.
git -C "$ct_clone" switch -q main
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the clone is on main, not on the run's branch fix/add-feature"
git -C "$ct_clone" switch -q fix/add-feature

assert_exit 1 run_contribute trial --bogus
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"
assert_eq "" "$(instance_calls)" "instance commands after the refusals"
assert_eq none "$(live)" "live framework after the refusals"

# --- a red gate: nothing switched, nothing to recover ----------------------------------

stand_in_fail gate '*--framework-override*'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: trial: the gate failed with the framework at ${sha:0:12}; nothing is published"
assert_eq "$(call_line dotsteward-gate --scope maintain --framework-override "$ref")" "$(instance_calls)" "calls of a red gate"
assert_eq false "$(field .trial_switched)" "trial_switched after a red gate"
assert_eq trial "$(field .step)" "step after a red gate"
assert_eq null "$(field .trial)" "trial after a red gate"
stand_in_clear gate

# --- the full trial ---------------------------------------------------------------------

# An inherited override never reaches the instance commands: only the flag.
reset_calls
DOTSTEWARD_FRAMEWORK_OVERRIDE=path:/elsewhere assert_exit 0 run_contribute trial
assert_eq "$(trial_calls)" "$(instance_calls)" "calls of the full trial"
assert_contains "$DS_STDOUT" "[dotsteward] trial passed: this machine runs the framework at ${sha:0:12}"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute publish"
assert_eq "$ref" "$(live)" "live framework after the trial"
state_json | assert_json - ".trial == \"full\" and .trial_sha == \"$sha\" and .trial_switched == true"
state_json | assert_json - '.profile == "main" and .step == "publish" and .test_sha != null'

# Again from step publish (the trial may be repeated before publishing).
reset_calls
assert_exit 0 run_contribute trial
assert_eq "$(trial_calls)" "$(instance_calls)" "calls of a repeated trial"

# --- a red e2e after the switch: the recovery -------------------------------------------

stand_in_fail e2e '*--framework-override*'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: trial: e2e failed with the framework at ${sha:0:12}; nothing is published"
assert_contains "$DS_STDOUT" "[dotsteward] recovery done: the live generation and its framework skills use the instance's pinned framework again"
assert_eq "$(trial_calls; recovery_calls)" "$(instance_calls)" "calls of a red e2e"
assert_eq pinned "$(live)" "live framework after the recovery"
state_json | assert_json - '.trial_switched == false and .recovery == "done" and .trial == null and .step == "publish"'
stand_in_clear e2e

# --- a red switch: the recovery runs too (the switch may be half done) ---------------------

stand_in_fail rebuild '*--switch --framework-override*'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: trial: rebuild --switch failed with the framework at ${sha:0:12}"
assert_eq "$(
  call_line dotsteward-gate --scope maintain --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --switch --framework-override "$ref"
  recovery_calls
)" "$(instance_calls)" "calls of a red switch"
assert_eq false "$(field .trial_switched)" "trial_switched after the recovery of a red switch"
stand_in_clear rebuild

# --- a recovery that fails: reported, trial_switched stays --------------------------------

stand_in_fail e2e '*--framework-override*'
stand_in_fail rebuild '--profile main --switch'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: recovery failed: rebuild --switch without the override failed, so the live generation may still use the trial framework; fix the problem, then run: dotsteward contribute abort"
state_json | assert_json - '.trial_switched == true and .recovery == "failed"'
assert_eq "$ref" "$(live)" "live framework after a failed recovery"
stand_in_clear e2e
stand_in_clear rebuild

# --- build-only -------------------------------------------------------------------------------

# The problem is fixed and the generation switched back by hand: nothing is
# left to recover.
state_set '.trial_switched = false | .recovery = null'
rm -f "$rt_live"
reset_calls
assert_exit 0 run_contribute trial --build-only
assert_eq "$(
  call_line dotsteward-gate --scope maintain --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --build-only --framework-override "$ref"
)" "$(instance_calls)" "calls of the build-only trial"
assert_contains "$DS_STDOUT" "[dotsteward] trial passed (build-only): ${sha:0:12} builds on this machine; publish also needs clean-install.yml green on it"
assert_eq none "$(live)" "live framework after the build-only trial"
state_json | assert_json - ".trial == \"build-only\" and .trial_sha == \"$sha\" and .trial_switched == false"

# A red build: nothing switched, nothing recovered.
stand_in_fail rebuild '*--build-only*'
reset_calls
assert_exit 1 run_contribute trial --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: trial: rebuild --build-only failed with the framework at ${sha:0:12}"
assert_call_count 0 dotsteward-e2e
assert_call_count 0 dotsteward-rebuild '*--switch*'
stand_in_clear rebuild

# --- the profile ------------------------------------------------------------------------------

# The current profile written by rebuild wins over profiles.check, and an
# unknown one is refused.
sed -i 's/^names = \["main"\]$/names = ["main", "spare"]/' "$ct_inst/workstation.toml"
instance_commit "chore: add the spare profile"
state_set '.profile = null'
mkdir -p "$DOTSTEWARD_STATE_ROOT/current"
printf 'spare\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
reset_calls
assert_exit 0 run_contribute trial --build-only
assert_call_count 1 dotsteward-rebuild '--profile spare --build-only*'
assert_eq spare "$(field .profile)" "profile of the run"
state_set '.profile = null'
printf 'gone\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
assert_exit 1 run_contribute trial --build-only
assert_contains "$DS_STDERR" "gone"

# --- past the trial ---------------------------------------------------------------------------

state_set '.step = "release"'
assert_exit 1 run_contribute trial
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) is past the trial; next: dotsteward contribute release"
