# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The framework override: --framework-override REF, or
# DOTSTEWARD_FRAMEWORK_OVERRIDE (the flag wins), replaces the instance's
# dotsteward input in memory: both Nix builds of the gate get
# `--override-input dotsteward REF --no-write-lock-file`, the step commands
# see DOTSTEWARD_FRAMEWORK_OVERRIDE=REF, flake.lock is never written, and the
# record carries framework_override. Without an override the variable is
# unset for the steps, even when the caller exported it empty.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

ref='git+file:///srv/dotsteward?rev=0123456789abcdef0123456789abcdef01234567'
lock_before=$(sha256sum <"$gate_inst/flake.lock")

overridden() {
  local expected=$1
  assert_eq "$(nix_line flake check "$gate_inst" --no-update-lock-file --keep-going -L --max-jobs 5 --cores 3 \
    --override-input dotsteward "$expected" --no-write-lock-file)" "$(ds_calls_of nix | grep -F ' flake check ')"
  assert_eq "$(nix_line build "$gate_inst#checks.x86_64-linux.home" --no-link --no-update-lock-file \
    --print-out-paths --max-jobs 5 --cores 3 --override-input dotsteward "$expected" --no-write-lock-file)" \
    "$(ds_calls_of nix | grep -F ' build ')"
  assert_eq 3 "$(grep -cF -- "DOTSTEWARD_FRAMEWORK_OVERRIDE=$(printf '%q' "$expected")" "$DS_CALL_LOG")" \
    "the step commands did not see the override"
  assert_eq "$expected" "$(jq -r .framework_override "$gate_validation")"
  assert_eq "$lock_before" "$(sha256sum <"$gate_inst/flake.lock")" "flake.lock changed"
}

# The flag.
assert_exit 0 run_gate --scope maintain --framework-override "$ref"
overridden "$ref"

# The environment variable.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="path:/srv/env-dotsteward" \
  "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain
overridden "path:/srv/env-dotsteward"

# The flag wins over the environment variable (and the memo answers for the
# recorded override).
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="path:/srv/env-dotsteward" \
  "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain --framework-override "$ref"
overridden "$ref"

# No override: no override arguments, the variable is unset for the steps
# and the record holds null; an empty variable means no override.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE= "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate --scope maintain
assert_call_count 0 nix '*--override-input*'
assert_call_count 0 nix '*--no-write-lock-file*'
assert_eq 3 "$(grep -c -- ' -DOTSTEWARD_FRAMEWORK_OVERRIDE$' "$DS_CALL_LOG")"
assert_json "$gate_validation" '.framework_override == null'

# A passed record answers a later gate with the same override.
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain --framework-override "$ref"
assert_not_contains "$DS_STDOUT" "already passed the gate"
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain --framework-override "$ref"
assert_contains "$DS_STDOUT" "already passed the gate"
assert_eq "" "$(fake_calls)"
