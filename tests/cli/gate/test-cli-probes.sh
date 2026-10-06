# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G11, the cli-probes step ([gate] I13, SPEC 6.2): it builds
# checks.<primary system>.home of the instance (the check profile; the
# primary system is the first of nix.systems) without writing the lock and
# runs `dotsteward probes --generation <built path>`. A failed build, a
# candidate without home-path/bin and failing probes fail the step.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

probes_failed() {
  assert_eq $'preflight\nstatic\npins\nflake-check' "$(step_lines)"
  assert_contains "$DS_STDERR" "cli-probes   FAILED ("
  assert_eq "[dotsteward] ERROR: gate step failed: cli-probes; full log: $gate_log" "$(tail -n 1 <<<"$DS_STDERR")"
  [[ ! -e $gate_validation ]] || ds_fail "a failed cli-probes step wrote a record"
}

# The primary system is the first configured one.
set_toml nix systems '["aarch64-darwin", "x86_64-linux"]'
commit_all "chore: add darwin"
assert_exit 0 run_gate --scope maintain
built=$(ds_calls_of nix | grep -F ' build ')
assert_contains "$built" "$gate_inst#checks.aarch64-darwin.home"
assert_not_contains "$built" "x86_64-linux"
generation=$(fake_calls | sed -n 's/^probes --generation //p')
assert_eq "$generation" "$(find "$DS_STUB_STATE/nix/store" -mindepth 1 -maxdepth 1 -name '*-home')"
assert_eq "== cli-probes: nix build $gate_inst#checks.aarch64-darwin.home, dotsteward probes --generation <built>" \
  "$(grep '^== cli-probes: ' "$gate_log")"
rm -f -- "$gate_validation"

# The build fails: no probe runs.
ds_stub_route nix 'build *' --exit 1 --stderr "error: builder for home failed"
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
probes_failed
assert_contains "$DS_STDERR" "error: builder for home failed"
assert_eq $'static\npins check --nix' "$(fake_calls)"
ds_stub_clear_routes nix

# The candidate has no home-path/bin.
mkdir -p "$DS_TEST_ROOT/empty-generation/home-path"
ds_stub_route nix 'build *' --stdout "$DS_TEST_ROOT/empty-generation"
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
probes_failed
assert_contains "$DS_STDERR" "candidate profile bin directory missing: $DS_TEST_ROOT/empty-generation/home-path/bin"
assert_eq $'static\npins check --nix' "$(fake_calls)"
ds_stub_clear_routes nix

# The build prints no path.
ds_stub_route nix 'build *' --stdout ""
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
probes_failed
assert_contains "$DS_STDERR" "the candidate build printed no output path"
ds_stub_clear_routes nix

# The probes fail.
step_fail probes 1
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
probes_failed
assert_contains "$DS_STDERR" "fake probes output"
step_fail probes 0

assert_exit 0 run_gate --scope maintain
assert_json "$gate_validation" '.result == "passed"'
