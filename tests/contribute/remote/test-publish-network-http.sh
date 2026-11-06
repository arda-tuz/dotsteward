# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` and `release` when the clone's remote speaks
# HTTPS, which is the default of gh: real git over a real smart HTTP server. A
# POST that breaks ends `git push` with status 1, the status of a rejected
# push, and may have landed all the same. Such a push says nothing about the
# change, so it is made again, after a fresh read of the ref, and the machine
# keeps the trial switch; a reference advertisement that fails with HTTP 5xx
# too. A push the remote rejects stays a verdict over HTTP as well, and so
# does an advertisement that answers HTTP 403: one attempt, no pause.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
git_http_serve

# switched_run SLUG VERSION: a checked run after a full trial that switched
# the live generation.
switched_run() {
  checked_run "$@"
  mark_trialled full true
  printf 'trial\n' >"$rt_live"
}

# no_recovery: the last command left the machine on the trial framework.
no_recovery() {
  assert_eq "" "$(instance_calls)" "instance commands of a publish over a broken connection"
  assert_eq trial "$(live)" "live framework after a publish over a broken connection"
}

# --- the POST of main fails with HTTP 502, before it landed -----------------------------------

switched_run add-feature 0.1.1
sha=$(git -C "$ct_clone" rev-parse HEAD)
git_http_fail post-502 refs/heads/main
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "error: 502"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/main on origin; trying again in 1s"
assert_not_contains "$DS_STDERR" "was refused"
assert_eq "$sha" "$(upstream_main)" "upstream main after a POST that failed"
assert_eq 3 "$(http_pushes)" "pushes: the branch, and main twice"
no_recovery
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$sha\" and .trial_switched == true"

# --- the answer of the tag's POST is lost: HTTP 502 after it landed ----------------------------

git_http_fail lost-502 refs/tags/v0.1.1
assert_exit 0 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/tags/v0.1.1 on origin; trying again in 1s"
assert_not_contains "$DS_STDOUT" "the release workflow cut"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "the tag"
assert_eq upgrade "$(field .step)" "step after the release"
state_set '.step = "done"'

# --- the connection resets during the POST of the branch, before it landed --------------------

switched_run second-feature 0.1.2
sha=$(git -C "$ct_clone" rev-parse HEAD)
git_http_fail post-reset refs/heads/fix/second-feature
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/fix/second-feature on origin; trying again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] pushed fix/second-feature (${sha:0:12}) to origin"
assert_eq "$sha" "$(upstream_main)" "upstream main after a reset POST"
no_recovery
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- the connection resets after the POST of main landed: the push is not made again ----------

switched_run third-feature 0.1.3
sha=$(git -C "$ct_clone" rev-parse HEAD)
git_http_fail lost-reset refs/heads/main
: >"$DS_TEST_ROOT/git-http.log"
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/main on origin; trying again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] main of $CT_UPSTREAM_SLUG is already ${sha:0:12}"
assert_not_contains "$DS_STDERR" "was refused"
assert_eq "$sha" "$(upstream_main)" "upstream main after the lost answer"
assert_eq 2 "$(http_pushes)" "pushes: the branch and main, once each"
no_recovery
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- an advertisement with HTTP 503 is made again ---------------------------------------------

switched_run fourth-feature 0.1.4
sha=$(git -C "$ct_clone" rev-parse HEAD)
git_http_fail get-503 .
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_eq "$sha" "$(upstream_main)" "upstream main after an advertisement with HTTP 503"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# --- the verdicts: a rejected push, HTTP 403 ------------------------------------------------------

switched_run refused-feature 0.1.5
refused=$(git -C "$ct_clone" rev-parse HEAD)
before=$(upstream_main)
hub_knob push-main refuse
: >"$DS_TEST_ROOT/git-http.log"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "protected branch: pushes to main are refused"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing ${refused:0:12} to main of $CT_UPSTREAM_SLUG was refused; main is untouched"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 2 "$(http_pushes)" "pushes: the branch and the refused push to main, once each"
assert_eq "$before" "$(upstream_main)" "upstream main after the refused push"
hub_knob push-main none

mark_trialled full false
git_http_fail get-403 .
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "error: 403"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the tags of origin"
assert_not_contains "$DS_STDERR" "trying again"
