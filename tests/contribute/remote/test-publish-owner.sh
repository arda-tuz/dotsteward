# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` in owner mode:
# needs a trial passed for the checked commit; pushes fix/<slug>, opens the
# pull request once (reused on a re-run), waits for its checks (red: main
# untouched, the trial switch recovered), merges by fast-forwarding main to
# the checked commit (GitHub then records the pull request as merged) and
# verifies the merged commit's tree is the tested tree. A build-only trial
# also needs clean-install.yml green on the commit (dispatched on the branch
# when it has no run there). A published run answers "already published".
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
tree=$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')
main_before=$(upstream_main)
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1

# --- refusals -----------------------------------------------------------------------

reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $(current_id) has not passed the trial; next: dotsteward contribute trial"

# A trial of another commit does not count.
mark_trialled full false
state_set '.trial_sha = "0000000000000000000000000000000000000000"'
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the trial has not passed for $sha; run: dotsteward contribute trial"
mark_trialled full true

assert_exit 1 run_contribute publish --pr-to-upstream
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --pr-to-upstream is for fork mode"
assert_call_count 0 gh 'pr *'
assert_eq "$main_before" "$(upstream_main)" "upstream main after the refusals"

# --- CI red: main untouched, the trial switch recovered ----------------------------------

printf 'git+file://%s?rev=%s\n' "$ct_clone" "$sha" >"$rt_live"
hub_knob checks fail
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: CI is not green on $pr_url; main is untouched"
assert_eq "$main_before" "$(upstream_main)" "upstream main after red CI"
assert_eq "$sha" "$(git -C "$ct_upstream_bare" rev-parse refs/heads/fix/add-feature)" "pushed branch"
assert_call_count 1 gh "pr create -R $CT_UPSTREAM_SLUG --base main --head fix/add-feature *"
assert_eq "$pr_url" "$(field .pr)" "recorded pull request"
assert_eq pinned "$(live)" "live framework after red CI"
assert_eq "$(
  call_line dotsteward-rebuild --profile main --switch
  call_line dotsteward-e2e --profile main
)" "$(instance_calls)" "the recovery after red CI"
state_json | assert_json - '.trial_switched == false and .step == "publish" and .merged_sha == null'

# The pull request title and body: the commits, no machine details.
pr_json=$(cat "$rt_hub/prs/1.json")

assert_contains "$(jq -r .body <<<"$pr_json")" "a full trial on an instance, at ${sha:0:12}"
assert_not_contains "$(jq -r .body <<<"$pr_json")" "$ct_clone"

# No checks at all: CI never ran, so nothing is merged.
hub_knob checks none
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no CI check appeared on $pr_url within 1s; publishing needs green CI, main is untouched"

# --- CI green: merged, verified -----------------------------------------------------------

# The open pull request is found again when the run lost its record.
hub_knob checks pass
state_set '.pr = null'
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'pr create*'
assert_call_count 1 gh "pr list -R $CT_UPSTREAM_SLUG --head fix/add-feature --state open *"
assert_call_count 1 gh "pr checks $pr_url --watch --fail-fast --interval 1"
assert_call_count 0 gh 'pr merge*'
assert_call_count 0 gh 'workflow run*'
assert_contains "$DS_STDOUT" "[dotsteward] merging $pr_url: fast-forwarding main of $CT_UPSTREAM_SLUG to ${sha:0:12}"
assert_contains "$DS_STDOUT" "[dotsteward] reusing $pr_url"
assert_contains "$DS_STDOUT" "[dotsteward] verified: "
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute release"
merged=$(upstream_main)
assert_eq "$sha" "$merged" "upstream main after the merge"
assert_eq "$tree" "$(upstream_tree)" "tree of upstream main"
assert_eq "$main_before" "$(git -C "$ct_upstream_bare" rev-parse "$merged~2")" "base of the merged commits"
assert_eq MERGED "$(gh pr view "$pr_url" --json state --jq .state)" "pull request state after the merge"
state_json | assert_json - ".merged_sha == \"$merged\" and .step == \"release\" and .pr == \"$pr_url\""
assert_eq "" "$(instance_calls)" "instance commands of a green publish"

# Interrupted after the merge, before the run recorded it: the re-run finds
# the merged pull request and verifies it (no rebase, no second push).
state_set '.step = "publish" | .merged_sha = null'
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'pr merge*'
assert_call_count 0 gh 'pr create*'
assert_not_contains "$DS_STDOUT" "moved to"
assert_eq "$sha" "$(git -C "$ct_clone" rev-parse HEAD)" "clone HEAD after the resumed publish"
assert_eq "$merged" "$(upstream_main)" "upstream main after the resumed publish"
state_json | assert_json - ".merged_sha == \"$merged\" and .step == \"release\" and .test_sha == \"$sha\""
assert_eq "" "$(instance_calls)" "instance commands of the resumed publish"

# A published run answers without doing anything.
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "is already published: $merged"
assert_calls

# --- build-only: clean-install.yml on the commit -----------------------------------------------

checked_run second-feature
mark_trialled build-only false
sha2=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob clean-install failure
reset_calls
assert_exit 1 run_contribute publish
assert_call_count 1 gh "workflow run clean-install.yml -R $CT_UPSTREAM_SLUG --ref fix/second-feature"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: clean-install.yml on ${sha2:0:12} concluded with failure"
merged2_before=$(upstream_main)
assert_eq "$merged" "$merged2_before" "upstream main after a red clean-install run"

# A failed run is dispatched again; a green one lets the merge through.
hub_knob clean-install success
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 1 gh "workflow run clean-install.yml -R $CT_UPSTREAM_SLUG --ref fix/second-feature"
assert_call_count 0 gh 'pr merge*'
assert_eq "$sha2" "$(upstream_main)" "upstream main after the build-only publish"
assert_eq "$merged2_before" "$(git -C "$ct_upstream_bare" rev-parse "$sha2~2")" "base of the second merge"

# A green run already on the commit: no dispatch.
checked_run third-feature
mark_trialled build-only false
git -C "$ct_clone" push -q origin HEAD:refs/heads/fix/third-feature
gh workflow run clean-install.yml -R "$CT_UPSTREAM_SLUG" --ref fix/third-feature
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'workflow run*'
assert_contains "$DS_STDOUT" "[dotsteward] clean-install.yml on $(git -C "$ct_clone" rev-parse --short=12 HEAD): success"

# --- VERSION must equal the next release before main is touched ----------------------------

# VERSION 0.2.0 while the next release is v0.1.1: nothing is pushed, no
# pull request is opened, main is untouched, the trial switch is recovered.
checked_run wrong-version 0.2.0
mark_trialled full true
sha4=$(git -C "$ct_clone" rev-parse HEAD)
main4_before=$(upstream_main)
printf 'switched\n' >"$rt_live"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.2.0 at ${sha4:0:12}, but the next release is v0.1.1: set VERSION to 0.1.1 in the fix, then run: dotsteward contribute check; nothing is published"
assert_call_count 0 gh 'pr *'
[[ -z $(git -C "$ct_upstream_bare" for-each-ref refs/heads/fix/wrong-version) ]] || ds_fail "pushed despite the VERSION mismatch"
assert_eq "$main4_before" "$(upstream_main)" "upstream main after a VERSION mismatch"
assert_eq pinned "$(live)" "live framework after a VERSION mismatch"
state_json | assert_json - '.step == "publish" and .merged_sha == null and .pr == null'

# A release tagged while CI ran moves the next release: checked again right
# before the merge, so nothing is merged.
printf '0.1.1\n' >"$ct_clone/VERSION"
git -C "$ct_clone" commit -q -a -m 'fix(example): VERSION of the next release'
mark_checked
mark_trialled full false
sha5=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob ci-tags v0.1.1
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.1.1 at ${sha5:0:12}, but the next release is v0.1.2: set VERSION to 0.1.2 in the fix, then run: dotsteward contribute check; nothing is published"
assert_call_count 1 gh 'pr checks * --watch *'
assert_eq "$main4_before" "$(upstream_main)" "upstream main after a release during CI"
assert_eq publish "$(field .step)" "step after a release during CI"
