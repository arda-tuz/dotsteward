# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q5, a red framework gate after a trial switch (SPEC 9.4, recovery after a
# trial switch): publish sends a trialled run back to check when upstream
# main moved (exit 5), with the live generation still on the trial
# framework. A privacy hard stop (exit 4) or a failed nix flake check
# (exit 1) of that check ends the run's way to publish, so check runs the
# recovery (rebuild --switch and e2e without an override) and keeps its own
# exit status; a failed recovery is recorded and resumed by the next red or
# by abort. A red check without a trial switch recovers nothing.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run guarded

recovery_calls() {
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
}

# trialled: a passed check and a full trial of the branch head; the live
# generation runs the trial framework.
trialled() {
  local sha
  assert_exit 0 run_contribute check
  sha=$(git -C "$ct_clone" rev-parse HEAD)
  assert_exit 0 run_contribute trial
  assert_eq "git+file://$ct_clone?rev=$sha" "$(live)" "live framework after the trial"
  assert_eq true "$(field .trial_switched)" "trial_switched after the trial"
}

# --- a red check without a trial switch recovers nothing --------------------------------

hub_knob flake-check fail
reset_calls
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix flake check failed in $ct_clone"
assert_eq "" "$(instance_calls)" "instance commands of a red check without a trial switch"
assert_eq none "$(live)" "live framework after a red check without a trial switch"
state_json | assert_json - '.step == "check" and .test_sha == null and .trial_switched == false and .recovery == null'
hub_knob flake-check pass

# --- publish sends the trialled run back to check: the trial generation stays -------------

trialled
trial_ref=$(live)
push_upstream other.txt other 'feat: an unrelated change'
reset_calls
assert_exit 5 run_contribute publish
assert_eq "$trial_ref" "$(live)" "live framework after the rebase"
assert_eq "" "$(instance_calls)" "instance commands of the rebase"
state_json | assert_json - '.step == "check" and .trial_switched == true'

# --- a privacy hard stop of that check: recovered, still exit 4 -----------------------------

clone_commit notes.md 'the synthetic-private-term appears here' 'docs: add notes'
reset_calls
assert_exit 4 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: privacy hard stop"
assert_contains "$DS_STDOUT" "[dotsteward] recovery: switching the live generation back to the instance's pinned framework"
assert_contains "$DS_STDOUT" "[dotsteward] recovery done: the live generation and its framework skills use the instance's pinned framework again"
assert_not_contains "$DS_STDOUT$DS_STDERR" "synthetic-private-term"
assert_eq "$(recovery_calls)" "$(instance_calls)" "calls of the recovery after a privacy stop"
assert_call_count 0 nix 'flake check*'
assert_eq pinned "$(live)" "live framework after a privacy stop"
state_json | assert_json - '.step == "check" and .test_sha == null and .tested_tree == null
  and .trial_switched == false and .recovery == "done"'

# Recovered once: the next red check has nothing to recover.
reset_calls
assert_exit 4 run_contribute check
assert_eq "" "$(instance_calls)" "instance commands of a second privacy stop"
git -C "$ct_clone" reset -q --hard HEAD~1

# --- a recovery that fails keeps the privacy stop's status ----------------------------------

trialled
trial_ref=$(live)
clone_commit notes.md 'the synthetic-private-term appears here' 'docs: add notes'
stand_in_fail rebuild '--profile main --switch'
reset_calls
assert_exit 4 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: privacy hard stop"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: recovery failed: rebuild --switch without the override failed"
assert_eq "$(call_line dotsteward-rebuild --profile main --switch)" "$(instance_calls)" "calls of a failed recovery"
assert_eq "$trial_ref" "$(live)" "live framework after a failed recovery"
state_json | assert_json - '.step == "check" and .trial_switched == true and .recovery == "failed"'
stand_in_clear rebuild
git -C "$ct_clone" reset -q --hard HEAD~1

# --- a failed nix flake check after a trial switch: recovered, still exit 1 ------------------

hub_knob flake-check fail
reset_calls
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix flake check failed in $ct_clone"
assert_eq "$(recovery_calls)" "$(instance_calls)" "calls of the recovery after a red nix flake check"
assert_eq pinned "$(live)" "live framework after a red nix flake check"
state_json | assert_json - '.step == "check" and .test_sha == null and .trial_switched == false and .recovery == "done"'
hub_knob flake-check pass

# The run goes on: check, trial and publish again.
trialled
reset_calls
assert_exit 0 run_contribute publish
assert_eq "$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')" "$(upstream_tree)" "tree of upstream main after the publish"
