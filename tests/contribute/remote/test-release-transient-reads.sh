# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute release` waits for main's CI on the merged commit,
# often for half an hour, and a read of GitHub that fails meanwhile (the
# network is down for a moment, so gh cannot connect) is not a CI result:
# the listing of main's runs and the read of each run are read again after a
# pause that starts at DOTSTEWARD_CONTRIBUTE_POLL_SECONDS and doubles, and
# the release is cut once the CI is green. A run that concluded red stops
# the step at once, failed reads before it or not, and only reads that keep
# failing for DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS stop it with the message
# of a read that cannot be made. Nothing is released while the step is red,
# and the step can be run again.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
runs_url=https://github.com/$CT_UPSTREAM_SLUG/actions/runs

# no_release TAG: TAG is neither on the upstream nor a GitHub release, and the
# run is still at release.
no_release() {
  if git -C "$ct_upstream_bare" rev-parse --verify --quiet "refs/tags/$1" >/dev/null; then
    ds_fail "tagged $1 while the step was red"
  fi
  assert_call_count 0 gh 'release create*'
  assert_eq release "$(field .step)" "step after the red release"
}

# --- reads fail while main's CI runs: read again, then released ---------------------------------

published_run add-feature 0.1.1
merged=$(field .merged_sha)
hub_knob runs-flaky 2
hub_knob run-flaky 2
hub_knob main-ci-pending 2
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read the CI runs of ${merged:0:12} in $CT_UPSTREAM_SLUG; reading GitHub again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read the CI runs of ${merged:0:12} in $CT_UPSTREAM_SLUG; reading GitHub again in 2s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read run "
assert_contains "$DS_STDERR" " of ci.yml on main at ${merged:0:12} in $CT_UPSTREAM_SLUG; reading GitHub again in 2s"
assert_contains "$DS_STDOUT" "[dotsteward] ci.yml on main at ${merged:0:12}: success ($runs_url/"
assert_contains "$DS_STDOUT" "[dotsteward] main's CI is green on ${merged:0:12}"
for knob in runs-flaky run-flaky main-ci-pending; do
  [[ ! -e $rt_hub/knobs/$knob ]] || ds_fail "release did not read through the knob $knob"
done
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "tag target"
assert_call_count 1 gh "release create v0.1.1 -R $CT_UPSTREAM_SLUG *"
assert_eq upgrade "$(field .step)" "step after the release"

# --- a red run stays red, after failed reads too -----------------------------------------------

state_set '.step = "done"'
published_run second-feature 0.1.2
merged=$(field .merged_sha)
hub_knob run-flaky 1
hub_knob main-ci-ci.yml failure
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "of ci.yml on main at ${merged:0:12} in $CT_UPSTREAM_SLUG; reading GitHub again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: ci.yml on main at ${merged:0:12} concluded with failure: $runs_url/"
no_release v0.1.2
rm -f "$rt_hub/knobs/main-ci-ci.yml"

# --- reads that keep failing: red once they failed for the appear time ---------------------------

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=3
hub_knob runs-flaky 1000
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read the CI runs of ${merged:0:12} in $CT_UPSTREAM_SLUG; reading GitHub again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the CI runs of ${merged:0:12} in $CT_UPSTREAM_SLUG; nothing is released"
(($(<"$rt_hub/knobs/runs-flaky") >= 990)) || ds_fail "release read the CI runs more than a few times"
no_release v0.1.2
rm -f "$rt_hub/knobs/runs-flaky"

hub_knob run-flaky 1000
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read run "
assert_contains "$DS_STDERR" " of ci.yml on main at ${merged:0:12} in $CT_UPSTREAM_SLUG"
(($(<"$rt_hub/knobs/run-flaky") >= 990)) || ds_fail "release read the run more than a few times"
no_release v0.1.2
rm -f "$rt_hub/knobs/run-flaky"

# Once GitHub answers again, the same step releases.
reset_calls
assert_exit 0 run_contribute release
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.2^{commit}')" "tag target after the rerun"
assert_eq upgrade "$(field .step)" "step after the rerun"
