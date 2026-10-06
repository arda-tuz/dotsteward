# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# P5, the advisory checks of update prepare ([gate] I5): an unreachable
# binary cache, less free space for /nix/store than
# gate.prepare_warn_free_gib, a GitHub CLI that is not logged in and a
# missing GitHub CLI are warnings in the JSON line (in this order), never
# refusals; candidate.json is written all the same. The cache URL and its
# DOTSTEWARD_CACHE_URL override are the gate's.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh

# warnings: the warnings of the JSON line of the last run, one per line.
warnings() {
  jq -r '.warnings[]' <<<"$(tail -n 1 <<<"$DS_STDOUT")"
}

# prepared_anyway: the run passed and wrote candidate.json.
prepared_anyway() {
  assert_eq "" "$DS_STDERR"
  assert_json "$up_candidate" '.schema_version == "1.1"'
  rm -f -- "$up_candidate"
  assert_call_count 0 nix
}

# Everything fine: no warning.
serve_cache
assert_exit 0 run_update prepare --official-sources-only
assert_eq "" "$(warnings)"
prepared_anyway
probe=$(ds_calls_of curl)
assert_contains "$probe" "--fail"
assert_contains "$probe" "--max-time 10"
assert_contains "$probe" "$UP_CACHE_URL/nix-cache-info"
assert_call_count 1 gh 'auth status'

# The cache answers with an error status.
: >"$DS_TEST_ROOT/empty"
ds_curl_serve "$UP_CACHE_URL/nix-cache-info" "$DS_TEST_ROOT/empty" 503
assert_exit 0 run_update prepare --official-sources-only
assert_eq "Nix binary cache unreachable: $UP_CACHE_URL" "$(warnings)"
prepared_anyway

# DOTSTEWARD_CACHE_URL replaces the configured cache.
down=https://down-cache.example.invalid
ds_curl_fail "$down/nix-cache-info" 6 "Could not resolve host"
assert_exit 0 env DOTSTEWARD_CACHE_URL=$down "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update prepare \
  --official-sources-only
assert_eq "Nix binary cache unreachable: $down" "$(warnings)"
prepared_anyway
serve_cache

# Too little free space: far more than any disk has.
set_toml gate prepare_warn_free_gib 1000000000
commit_all "chore: ask for more free space"
git -C "$up_inst" push -q origin main 2>/dev/null
assert_exit 0 run_update prepare --official-sources-only
assert_eq "free space for /nix/store is below 1000000000 GiB" "$(warnings)"
prepared_anyway

# The GitHub CLI is not logged in.
ds_stub_set gh auth logged-out
assert_exit 0 run_update prepare --official-sources-only
assert_eq "free space for /nix/store is below 1000000000 GiB
gh is not logged in; GitHub queries need 'gh auth login'" "$(warnings)"
prepared_anyway

# Every warning at once, in order, with the GitHub CLI missing.
ds_curl_serve "$UP_CACHE_URL/nix-cache-info" "$DS_TEST_ROOT/empty" 404
nogh=$(path_without gh)
assert_exit 0 env PATH="$nogh" "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update prepare \
  --official-sources-only --scope maintain
assert_eq "Nix binary cache unreachable: $UP_CACHE_URL
free space for /nix/store is below 1000000000 GiB
gh not found" "$(warnings)"
assert_json - '.scope == "maintain" and .dirty == []' <<<"$(tail -n 1 <<<"$DS_STDOUT")"
prepared_anyway

# curl itself is required.
nocurl=$(path_without curl)
assert_exit 1 env PATH="$nocurl" "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update prepare \
  --official-sources-only
assert_eq "[dotsteward] ERROR: required command not found: curl" "$DS_STDERR"
[[ ! -e $up_candidate ]] || ds_fail "prepare wrote candidate.json without curl"
