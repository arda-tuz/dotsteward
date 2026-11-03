# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute release` cuts a release only from a main commit
# whose CI is green: the push runs of ci.yml (lint and the full check) and
# privacy.yml on main for the merged commit. It waits for them to appear
# (DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS) and to finish
# (DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS); a missing, red or unfinished
# run releases nothing (no tag, no GitHub release) and keeps the run at
# release. A fork without GitHub Actions has no CI to wait for.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=3
export DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS=6

rt_setup owner
published_run add-feature
merged=$(field .merged_sha)
runs_url=https://github.com/$CT_UPSTREAM_SLUG/actions/runs

no_tag() {
  if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.1.1 >/dev/null; then
    ds_fail "tagged v0.1.1 $1"
  fi
  assert_call_count 0 gh 'release create*'
  assert_eq release "$(field .step)" "step $1"
}

# --- main's CI has not started: nothing is released ------------------------------------------

hub_knob main-ci none
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no run of ci.yml privacy.yml appeared on main of $CT_UPSTREAM_SLUG for ${merged:0:12} within 3s; a release needs main's CI green on its commit, nothing is released"
no_tag "without main's CI"

# --- the full check failed on main: nothing is released ----------------------------------------

hub_knob main-ci success
hub_knob main-ci-ci.yml failure
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: ci.yml on main at ${merged:0:12} concluded with failure: $runs_url/"
assert_contains "$DS_STDERR" "; nothing is released"
no_tag "with the full check red on main"

# --- the full check still runs on main: waited for, then released --------------------------------

rm -f "$rt_hub/knobs/main-ci-ci.yml"
hub_knob main-ci-pending 3
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] waiting for main's CI on ${merged:0:12} (ci.yml privacy.yml)"
assert_contains "$DS_STDOUT" "[dotsteward] ci.yml on main at ${merged:0:12}: success ($runs_url/"
assert_contains "$DS_STDOUT" "[dotsteward] privacy.yml on main at ${merged:0:12}: success ($runs_url/"
assert_contains "$DS_STDOUT" "[dotsteward] main's CI is green on ${merged:0:12}"
[[ ! -e $rt_hub/knobs/main-ci-pending ]] || ds_fail "release did not wait for main's CI to finish"
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "tag target"
assert_call_count 1 gh "release create v0.1.1 -R $CT_UPSTREAM_SLUG *"
assert_eq upgrade "$(field .step)" "step after the release"

# --- a full check that never finishes: nothing is released -------------------------------------

state_set '.step = "done"'
published_run second-feature 0.1.2
merged=$(field .merged_sha)
hub_knob main-ci-pending 1000
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: ci.yml on main at ${merged:0:12} did not finish within 6s: $runs_url/"
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.1.2 >/dev/null; then
  ds_fail "tagged v0.1.2 with main's CI unfinished"
fi
rm -f "$rt_hub/knobs/main-ci-pending"

# --- an interrupted release whose tag is pushed: no second wait ----------------------------------

assert_exit 0 run_contribute release
state_set '.step = "release"'
hub_knob main-ci none
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] the release v0.1.2 exists"
assert_call_count 0 gh '*actions/runs*'

# --- a fork without GitHub Actions: no CI to wait for ---------------------------------------------

rm -f "$rt_hub/knobs/main-ci"
state_set '.step = "done"'
rm -rf -- "$ct_clone"
rt_setup fork
checked_run fork-feature 0.1.3
mark_trialled full false
hub_knob actions false
assert_exit 0 run_contribute publish
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: GitHub Actions are disabled on $CT_FORK_SLUG, so main has no CI; releasing on the framework gate and the trial"
assert_eq "$(field .merged_sha)" "$(git -C "$ct_fork_bare" rev-parse 'refs/tags/v0.1.3^{commit}')" "tag on the fork"
assert_call_count 0 gh '*actions/runs*'
