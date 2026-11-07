# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# A framework defect blocked a maintain transaction: its instance commit is
# made but unpublished (HEAD ahead of origin) while the run fixes the
# framework. The trial runs the instance as it is, the waiting commit
# included, so its e2e checks the remote against origin's commit, an
# ancestor of HEAD (--expected-remote-base), instead of HEAD itself; so does
# the recovery after a red trial. The run then continues to the upgrade,
# which carries the commit across it (--carry) and publishes both: the
# maintain transaction continues on the fixed framework.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
ref="git+file://$ct_clone?rev=$sha"
base=$(git -C "$ct_inst" rev-parse HEAD)

# The maintain commit the defect blocked: made, not published.
printf 'example-widget\n' >"$ct_inst/components.txt"
git -C "$ct_inst" add -A
git -C "$ct_inst" commit -q -m "feat(components): add example-widget"
waiting=$(git -C "$ct_inst" rev-parse HEAD)

# --- a red e2e: the recovery checks the remote the same way ---------------------------

stand_in_fail e2e '*--framework-override*'
reset_calls
assert_exit 1 run_contribute trial
assert_contains "$DS_STDOUT" "[dotsteward] the instance has 1 commit(s) that origin/main lacks (waiting for this fix): e2e checks origin/main at ${base:0:12}, an ancestor of HEAD"
assert_eq "$(
  call_line dotsteward-gate --scope maintain --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --switch --framework-override "$ref"
  call_line dotsteward-e2e --profile main --expected-remote-base "$base" --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main --expected-remote-base "$base"
)" "$(instance_calls)" "calls of a red trial and its recovery"
state_json | assert_json - '.recovery == "done" and .trial_switched == false'
stand_in_clear e2e

# --- the trial passes with the waiting commit ------------------------------------------

reset_calls
assert_exit 0 run_contribute trial
assert_eq "$(
  call_line dotsteward-gate --scope maintain --framework-override "$ref"
  call_line dotsteward-rebuild --profile main --switch --framework-override "$ref"
  call_line dotsteward-e2e --profile main --expected-remote-base "$base" --framework-override "$ref"
)" "$(instance_calls)" "calls of the trial with a waiting commit"
assert_eq "$waiting" "$(git -C "$ct_inst" rev-parse HEAD)" "the trial leaves the waiting commit alone"

# --- publish, release, and the upgrade carries the commit ---------------------------------

assert_exit 0 run_contribute publish
assert_exit 0 run_contribute release
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "or carry them across the upgrade with: dotsteward contribute upgrade --tag v0.1.1 --carry"
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1 --carry
assert_eq "chore(dotsteward): upgrade to 0.1.1
feat(components): add example-widget" "$(git -C "$ct_inst" log --reverse --format=%s "$base..HEAD")" \
  "the upgrade, then the waiting maintain commit"
assert_call_count 1 dotsteward-txn "publish --scope maintain --expected-base $base"
assert_eq pinned "$(live)" "live framework after the upgrade"
state_json | assert_json - '.step == "report" and .carry.applied == true'
