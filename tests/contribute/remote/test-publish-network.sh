# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` and `release` over a network that drops
# for a moment: a `git ls-remote`, a fetch or a push that fails for the
# network says nothing about the change, so it is made again after a pause
# that starts at DOTSTEWARD_CONTRIBUTE_POLL_SECONDS and doubles, and only
# failures that last DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS stop the step. A
# push reads its ref again first: a push whose answer was lost has landed.
# The verdicts are never made again: a push the remote refuses (a protected
# branch, a main that moved) or the pre-push hook refuses (a privacy
# finding), and a repository that does not exist or refuses the login.
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
network_plan x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.
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

network_plan x.x.x.x.x.x.x.x.x.x.
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
network_plan xxx
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 2s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 4s"
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

# --- a push the remote refuses is a verdict: made once --------------------------------------------

switched_run refused-feature 0.1.6
refused=$(git -C "$ct_clone" rev-parse HEAD)
before=$(upstream_main)
hub_knob push-main refuse
: >"$DS_FAKESSH_LOG"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "protected branch: pushes to main are refused"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing ${refused:0:12} to main of $CT_UPSTREAM_SLUG was refused; main is untouched"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and the refused push to main, once"
assert_eq "$before" "$(upstream_main)" "upstream main after the refused push"
assert_eq pinned "$(live)" "the refused push runs the recovery"
hub_knob push-main none

# A main that moved at the last moment is a verdict too: the branch goes
# back to check at once.
mark_trialled full false
hub_knob push-main race
: >"$DS_FAKESSH_LOG"
assert_exit 5 run_contribute publish
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 1 "$(pushes_served)" "pushes served: the push to main that no longer fast-forwards, once"
assert_eq check "$(field .step)" "step after main moved"

# A finding of the pre-push hook: the push is refused before it is sent.
mark_checked
mark_trialled full false
mkdir -p "$DS_TEST_ROOT/refusing-hooks"
printf '#!%s\nprintf "[dotsteward] ERROR: pre-push: a finding\\n" >&2\nexit 1\n' "$BASH" >"$DS_TEST_ROOT/refusing-hooks/pre-push"
chmod 0755 "$DS_TEST_ROOT/refusing-hooks/pre-push"
git -C "$ct_clone" config core.hooksPath "$DS_TEST_ROOT/refusing-hooks"
main_before=$(upstream_main)
: >"$DS_FAKESSH_LOG"
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-push: a finding"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing fix/refused-feature to origin failed; nothing is published"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 1 "$(pushes_served)" "connections of the push that the hook refused"
assert_eq "$main_before" "$(upstream_main)" "upstream main after the hook's refusal"
git -C "$ct_clone" config --unset core.hooksPath

# --- a repository that does not exist is no network failure ----------------------------------

: >"$DS_TEST_ROOT/empty.map"
mark_trialled full false
started=$SECONDS
DS_FAKESSH_MAP=$DS_TEST_ROOT/empty.map assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "ERROR: Repository not found."
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the tags of origin"
assert_not_contains "$DS_STDERR" "trying again"
((SECONDS - started < 20)) || ds_fail "publish waited for a repository that does not exist"

# --- failures that last: red once they lasted the appear time, then the rerun passes --------------

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=2
DS_FAKESSH_FAIL=1 assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the tags of origin"
assert_eq publish "$(field .step)" "step after a network that stayed down"
sha=$(git -C "$ct_clone" rev-parse HEAD)
main_before=$(upstream_main)
network_plan xx
assert_exit 0 run_contribute publish
assert_eq "$sha" "$(upstream_main)" "upstream main once the network is back"
