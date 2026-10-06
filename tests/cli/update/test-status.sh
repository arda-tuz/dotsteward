# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# update status (SPEC 6.2): the paths and contents of candidate.json and
# validation.json, so skills never hard-code the state paths. --json prints
# one document {schema_version: 1, instance, paths: {state_dir, candidate,
# validation, log}, candidate, validation} whose records are the files'
# objects as written (null when absent or not a JSON object, with a warning
# for an unreadable one). It only reads: no state directory is created, no
# git, network or Nix command runs, and it works in any checkout of the
# instance.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

# status_json: runs status --json; json is its one line.
status_json() {
  assert_exit 0 run_update status --json
  assert_eq 1 "$(wc -l <<<"$DS_STDOUT")" "status --json printed more than one line"
  json=$DS_STDOUT
}

# --- nothing recorded yet -----------------------------------------------------------

status_json
assert_eq "" "$DS_STDERR"
assert_eq "$(jq -cn --arg i "$up_inst" --arg s "$up_state" '{schema_version: 1, instance: $i,
  paths: {state_dir: $s, candidate: ($s + "/candidate.json"), validation: ($s + "/validation.json"),
    log: ($s + "/validate.log")},
  candidate: null, validation: null}')" "$json"
[[ ! -e $up_state ]] || ds_fail "status created the state directory"
assert_calls
assert_no_network

assert_exit 0 run_update status
assert_eq "[dotsteward] state directory: $up_state
[dotsteward] candidate: $up_candidate (none)
[dotsteward] validation: $up_validation (none)
[dotsteward] log: $up_log (none)" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
[[ ! -e $up_state ]] || ds_fail "status created the state directory"

# --- records -----------------------------------------------------------------------

assert_exit 0 run_update prepare --official-sources-only --scope maintain
base=$(head_oid)
change_and_commit "docs: a change"
write_validation '.step_seconds.static = 42'
printf 'log line\n' >"$up_log"
reset_logs

status_json
assert_eq "$(jq -c . "$up_candidate")" "$(jq -c .candidate <<<"$json")"
assert_eq "$(jq -c . "$up_validation")" "$(jq -c .validation <<<"$json")"
assert_eq "$base" "$(jq -r .candidate.base_oid <<<"$json")"
assert_eq 42 "$(jq -r '.validation.step_seconds.static' <<<"$json")"
assert_calls
assert_no_network

# The human form names each file and prints its record.
assert_exit 0 run_update status
assert_contains "$DS_STDOUT" "[dotsteward] candidate: $up_candidate"
assert_contains "$DS_STDOUT" "[dotsteward] validation: $up_validation"
assert_contains "$DS_STDOUT" "[dotsteward] log: $up_log"
assert_contains "$DS_STDOUT" "  \"base_oid\": \"$base\","
assert_contains "$DS_STDOUT" "  \"result\": \"passed\","
assert_not_contains "$DS_STDOUT" "(none)"

# --- unreadable records ------------------------------------------------------------------

printf 'not json\n' >"$up_candidate"
printf '[1, 2]\n' >"$up_validation"
status_json
assert_json - '.candidate == null and .validation == null' <<<"$json"
assert_eq "[dotsteward] WARNING: ignoring $up_candidate: not a JSON object
[dotsteward] WARNING: ignoring $up_validation: not a JSON object" "$DS_STDERR"

# --- any checkout, any state root ---------------------------------------------------------

# Another branch, a dirty tree and no origin do not matter.
git -C "$up_inst" checkout -q -b feature
printf 'dirty\n' >"$up_inst/new.txt"
git -C "$up_inst" remote remove origin
other=$DS_TEST_ROOT/other-state
assert_exit 0 env DOTSTEWARD_STATE_ROOT="$other" "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update status --json
assert_eq "$other/update" "$(jq -r .paths.state_dir <<<"$DS_STDOUT")"
assert_eq "$other/update/candidate.json" "$(jq -r .paths.candidate <<<"$DS_STDOUT")"
[[ ! -e $other ]] || ds_fail "status created the state root"

# The state root of the configuration.
set_toml state root '"~/custom-state"'
assert_exit 0 bash -c 'unset DOTSTEWARD_STATE_ROOT; exec "$@"' bash "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" \
  update status --json
assert_eq "$HOME/custom-state/update" "$(jq -r .paths.state_dir <<<"$DS_STDOUT")"
