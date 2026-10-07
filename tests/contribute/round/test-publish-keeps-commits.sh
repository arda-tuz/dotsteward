# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` in owner mode lands the checked commits on
# main unchanged: main is fast-forwarded to the tested commit, so its author,
# committer and UTC dates stay those of the framework identity. A merge made
# by GitHub writes a new commit authored with the account's display name and
# the local time zone, which the framework's privacy scans refuse on main.
# Found in the first real contribute round (v0.0.1).
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run keep-commits
mark_trialled full false
sha=$(git -C "$ct_clone" rev-parse HEAD)
main_before=$(upstream_main)
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1

reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'pr merge*'
assert_eq "$sha" "$(upstream_main)" "upstream main after publish"
assert_eq "$main_before" "$(git -C "$ct_upstream_bare" rev-parse "$sha~2")" "base of the published commits"
assert_eq MERGED "$(gh pr view "$pr_url" --json state --jq .state)" "pull request state"
state_json | assert_json - ".merged_sha == \"$sha\" and .step == \"release\" and .pr == \"$pr_url\""
