# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute upgrade --carry` before its first commit. The fetch of
# origin is made again after a network failure. A red `update prepare` after
# the reset says where the instance and the carried commits are (the instance
# is not unchanged), and such a run no longer ends at publish: its commits are
# only in the saved ref, so report refuses, and abort names them.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
published_run add-feature 0.1.0
id=$(current_id)
base=$(git -C "$ct_inst" rev-parse HEAD)
printf 'waiting\n' >"$ct_inst/waiting.txt"
git -C "$ct_inst" add waiting.txt
git -C "$ct_inst" commit -q -m 'feat: a commit that waits for the fix'
waiting=$(git -C "$ct_inst" rev-parse HEAD)

stand_in_fail update 'prepare*'
network_plan x
reset_calls
assert_exit 1 run_contribute upgrade --main --carry
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch origin/main of the instance; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: update prepare failed; the instance is at origin/main, and the carried commits stay saved as refs/dotsteward/carry/$id"
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD)" "the instance after the reset"
assert_eq "$waiting" "$(git -C "$ct_inst" rev-parse "refs/dotsteward/carry/$id")" "the saved commits"
state_json | assert_json - '.instance_base == null and .carry != null and .step == "release"'

assert_exit 1 run_contribute report
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the upgrade of run $id has started, so the run no longer ends at publish; finish it with: dotsteward contribute upgrade --main --carry, or end the run with: dotsteward contribute abort"

assert_exit 0 run_contribute abort
assert_contains "$DS_STDOUT" "[dotsteward] the instance commits carried across the upgrade stay saved as refs/dotsteward/carry/$id (${waiting:0:12})"
