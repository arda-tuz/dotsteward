# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G9, the preflight step ([gate] I11): an unreachable binary cache and too
# little free space for /nix/store are fatal in the gate. The cache outage
# rule is part of the message: no mirrors, no extra substituters. Both
# thresholds come from the configuration and its environment overrides.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl

preflight_failed() {
  assert_eq "" "$(step_lines)"
  assert_contains "$DS_STDERR" "preflight    FAILED ("
  assert_eq "[dotsteward] ERROR: gate step failed: preflight; full log: $gate_log" "$(tail -n 1 <<<"$DS_STDERR")"
  assert_eq "" "$(fake_calls)"
  assert_call_count 0 nix '*flake check*'
  assert_call_count 0 nix '* build *'
  [[ ! -e $gate_validation ]] || ds_fail "a failed preflight wrote a record"
}

# The cache answers with an error status.
: >"$DS_TEST_ROOT/empty"
ds_curl_serve "$GATE_CACHE_URL/nix-cache-info" "$DS_TEST_ROOT/empty" 503
assert_exit 1 run_gate --scope maintain
preflight_failed
assert_contains "$DS_STDERR" "Nix binary cache unreachable: $GATE_CACHE_URL. Do not use mirrors or extra substituters; rerun when the network is back."
assert_contains "$(<"$gate_log")" "== preflight: "
probe=$(ds_calls_of curl)
assert_contains "$probe" "--fail"
assert_contains "$probe" "--max-time 10"
assert_contains "$probe" "$GATE_CACHE_URL/nix-cache-info"

# The cache is unreachable (DOTSTEWARD_CACHE_URL replaces the configured
# cache).
down=https://down-cache.example.invalid
ds_curl_fail "$down/nix-cache-info" 6 "Could not resolve host"
: >"$DS_CALL_LOG"
assert_exit 1 env DOTSTEWARD_CACHE_URL=$down "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain
preflight_failed
assert_contains "$DS_STDERR" "Nix binary cache unreachable: $down. Do not use mirrors"
assert_call_count 1 curl "*$down/nix-cache-info*"

# A reachable cache given through the environment passes while the
# configured one still fails.
other=https://other-cache.example.invalid
printf 'StoreDir: /nix/store\n' >"$DS_TEST_ROOT/other-cache-info"
ds_curl_serve "$other/nix-cache-info" "$DS_TEST_ROOT/other-cache-info"
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_CACHE_URL=$other "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain
assert_call_count 1 curl "*$other/nix-cache-info*"
rm -f -- "$gate_validation"

# Too little free space: far more than any disk has.
serve_cache
set_toml gate min_free_gib 1000000000
commit_all "chore: ask for more free space"
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
preflight_failed
assert_contains "$DS_STDERR" "free space for /nix/store is below 1000000000 GiB; free space first"

# DOTSTEWARD_MIN_FREE_GB replaces the configured threshold.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_MIN_FREE_GB=0 "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain
assert_json "$gate_validation" '.result == "passed"'
: >"$DS_CALL_LOG"
assert_exit 1 env DOTSTEWARD_MIN_FREE_GB=999999999 "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain --force
assert_contains "$DS_STDERR" "free space for /nix/store is below 999999999 GiB; free space first"
