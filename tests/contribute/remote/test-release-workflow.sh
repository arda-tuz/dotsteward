# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# The release workflow (.github/workflows/release.yml) cuts the pending
# release of main with `tools/version.sh release`, here in a checkout of the
# synthetic upstream against the fake GitHub. Nothing happens while VERSION
# is the release the commits are based on. A pending release (VERSION set
# to the next version by a release commit) is cut only when main's CI of
# that commit is green, as a tag on exactly that commit with the grouped
# notes, and channels.yml and macos-smoke.yml are dispatched on the tag (a
# tag made with the workflow's token starts no workflow); no commit is
# made. A VERSION that is not the next release, a red or unfinished CI and
# a major release without --major are refused with nothing released; a
# release that exists is left alone.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export RELEASE_WAIT_SECONDS=3
export RELEASE_POLL_SECONDS=1

work=$DS_TEST_ROOT/release-work
checkout=$DS_TEST_ROOT/release-checkout
git clone -q "$ct_upstream_bare" "$work"
git clone -q "$ct_upstream_bare" "$checkout"
mkdir -p "$rt_hub/releases"

# land SUBJECT [VERSION]: a commit on upstream main (writing a file named
# after the subject, and VERSION when given).
land() {
  printf '%s\n' "$1" >"$work/change-$(git -C "$work" rev-list --count HEAD).txt"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >"$work/VERSION"
  git -C "$work" add -A
  git -C "$work" commit -q -m "$1"
  git -C "$work" push -q origin HEAD:main
}

# checkout_main: the workflow's checkout of upstream main, freshly fetched
# with its tags as actions/checkout does.
checkout_main() {
  git -C "$checkout" fetch -q --tags origin main
  git -C "$checkout" checkout -q --detach FETCH_HEAD
}

# cut_release [ARG...]: the workflow's step on its checkout as it is.
cut_release() {
  "$DS_REPO_ROOT/tools/version.sh" release --root "$checkout" --repo "$CT_UPSTREAM_SLUG" \
    --rev "$(git -C "$checkout" rev-parse HEAD)" "$@"
}

# release_ci [ARG...]: the workflow's step on upstream main, freshly checked
# out.
release_ci() {
  checkout_main
  cut_release "$@"
}

releases() {
  find "$rt_hub/releases" -maxdepth 1 -type f ! -name '*.notes' | wc -l | tr -d ' '
}

# --- nothing pending ---------------------------------------------------------------------------

land "fix(cli): a fix without a release"
before=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
reset_calls
assert_exit 0 release_ci
assert_contains "$DS_STDOUT" "[version] no release pending at ${before:0:12}: VERSION 0.1.0 is the release v0.1.0 it is based on"
assert_call_count 0 gh
assert_eq 0 "$(releases)" "releases without a pending one"

# --- a pending release with main's CI green: tagged, notes, channels -------------------------------

land "feat(cli): a feature"
land "chore(release): 0.2.0" 0.2.0
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
reset_calls
assert_exit 0 release_ci
assert_contains "$DS_STDOUT" "[version] main's CI is green on ${sha:0:12}"
assert_contains "$DS_STDOUT" "[version] released v0.2.0 at ${sha:0:12}: https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.2.0"
assert_contains "$DS_STDOUT" "[version] dispatched channels.yml on v0.2.0"
assert_contains "$DS_STDOUT" "[version] dispatched macos-smoke.yml on v0.2.0"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.2.0^{commit}')" "tag of the release"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)" "main after the release: no commit"
assert_call_count 1 gh "release create v0.2.0 --repo $CT_UPSTREAM_SLUG --target $sha --title v0.2.0 --notes-file *"
assert_call_count 1 gh "workflow run channels.yml --repo $CT_UPSTREAM_SLUG --ref v0.2.0"
assert_call_count 1 gh "workflow run macos-smoke.yml --repo $CT_UPSTREAM_SLUG --ref v0.2.0"
notes=$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v0.2.0.notes")
assert_contains "$notes" "## Features"$'\n\n'"- cli: a feature ("
assert_contains "$notes" "## Fixes"$'\n\n'"- cli: a fix without a release ("
assert_contains "$notes" "## Other"$'\n\n'"- release: 0.2.0 ("

# Run again (the next ci run on main): the release exists.
reset_calls
assert_exit 0 release_ci
assert_contains "$DS_STDOUT" "[version] the release v0.2.0 exists"
assert_call_count 0 gh 'release create*'

# --- main's CI red or unfinished: nothing released --------------------------------------------

land "fix(cli): a second fix"
land "chore(release): 0.2.1" 0.2.1
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
hub_knob main-ci-ci.yml failure
reset_calls
assert_exit 1 release_ci
assert_contains "$DS_STDERR" "[version] ERROR: main's CI is red on ${sha:0:12}: https://github.com/$CT_UPSTREAM_SLUG/actions/runs/"
assert_contains "$DS_STDERR" "; nothing is released"
assert_call_count 0 gh 'release create*'
rm -f "$rt_hub/knobs/main-ci-ci.yml"

hub_knob main-ci-pending 1000
assert_exit 1 release_ci
assert_contains "$DS_STDERR" "[version] ERROR: main's CI on ${sha:0:12} is not green within 3s (ci.yml: in_progress, privacy.yml: in_progress); nothing is released"
rm -f "$rt_hub/knobs/main-ci-pending"
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.2.1 >/dev/null; then
  ds_fail "released v0.2.1 without main's CI green"
fi

assert_exit 0 release_ci
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.2.1^{commit}')" "the patch release once CI is green"

# --- a VERSION that is not the next release -----------------------------------------------------

land "fix(cli): a third fix"
land "chore(release): 0.4.0" 0.4.0
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
reset_calls
assert_exit 1 release_ci
assert_contains "$DS_STDERR" "[version] ERROR: VERSION 0.4.0 at ${sha:0:12} is not the next release 0.2.2 (after v0.2.1): set it with tools/version.sh bump in a release commit"
assert_call_count 0 gh 'release create*'

# --- a breaking change: the next major, only with --major ------------------------------------------

land "chore(release): 0.2.1" 0.2.1
land "feat(cli)!: drop the old flags"
land "chore(release): 0.3.0" 0.3.0
assert_exit 1 release_ci
assert_contains "$DS_STDERR" "[version] ERROR: VERSION 0.3.0 at "
assert_contains "$DS_STDERR" "the commits since v0.2.1 hold a breaking change, so the next release is a major one; set VERSION with tools/version.sh bump --major once the user decided it"

land "chore(release): 1.0.0" 1.0.0
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
reset_calls
assert_exit 1 release_ci
assert_contains "$DS_STDERR" "[version] ERROR: v1.0.0 is a major release: cut it only with --major (the workflow's major input), a decision of the user"
assert_call_count 0 gh 'release create*'
assert_exit 0 release_ci --major
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v1.0.0^{commit}')" "the major release"
assert_contains "$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v1.0.0.notes")" "- Breaking: cli: drop the old flags ("

# --- a tag without its GitHub release (an interrupted release by hand): completed --------------

land "fix(cli): a fourth fix"
land "chore(release): 1.0.1" 1.0.1
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
git -C "$ct_upstream_bare" tag -a v1.0.1 -m "dotsteward v1.0.1" "$sha"
reset_calls
assert_exit 0 release_ci
assert_contains "$DS_STDOUT" "[version] released v1.0.1 at ${sha:0:12}"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v1.0.1^{commit}')" "the tag is kept"
assert_eq "## Fixes"$'\n\n'"- cli: a fourth fix ($(git -C "$checkout" log -1 --format=%h HEAD^))"$'\n\n'"## Other"$'\n\n'"- release: 1.0.1 ($(git -C "$checkout" log -1 --format=%h HEAD))" \
  "$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v1.0.1.notes")" "notes since the release before"

# --- a GitHub release that `dotsteward contribute release` created meanwhile --------------------

# A run's `dotsteward contribute release` cuts the same release once main's
# CI is green: it pushes its tag (an annotated one) and creates the GitHub
# release, here after the workflow's checkout and between the workflow's
# look for the release and its own create, which then fails as GitHub does.
# A release whose tag names the workflow's commit is the release: the
# workflow is green, creates no second release and dispatches nothing (the
# run's tag push started channels.yml and macos-smoke.yml).
land "fix(cli): a fifth fix"
land "chore(release): 1.0.2" 1.0.2
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
checkout_main
git -C "$ct_upstream_bare" tag -a v1.0.2 -m "dotsteward v1.0.2" "$sha"
hub_knob release-race true
reset_calls
assert_exit 0 cut_release
assert_contains "$DS_STDOUT" "[version] the release v1.0.2 exists at ${sha:0:12}: it was created meanwhile"
assert_not_contains "$DS_STDOUT" "[version] released v1.0.2"
assert_call_count 1 gh "release create v1.0.2 --repo $CT_UPSTREAM_SLUG --target $sha *"
assert_call_count 0 gh 'workflow run *'
assert_eq tag "$(git -C "$ct_upstream_bare" cat-file -t refs/tags/v1.0.2)" "the run's tag stays"
[[ ! -e $rt_hub/knobs/release-race ]] || ds_fail "the workflow did not try to create the release"

# The same race with the run's tag on another commit: red, nothing more.
land "fix(cli): a sixth fix"
land "chore(release): 1.0.3" 1.0.3
sha=$(git -C "$ct_upstream_bare" rev-parse refs/heads/main)
other=$(git -C "$ct_upstream_bare" rev-parse "$sha^")
checkout_main
git -C "$ct_upstream_bare" tag -a v1.0.3 -m "dotsteward v1.0.3" "$other"
hub_knob release-race true
reset_calls
assert_exit 1 cut_release
assert_contains "$DS_STDERR" "[version] ERROR: gh release create v1.0.3 failed: the release v1.0.3 exists, but its tag names ${other:0:12}, not ${sha:0:12}"
assert_call_count 0 gh 'workflow run *'
