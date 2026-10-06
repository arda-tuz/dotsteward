# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute status` (SPEC 6.2, 9.4): the state of the current
# run (or of --id ID) as human lines or, with --json, the state document
# itself; it reads only.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

setup_owner
start_run first-fix
first=$(current_id)
start_run second-fix
second=$(current_id)
: >"$DS_CALL_LOG"

# --json prints the current run's state document.
assert_exit 0 run_contribute status --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/status.json"
assert_eq "$(jq -S . "$ct_runs/$second.json")" "$(jq -S . "$DS_TEST_ROOT/status.json")" "status --json"

# --id selects another run.
assert_exit 0 run_contribute status --json --id "$first"
assert_json - ".id == \"$first\" and .slug == \"first-fix\" and .step == \"reproduce\"" <<<"$DS_STDOUT"

# Human output: one line per field.
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "[dotsteward] contribute run $second"
assert_contains "$DS_STDOUT" "  slug: second-fix"
assert_contains "$DS_STDOUT" "  mode: owner"
assert_contains "$DS_STDOUT" "  branch: fix/second-fix"
assert_contains "$DS_STDOUT" "  step: reproduce"
assert_contains "$DS_STDOUT" "  test_sha: null"
assert_contains "$DS_STDOUT" "  trial_switched: false"

# Status reads only: no stub call, the state files are unchanged.
before=$(cat "$ct_runs/$first.json" "$ct_runs/$second.json" "$ct_runs/current")
assert_exit 0 run_contribute status
assert_eq "$before" "$(cat "$ct_runs/$first.json" "$ct_runs/$second.json" "$ct_runs/current")" "state files"
assert_calls

# A damaged state file is refused, not printed.
printf 'not json\n' >"$ct_runs/$first.json"
assert_exit 1 run_contribute status --id "$first"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the state file of run $first is not a JSON object"
