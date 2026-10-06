# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q5, `dotsteward contribute publish` in owner mode (SPEC 9.4 step 8, D23):
# needs a trial passed for the checked commit; pushes fix/<slug>, opens the
# pull request once (reused on a re-run), waits for its checks (red: main
# untouched, the trial switch recovered), merges with --squash
# --match-head-commit <checked commit> and verifies the merged commit's
# tree is the tested tree. A build-only trial also needs clean-install.yml
# green on the commit (dispatched on the branch when it has no run there).
# A published run answers "already published".
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
assert_call_count 0 gh 'pr merge*'
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
assert_call_count 1 gh "pr merge $pr_url --squash --match-head-commit $sha"
assert_call_count 0 gh 'workflow run*'
assert_contains "$DS_STDOUT" "[dotsteward] reusing $pr_url"
assert_contains "$DS_STDOUT" "[dotsteward] verified: "
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute release"
merged=$(upstream_main)
assert_eq "$tree" "$(upstream_tree)" "tree of upstream main"
assert_eq "$main_before" "$(git -C "$ct_upstream_bare" rev-parse "$merged^")" "parent of the squash commit"
state_json | assert_json - ".merged_sha == \"$merged\" and .step == \"release\" and .pr == \"$pr_url\""
assert_eq "" "$(instance_calls)" "instance commands of a green publish"

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
assert_call_count 0 gh 'pr merge*'
merged2_before=$(upstream_main)

# A failed run is dispatched again; a green one lets the merge through.
hub_knob clean-install success
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 1 gh "workflow run clean-install.yml -R $CT_UPSTREAM_SLUG --ref fix/second-feature"
assert_call_count 1 gh "pr merge * --squash --match-head-commit $sha2"
assert_eq "$(git -C "$ct_clone" rev-parse "$sha2^{tree}")" "$(upstream_tree)" "tree after the build-only publish"
assert_eq "$merged2_before" "$(git -C "$ct_upstream_bare" rev-parse 'refs/heads/main^')" "parent of the second squash"

# A green run already on the commit: no dispatch.
checked_run third-feature
mark_trialled build-only false
git -C "$ct_clone" push -q origin HEAD:refs/heads/fix/third-feature
gh workflow run clean-install.yml -R "$CT_UPSTREAM_SLUG" --ref fix/third-feature
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'workflow run*'
assert_contains "$DS_STDOUT" "[dotsteward] clean-install.yml on $(git -C "$ct_clone" rev-parse --short=12 HEAD): success"
