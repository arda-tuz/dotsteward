# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` and `release` over a network that drops
# for a moment: a `git ls-remote`, a fetch or a push that fails for the
# network says nothing about the change, so it is made again after a pause
# that starts at DOTSTEWARD_CONTRIBUTE_POLL_SECONDS and doubles, and only
# failures that last DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS stop the step, with
# the machine as it is: no recovery, since the failure says nothing about the
# change, and the step runs again once the network is back. A push reads its
# ref again first: a push whose answer was lost has landed.
# test-publish-refused.sh holds what is never made again.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1

# switched_run SLUG VERSION: a checked run after a full trial that switched
# the live generation.
switched_run() {
  checked_run "$@"
  mark_trialled full true
  printf 'trial\n' >"$rt_live"
}

# --- every read and push of publish loses its first connection ---------------------------------

switched_run add-feature 0.1.1
sha=$(git -C "$ct_clone" rev-parse HEAD)
# A read takes x. (dropped, served); a push x.x.. (its read dropped and
# served, the push dropped, the read served, the push served). In order: the
# tags and the fetch of main; the branch; the fetch and the tags again; main;
# the fetch of the verification and the tags of the last line.
network_plan x.x.x.x..x.x.x.x..x.x.
: >"$DS_FAKESSH_LOG"
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "ssh: connect to host github.com port 22: Connection timed out"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/fix/add-feature on origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/main on origin; trying again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] published: $pr_url merged as ${sha:0:12}"
assert_eq "$sha" "$(upstream_main)" "upstream main after the drops"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse refs/heads/fix/add-feature)" "pushed branch"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and main, one each"
assert_eq "" "$(instance_calls)" "a publish that survived the drops runs no recovery"
assert_eq trial "$(live)" "live framework after the drops"
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$sha\" and .trial_switched == true"

# --- the same for release: the tags, the push of the tag, its fetch ----------------------------

# The tags, the tag on origin before and after main's CI, the tag, and the
# tags of the release notes.
network_plan x.x.x.x.x..x.
: >"$DS_FAKESSH_LOG"
assert_exit 0 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/tags/v0.1.1 on origin; trying again in 1s"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "the tag after the drops"
assert_eq 1 "$(pushes_served)" "pushes served: the tag"
assert_eq upgrade "$(field .step)" "step after the release"
state_set '.step = "done"'
network_plan ''

# --- a longer drop: the pause doubles ----------------------------------------------------------

switched_run second-feature 0.1.2
sha=$(git -C "$ct_clone" rev-parse HEAD)
network_plan xx
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 2s"
assert_eq "$sha" "$(upstream_main)" "upstream main after a longer drop"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- the answer of a push is lost: the push landed, and is not made again ---------------------

switched_run third-feature 0.1.3
sha=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob push-lost refs/heads/fix/third-feature
: >"$DS_FAKESSH_LOG"
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/fix/third-feature on origin; trying again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] fix/third-feature is already ${sha:0:12} on origin"
assert_eq "$sha" "$(upstream_main)" "upstream main after the lost answer of the branch"
assert_eq 2 "$(pushes_served)" "pushes served: the branch, whose answer was lost, and main"

hub_knob push-lost refs/tags/v0.1.3
: >"$DS_FAKESSH_LOG"
assert_exit 0 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/tags/v0.1.3 on origin; trying again in 1s"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.3^{commit}')" "the tag after its lost answer"
assert_eq 1 "$(pushes_served)" "pushes served: the tag, whose answer was lost"
state_set '.step = "done"'

switched_run fourth-feature 0.1.4
sha=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob push-lost refs/heads/main
: >"$DS_FAKESSH_LOG"
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/main on origin; trying again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] main of $CT_UPSTREAM_SLUG is already ${sha:0:12}"
assert_eq "$sha" "$(upstream_main)" "upstream main after its lost answer"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and main, whose answer was lost"
assert_eq "" "$(instance_calls)" "a lost answer runs no recovery"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- the reads of the pull request on GitHub fail for a moment ------------------------------------

switched_run flaky-feature 0.1.5
sha=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob pr-flaky 1
hub_knob checks fail
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read the pull requests of $CT_UPSTREAM_SLUG; reading GitHub again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: CI is not green on "
pr=$(field .pr)
hub_knob checks pass
hub_knob pr-flaky 1
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read $pr; reading GitHub again in 1s"
assert_eq "$sha" "$(upstream_main)" "upstream main after failed reads of the pull request"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- failures that last: red once they lasted the appear time, then the rerun passes --------------

switched_run lasting-feature 0.1.6
sha=$(git -C "$ct_clone" rev-parse HEAD)

# stays_down PLAN WHAT: with the connections of PLAN, publish stops once the
# failures lasted the appear time: red, naming WHAT and the network, with the
# machine as it is and the run still at publish.
stays_down() {
  network_plan "$1"
  export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=5
  reset_calls
  assert_exit 1 run_contribute publish
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: $2"
  assert_contains "$DS_STDOUT" "[dotsteward] the network kept failing, so the machine stays as it is; run the step again once the network is back"
  assert_not_contains "$DS_STDOUT" "recovery"
  assert_eq "" "$(instance_calls)" "a network that stays down runs no recovery"
  assert_eq trial "$(live)" "live framework after a network that stayed down"
  state_json | assert_json - '.step == "publish" and .trial_switched == true and (.recovery // null) == null'
  network_plan ''
  export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30
}

# The read of the branch: after the tags and the fetch of main.
stays_down ..xxxxxxxxxx "pushing fix/lasting-feature to origin failed; nothing is published"
# The read before the push of main: after the tags, the fetch, the branch (its
# read and its push), the fetch and the tags again.
stays_down ......xxxxxxxxxx "pushing ${sha:0:12} to main of $CT_UPSTREAM_SLUG failed"
# A read of GitHub.
hub_knob pr-flaky 1000
stays_down '' "cannot read $(field .pr)"
rm -f -- "$rt_hub/knobs/pr-flaky"
# Before any of it: the tags.
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=5
DS_FAKESSH_FAIL=1 assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the tags of origin"
assert_eq publish "$(field .step)" "step after a network that stayed down"
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30
# It is back.
network_plan xx
assert_exit 0 run_contribute publish
assert_eq "$sha" "$(upstream_main)" "upstream main once the network is back"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- the answer of the push of main is lost and main moves on: the push landed --------------------

# The next attempt no longer fast-forwards, but the tested commit is on main,
# so the run is published: no rebase, and no way back to check.
switched_run moved-feature 0.1.7
sha=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob push-lost 'refs/heads/main moved'
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] ${sha:0:12} is on main of $CT_UPSTREAM_SLUG: its push landed although its answer was lost"
assert_not_contains "$DS_STDOUT" "rebasing"
[[ $(upstream_main) != "$sha" ]] || ds_fail "main did not move on"
git -C "$ct_upstream_bare" merge-base --is-ancestor "$sha" refs/heads/main || ds_fail "the tested commit is not on main"
assert_eq "$sha" "$(git -C "$ct_clone" rev-parse HEAD)" "the branch stays the tested commit"
assert_eq "" "$(instance_calls)" "a push that landed runs no recovery"
assert_eq trial "$(live)" "live framework after a push that landed"
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$sha\" and .test_sha == \"$sha\""
