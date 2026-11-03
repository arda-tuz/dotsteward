# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute status` shows main's CI for the merged commit once
# the run has one: the state of the push runs of ci.yml (with the full
# check) and privacy.yml on main (pending while one is missing or running,
# red when one failed, else green) and the run's URL, as a line and, with
# --json, as main_ci {sha, state, url, runs} next to the state document.
# It reads them once, never waits, and never fails over them: without gh
# the state is unknown, with the reason.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
runs_url=https://github.com/$CT_UPSTREAM_SLUG/actions/runs

# Before the merge: the state document only, no GitHub call.
checked_run add-feature
mark_trialled full false
reset_calls
assert_exit 0 run_contribute status --json
assert_json - 'has("main_ci") | not' <<<"$DS_STDOUT"
assert_call_count 0 gh

assert_exit 0 run_contribute publish
merged=$(field .merged_sha)

# --- running ---------------------------------------------------------------------------------

hub_knob main-ci-pending 1000
reset_calls
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "  main_ci: pending $runs_url/"
assert_contains "$DS_STDOUT" "  merged_sha: $merged"
assert_exit 0 run_contribute status --json
assert_json - ".main_ci.sha == \"$merged\" and .main_ci.state == \"pending\"" <<<"$DS_STDOUT"
assert_json - '[.main_ci.runs[] | {workflow, status, conclusion}] == [{workflow: "ci.yml", status: "in_progress", conclusion: null}, {workflow: "privacy.yml", status: "in_progress", conclusion: null}]' <<<"$DS_STDOUT"
assert_json - ".main_ci.url | startswith(\"$runs_url/\")" <<<"$DS_STDOUT"
assert_json - "del(.main_ci) == $(state_json)" <<<"$DS_STDOUT"
[[ -e $rt_hub/knobs/main-ci-pending ]] || ds_fail "status waited for main's CI"
rm -f "$rt_hub/knobs/main-ci-pending"

# --- missing: pending as well ------------------------------------------------------------------

hub_knob main-ci none
assert_exit 0 run_contribute status --json
assert_json - '.main_ci.state == "pending" and .main_ci.url == null and ([.main_ci.runs[].status] | unique) == ["missing"]' <<<"$DS_STDOUT"

# --- green ---------------------------------------------------------------------------------------

hub_knob main-ci success
assert_exit 0 run_contribute status --json
assert_json - '.main_ci.state == "green" and ([.main_ci.runs[].conclusion] | unique) == ["success"]' <<<"$DS_STDOUT"
ci_url=$(jq -r '.main_ci.runs[] | select(.workflow == "ci.yml") | .url' <<<"$DS_STDOUT")
assert_json - ".main_ci.url == \"$ci_url\"" <<<"$DS_STDOUT"
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "  main_ci: green $ci_url"

# --- red: the URL of the failed run ---------------------------------------------------------------

hub_knob main-ci-privacy.yml failure
assert_exit 0 run_contribute status --json
privacy_url=$(jq -r '.main_ci.runs[] | select(.workflow == "privacy.yml") | .url' <<<"$DS_STDOUT")
assert_json - ".main_ci.state == \"red\" and .main_ci.url == \"$privacy_url\"" <<<"$DS_STDOUT"
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "  main_ci: red $privacy_url"

# --- gh logged out: unknown, with the reason; status still succeeds ---------------------------------

hub_knob logged-out true
assert_exit 0 run_contribute status --json
assert_json - ".main_ci == {sha: \"$merged\", state: \"unknown\", url: null, reason: \"gh is not logged in; run 'gh auth login' first\", runs: []}" <<<"$DS_STDOUT"
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "  main_ci: unknown (gh is not logged in; run 'gh auth login' first)"
