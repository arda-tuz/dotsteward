# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# The release workflow (release.yml) cuts a pending release as soon as
# main's CI is green on the merged commit, so it often cuts the release of
# a run while `dotsteward contribute release` still waits for that CI, and
# it may also win the push of the tag or the creation of the GitHub
# release. release reads origin's tag again once main's CI is green: a tag
# on the merged commit is the run's release, recorded without a push or a
# second GitHub release (the clone takes origin's tag), and nothing is red,
# so a trial switch stays and no recovery runs. A tag on another commit is
# red and changes nothing: no local tag, no push, no GitHub release, no
# recorded tag. A tag or a GitHub release that the workflow made between
# the read and the push or the create counts as done once origin shows it.
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

# no_local_tag TAG: the clone holds no tag TAG.
no_local_tag() {
  if git -C "$ct_clone" rev-parse --verify --quiet "refs/tags/$1" >/dev/null; then
    ds_fail "the clone holds a tag $1"
  fi
}

release_file() {
  printf '%s\n' "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_$1"
}

# --- the workflow cuts the release while release waits for main's CI ---------------------------

switched_run add-feature 0.1.1
merged=$(field .merged_sha)
hub_knob main-ci-pending 2
hub_knob release-workflow v0.1.1
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] waiting for main's CI on ${merged:0:12} (ci.yml privacy.yml)"
assert_contains "$DS_STDOUT" "[dotsteward] the release workflow cut v0.1.1 on ${merged:0:12} while this step waited for main's CI: it is the run's release"
assert_contains "$DS_STDOUT" "[dotsteward] the release v0.1.1 exists"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute upgrade --tag v0.1.1"
assert_not_contains "$DS_STDOUT" "[dotsteward] tagged "
assert_call_count 0 gh 'release create*'
# The workflow's tag (a lightweight one) stays, and the clone holds it too.
assert_eq commit "$(git -C "$ct_upstream_bare" cat-file -t refs/tags/v0.1.1)" "the type of the upstream's tag"
assert_eq "$merged" "$(git -C "$ct_clone" rev-parse refs/tags/v0.1.1)" "the clone's tag"
assert_eq "" "$(instance_calls)" "instance commands of the release"
assert_eq trial "$(live)" "live framework after the release"
state_json | assert_json - '.tag == "v0.1.1" and .step == "upgrade" and .trial_switched == true and .recovery == null'

# --- a tag on another commit appears during the wait: red, nothing changed -----------------------

state_set '.step = "done"'
switched_run second-feature 0.1.2
merged=$(field .merged_sha)
other=$(git -C "$ct_upstream_bare" rev-parse "$merged^")
hub_knob release-workflow "v0.1.2 $other"
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the tag v0.1.2 already exists on origin at ${other:0:12}, not at the merged commit ${merged:0:12}; nothing is released"
assert_not_contains "$DS_STDERR" "pushing the tag"
no_local_tag v0.1.2
assert_eq "$other" "$(git -C "$ct_upstream_bare" rev-parse refs/tags/v0.1.2)" "the upstream's tag after the red release"
assert_call_count 0 gh 'release create*'
assert_eq "" "$(instance_calls)" "instance commands of the red release"
assert_eq trial "$(live)" "live framework after the red release"
state_json | assert_json - '.tag == null and .step == "release" and .trial_switched == true and .recovery == null'

# Nothing to clean up in the clone: once the wrong tag is gone, release
# tags the merged commit itself.
git -C "$ct_upstream_bare" tag -d v0.1.2 >/dev/null
rm -f -- "$(release_file v0.1.2)"
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] tagged ${merged:0:12} as v0.1.2 on $CT_UPSTREAM_SLUG"
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.2^{commit}')" "tag target after the rerun"
assert_call_count 1 gh 'release create v0.1.2 *'
state_json | assert_json - '.tag == "v0.1.2" and .step == "upgrade"'

# --- the workflow tags the merged commit between the read and the push ---------------------------

state_set '.step = "done"'
switched_run third-feature 0.1.3
merged=$(field .merged_sha)
hub_knob push-tag taken
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] the release workflow cut v0.1.3 on ${merged:0:12} first: it is the run's release"
assert_not_contains "$DS_STDOUT" "[dotsteward] tagged "
assert_contains "$DS_STDOUT" "[dotsteward] released v0.1.3: https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.1.3"
[[ ! -e $rt_hub/knobs/push-tag ]] || ds_fail "release did not push the tag"
assert_eq commit "$(git -C "$ct_upstream_bare" cat-file -t refs/tags/v0.1.3)" "the type of the upstream's tag after the lost push"
assert_eq "$merged" "$(git -C "$ct_clone" rev-parse refs/tags/v0.1.3)" "the clone's tag after the lost push"
assert_eq "" "$(instance_calls)" "instance commands of the release after the lost push"
state_json | assert_json - '.tag == "v0.1.3" and .step == "upgrade" and .trial_switched == true'

# --- the workflow creates the GitHub release between the read and the create ---------------------

state_set '.step = "done"'
switched_run fourth-feature 0.1.4
merged=$(field .merged_sha)
hub_knob release-race true
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] tagged ${merged:0:12} as v0.1.4 on $CT_UPSTREAM_SLUG"
assert_contains "$DS_STDOUT" "[dotsteward] the release v0.1.4 exists: the release workflow created it meanwhile"
assert_call_count 1 gh 'release create v0.1.4 *'
assert_eq "" "$(instance_calls)" "instance commands of the release after the lost create"
state_json | assert_json - '.tag == "v0.1.4" and .step == "upgrade" and .trial_switched == true'
