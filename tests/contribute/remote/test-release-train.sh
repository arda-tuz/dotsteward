# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Release trains in owner mode. A run that keeps VERSION at the release it
# is based on releases nothing: publish accepts it, release refuses and
# names `contribute upgrade --main` and `contribute report`, which ends the
# run at publish (after the recovery when its trial switched the
# machine). A later run with a release
# commit (VERSION set to the next version) is released with semantic
# versioning from the conventional commits since the last release (any
# feat: the next minor, otherwise the next patch), and the release bundles
# the commits of both runs; the GitHub release carries their subjects as
# grouped notes (Features, Fixes, Other). A breaking change needs the next
# major in VERSION, and that release is cut only with `release --major`.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner

# commit SUBJECT FILE: a commit in the clone that writes FILE.
commit() {
  printf '%s\n' "$1" >"$ct_clone/$2"
  git -C "$ct_clone" add -A
  git -C "$ct_clone" commit -q -m "$1"
}

# release_commit VERSION: the release commit, VERSION and the template of
# that release.
release_commit() {
  printf '%s\n' "$1" >"$ct_clone/VERSION"
  rt_bootstrap "$1" >"$ct_clone/template/bootstrap.sh"
  git -C "$ct_clone" add -A
  git -C "$ct_clone" commit -q -m "chore(release): $1"
}

short() {
  git -C "$ct_clone" log -1 --format=%h --grep="^$1\$"
}

# --- a fix that keeps VERSION: published, nothing to release, ended at publish ----------------

start_run keep-version
id=$(current_id)
commit "test(example): cover the kept version" tests/example/keep.txt
commit "fix(example): keep the version" keep.txt
mark_checked
mark_trialled full true
printf 'git+file://%s?rev=%s\n' "$ct_clone" "$(git -C "$ct_clone" rev-parse HEAD)" >"$rt_live"
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] no release is pending (VERSION is still 0.1.0): the next release bundles this run"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute upgrade --main (the instance follows the merged commit), or dotsteward contribute report"
first=$(field .merged_sha)
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no release is pending at the merged commit ${first:0:12}: VERSION is still 0.1.0, the release it is based on, so the next release bundles it (release trains); follow it with: dotsteward contribute upgrade --main, or end the run with: dotsteward contribute report"
assert_call_count 0 gh 'release *'
assert_eq release "$(field .step)" "step after the refusal"
assert_eq "" "$(instance_calls)" "a refusal runs no recovery"

reset_calls
assert_exit 0 run_contribute report
assert_contains "$DS_STDOUT" "[dotsteward] contribute run $id: completed"
assert_contains "$DS_STDOUT" "  merged commit: $first"
assert_contains "$DS_STDOUT" "  release: none"
assert_contains "$DS_STDOUT" "  instance commit: none"
assert_eq "$(
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
)" "$(instance_calls)" "the recovery before the run ends at publish"
assert_eq pinned "$(live)" "live framework after the run ended at publish"
state_json | assert_json - '.step == "done" and .outcome == "completed" and .tag == null and .recovery == "done"'

# --- a feature with a release commit: the next minor, bundling both runs ----------------------

start_run add-widget
commit "test(example): cover the widget" tests/example/widget.txt
commit "feat(example): add the widget" widget.txt
release_commit 0.2.0
mark_checked
mark_trialled full false
assert_exit 0 run_contribute publish
second=$(field .merged_sha)
reset_calls
assert_exit 0 run_contribute release
assert_contains "$DS_STDOUT" "[dotsteward] tagged ${second:0:12} as v0.2.0 on $CT_UPSTREAM_SLUG"
assert_eq "$second" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.2.0^{commit}')" "tag of the train"
git -C "$ct_upstream_bare" merge-base --is-ancestor "$first" v0.2.0 || ds_fail "the release does not bundle the first run"
assert_call_count 1 gh "release create v0.2.0 -R $CT_UPSTREAM_SLUG --title v0.2.0 --notes-file * --verify-tag"
assert_eq "## Features

- example: add the widget ($(short 'feat(example): add the widget'))

## Fixes

- example: keep the version ($(short 'fix(example): keep the version'))

## Other

- example: cover the kept version ($(short 'test(example): cover the kept version'))
- example: cover the widget ($(short 'test(example): cover the widget'))
- release: 0.2.0 ($(short 'chore(release): 0.2.0'))" \
  "$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v0.2.0.notes")" "grouped release notes"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute upgrade --tag v0.2.0"
state_set '.step = "done"'

# --- a fix after it: the next patch ---------------------------------------------------------------

start_run patch-widget
commit "test(example): cover the widget patch" tests/example/patch.txt
commit "fix(example): patch the widget" patch.txt
release_commit 0.2.1
mark_checked
mark_trialled full false
assert_exit 0 run_contribute publish
assert_exit 0 run_contribute release
assert_eq "$(field .merged_sha)" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.2.1^{commit}')" "the next patch"
state_set '.step = "done"'

# --- a breaking change: VERSION must be the next major, cut only with --major ---------------------

start_run drop-api
commit "test(example): cover the new api" tests/example/api.txt
commit "feat(example)!: drop the old api" api.txt
release_commit 0.3.0
mark_checked
mark_trialled full false
sha=$(git -C "$ct_clone" rev-parse HEAD)
main_before=$(upstream_main)
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.3.0 at ${sha:0:12}, but the commits since v0.2.1 hold a breaking change: keep VERSION 0.2.1 (no release in this run), or set the next major with tools/version.sh bump --major once the user decided it; then run: dotsteward contribute check; nothing is published"
assert_eq "$main_before" "$(upstream_main)" "upstream main after a minor for a breaking change"

release_commit 1.0.0
mark_checked
mark_trialled full false
assert_exit 0 run_contribute publish
merged=$(field .merged_sha)
reset_calls
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: v1.0.0 is a major release: cut it only with dotsteward contribute release --major, a decision of the user; nothing is released"
assert_call_count 0 gh 'release create*'
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v1.0.0 >/dev/null; then
  ds_fail "a major release was cut without --major"
fi
assert_exit 0 run_contribute release --major
assert_eq "$merged" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v1.0.0^{commit}')" "the major release"
assert_contains "$(cat "$rt_hub/releases/${CT_UPSTREAM_SLUG//\//_}_v1.0.0.notes")" \
  "- Breaking: example: drop the old api ($(short 'feat(example)!: drop the old api'))"
