# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q5, `dotsteward contribute release` in owner mode (SPEC 9.4 step 9, D11):
# the next patch tag after the newest stable v* tag of the upstream (v0.0.1
# without any), only when VERSION of the merged commit equals it; an
# annotated tag on the merged commit with a UTC tagger date, pushed, then
# `gh release create TAG --generate-notes --verify-tag`. Re-runs reuse the
# tag and the release; a tag elsewhere is refused.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

# --- before publish -------------------------------------------------------------------

checked_run add-feature
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) is not published yet; next: dotsteward contribute trial"

state_set '.step = "done"'

# --- VERSION must equal the next tag ----------------------------------------------------

checked_run wrong-version 0.2.0
mark_trialled full false
assert_exit 0 run_contribute publish
merged=$(field .merged_sha)
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.2.0 at the merged commit ${merged:0:12}, but the next release is v0.1.1: the fix must set VERSION to 0.1.1 (VERSION equals the released tag); nothing is released"
assert_eq release "$(field .step)" "step after a VERSION mismatch"
assert_call_count 0 gh 'release *'
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.1.1 >/dev/null; then
  ds_fail "tagged despite the VERSION mismatch"
fi
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
assert_call_count 1 gh "release create v0.1.1 -R $CT_UPSTREAM_SLUG --title v0.1.1 --generate-notes --verify-tag"
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

for tag in v0.1.0 v0.1.1; do
  git -C "$ct_upstream_bare" tag -d "$tag" >/dev/null
  git -C "$ct_clone" tag -d "$tag" >/dev/null 2>&1 || true
done
state_set '.step = "done"'
checked_run first-release 0.0.1
mark_trialled full false
assert_exit 0 run_contribute publish
reset_calls
assert_exit 0 run_contribute release
assert_eq "$(field .merged_sha)" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.0.1^{commit}')" "first tag"
assert_call_count 1 gh "release create v0.0.1 -R $CT_UPSTREAM_SLUG *"
