# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute release` in owner mode:
# the release VERSION of the merged commit names, only when it is the next
# release after the newest stable v* tag of the upstream for the commits
# since the release they are based on (semantic versioning from 0.0.0
# without any tag; publish checks it before the merge, release again as
# the last safety net); an annotated tag on the merged commit with a UTC
# tagger date, pushed, then `gh release create TAG --notes-file NOTES
# --verify-tag` with the grouped notes of the commits since the previous
# release. Re-runs reuse the tag and the release; a tag elsewhere is
# refused.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

# --- before publish -------------------------------------------------------------------

checked_run add-feature
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) is not published yet; next: dotsteward contribute trial"

state_set '.step = "done"'

# --- VERSION must be the next release ----------------------------------------------------

# publish already refuses a VERSION that is neither the base release nor
# the next one; release checks it again, as the last safety net, for a
# release tagged after the merge: v0.2.0 elsewhere makes the next release
# v0.2.1, and v0.1.1 on an older commit leaves nothing to release here
# (the next release bundles the run).
published_run late-tag
merged=$(field .merged_sha)
git -C "$ct_upstream_bare" tag -a v0.2.0 -m 'dotsteward v0.2.0' "$merged^"
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.1.1 at the merged commit ${merged:0:12}, but the next release is v0.2.1 (after v0.2.0, as the commits decide): set it with tools/version.sh bump in a release commit; nothing is released"
assert_eq release "$(field .step)" "step after a VERSION mismatch"
assert_call_count 0 gh 'release *'
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.1.1 >/dev/null; then
  ds_fail "tagged despite the VERSION mismatch"
fi
git -C "$ct_upstream_bare" tag -d v0.2.0 >/dev/null

git -C "$ct_upstream_bare" tag -a v0.1.1 -m 'dotsteward v0.1.1' "$merged^"
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no release is pending at the merged commit ${merged:0:12}: VERSION is still 0.1.1, the release it is based on, so the next release bundles it (release trains)"
assert_eq release "$(field .step)" "step without a pending release"
assert_call_count 0 gh 'release *'
git -C "$ct_upstream_bare" tag -d v0.1.1 >/dev/null
state_set '.step = "done"'

# --- the release ------------------------------------------------------------------------

published_run add-other
merged=$(field .merged_sha)
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] tagged ${merged:0:12} as v0.1.1 on $CT_UPSTREAM_SLUG"
assert_contains "$DS_STDOUT" "[dotsteward] released v0.1.1: https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.1.1"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute upgrade --tag v0.1.1"
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "tag target"
assert_eq tag "$(git -C "$ct_upstream_bare" cat-file -t refs/tags/v0.1.1)" "the tag is annotated"
tagger=$(git -C "$ct_upstream_bare" cat-file -p refs/tags/v0.1.1 | sed -n 's/^tagger //p')
assert_contains "$tagger" "dotsteward-test <$CT_NOREPLY>"
[[ $tagger == *' +0000' ]] || ds_fail "the tagger date is not UTC: $tagger"
assert_call_count 1 gh "release create v0.1.1 -R $CT_UPSTREAM_SLUG --title v0.1.1 --notes-file * --verify-tag"
# The notes of the train since v0.1.0: both runs.
notes=$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v0.1.1.notes")
assert_contains "$notes" "## Fixes"$'\n\n'"- example: late-tag ("
assert_contains "$notes" "- example: add-other ($(git -C "$ct_clone" log -1 --format=%h "$merged"))"
assert_contains "$notes" "## Other"$'\n\n'"- example: cover late-tag ("
state_json | assert_json - '.tag == "v0.1.1" and .step == "upgrade"'

# A released run answers without doing anything.
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "is already released: v0.1.1"
assert_calls

# --- an interrupted release resumes with its tag ------------------------------------------

state_set '.step = "release"'
reset_calls
assert_exit 0 run_contribute release
assert_call_count 0 gh 'release create*'
assert_contains "$DS_STDOUT" "[dotsteward] the release v0.1.1 exists"

# The tag lost locally is fetched again; one elsewhere on the remote is refused.
state_set '.step = "release"'
git -C "$ct_clone" tag -d v0.1.1 >/dev/null
rm -f "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v0.1.1"
assert_exit 0 run_contribute release
assert_eq "$merged" "$(git -C "$ct_clone" rev-parse 'refs/tags/v0.1.1^{commit}')" "local tag after the fetch"
assert_call_count 1 gh 'release create v0.1.1 *'

state_set '.step = "release"'
git -C "$ct_upstream_bare" tag -f -a v0.1.1 -m moved "$merged^" >/dev/null
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the tag v0.1.1 already exists on origin at "
assert_contains "$DS_STDERR" "not at the merged commit ${merged:0:12}"

# --- the first release of a repository without tags ---------------------------------------

# Semantic versioning from 0.0.0: the history holds a feat, so 0.1.0.
for tag in v0.1.0 v0.1.1; do
  git -C "$ct_upstream_bare" tag -d "$tag" >/dev/null
  git -C "$ct_clone" tag -d "$tag" >/dev/null 2>&1 || true
done
state_set '.step = "done"'
checked_run first-release 0.1.0
mark_trialled full false
assert_exit 0 run_contribute publish
reset_calls
assert_exit 0 run_contribute release
assert_eq "$(field .merged_sha)" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.0^{commit}')" "first tag"
assert_call_count 1 gh "release create v0.1.0 -R $CT_UPSTREAM_SLUG *"
