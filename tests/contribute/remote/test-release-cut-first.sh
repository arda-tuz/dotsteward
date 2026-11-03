# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# The release workflow (release.yml, `tools/version.sh release`) cuts a
# pending release by itself once main's CI is green on the merged commit,
# so it may cut the release of a run before `dotsteward contribute release`
# runs. release then finds the release tag on the merged commit: once
# main's CI is green on it, it records that tag as the run's release,
# creates no second tag or GitHub release (a tag without its GitHub release
# gets one), and the run continues to the upgrade to that tag. A red main
# CI records nothing and keeps the run at release.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export RELEASE_WAIT_SECONDS=3
export RELEASE_POLL_SECONDS=1

rt_setup owner
mkdir -p "$rt_hub/releases"
checkout=$DS_TEST_ROOT/release-checkout
git clone -q "$ct_upstream_bare" "$checkout"

# release_ci: the workflow's step on the merged commit, after ci passed on
# main (a checkout with the tags, as actions/checkout fetches them).
release_ci() {
  local merged
  merged=$(field .merged_sha)
  git -C "$checkout" fetch -q --tags origin main
  git -C "$checkout" checkout -q --detach "$merged"
  "$DS_REPO_ROOT/tools/version.sh" release --root "$checkout" --repo "$CT_UPSTREAM_SLUG" --rev "$merged"
}

# --- the workflow cut the tag and the GitHub release first ------------------------------------

published_run add-feature 0.1.1
merged=$(field .merged_sha)
assert_exit 0 release_ci
assert_contains "$DS_STDOUT" "[version] released v0.1.1 at ${merged:0:12}"
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] the merged commit ${merged:0:12} carries its release tag v0.1.1 already (cut by the release workflow or by hand)"
assert_contains "$DS_STDOUT" "[dotsteward] main's CI is green on ${merged:0:12}"
assert_contains "$DS_STDOUT" "[dotsteward] the release v0.1.1 exists"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute upgrade --tag v0.1.1"
assert_call_count 0 gh 'release create*'
assert_eq "$merged" "$(git -C "$ct_clone" rev-parse 'refs/tags/v0.1.1^{commit}')" "the workflow's tag in the clone"
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "the tag on the upstream"
state_json | assert_json - '.tag == "v0.1.1" and .step == "upgrade"'

# The upgrade follows that release.
write_flake github
assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_contains "$(cat "$ct_inst/flake.nix")" "github:$CT_UPSTREAM_SLUG/v0.1.1"
state_json | assert_json - '.step == "report"'
assert_exit 0 run_contribute report

# --- a tag on the merged commit without its GitHub release: the release is completed -----------

published_run second-feature 0.1.2
merged=$(field .merged_sha)
git -C "$ct_upstream_bare" tag v0.1.2 "$merged"
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] the merged commit ${merged:0:12} carries its release tag v0.1.2 already"
assert_contains "$DS_STDOUT" "[dotsteward] released v0.1.2: https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.1.2"
assert_call_count 1 gh "release create v0.1.2 -R $CT_UPSTREAM_SLUG --title v0.1.2 --notes-file * --verify-tag"
assert_contains "$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v0.1.2.notes")" "- example: second-feature ("
state_json | assert_json - '.tag == "v0.1.2" and .step == "upgrade"'

# --- a tag on the merged commit while main's CI is red: nothing recorded --------------------------

state_set '.step = "done"'
published_run third-feature 0.1.3
merged=$(field .merged_sha)
git -C "$ct_upstream_bare" tag v0.1.3 "$merged"
hub_knob main-ci-ci.yml failure
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: ci.yml on main at ${merged:0:12} concluded with failure: "
assert_contains "$DS_STDERR" "; nothing is released"
assert_call_count 0 gh 'release create*'
state_json | assert_json - '.tag == null and .step == "release"'
rm -f "$rt_hub/knobs/main-ci-ci.yml"
assert_exit 0 run_contribute release
state_json | assert_json - '.tag == "v0.1.3" and .step == "upgrade"'
