# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the mkInstance tests (tests/nix/instance).
#
# Builds on tests/nix/core/helpers.sh (isolated Nix store, locked nixpkgs and
# home-manager, json_check). Expressions are evaluated with
# tests/nix/instance/prelude.nix in scope: fixture instances evaluated by
# lib.mkInstance with constructed flake inputs.
#
# Inputs (besides those of tests/nix/core/helpers.sh):
#   DS_JSONSCHEMA_PYTHON   python with jsonschema (see tests/nix/lib/helpers.sh)

# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

nix_instance_dir=$DS_REPO_ROOT/tests/nix/instance
# shellcheck disable=SC2034 # used by the test files that source this file
nix_instance_fixtures=$nix_instance_dir/fixtures

# nix_instance_eval_in REPO EXPR: evaluates EXPR strictly to JSON with the
# instance prelude of the framework checkout REPO in scope. Output and status
# land in DS_STDOUT, DS_STDERR and DS_STATUS; the status is returned.
nix_instance_eval_in() {
  (($# == 2)) || ds_fail "nix_instance_eval_in: usage: nix_instance_eval_in REPO EXPR"
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  local repo=$1
  local expr="{ nixpkgs, homeManager, repo }: with import (/. + repo + \"/tests/nix/instance/prelude.nix\") { inherit nixpkgs homeManager repo; }; ($2)"
  local out_file=$DS_TEST_ROOT/nix-eval.out err_file=$DS_TEST_ROOT/nix-eval.err
  DS_STATUS=0
  env -u NIX_REMOTE -u NIX_PATH \
    NIX_STORE_DIR="$nix_lib_store/store" \
    NIX_STATE_DIR="$nix_lib_store/state" \
    NIX_LOG_DIR="$nix_lib_store/log" \
    NIX_CONF_DIR="$nix_lib_store/etc" \
    NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
    nix-instantiate --eval --strict --json --show-trace \
    --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" \
    --argstr repo "$repo" \
    --expr "$expr" >"$out_file" 2>"$err_file" || DS_STATUS=$?
  DS_STDOUT=$(<"$out_file")
  DS_STDERR=$(<"$err_file")
  return "$DS_STATUS"
}

# nix_instance_eval EXPR: nix_instance_eval_in for the checkout under test.
nix_instance_eval() {
  (($# == 1)) || ds_fail "nix_instance_eval: usage: nix_instance_eval EXPR"
  nix_instance_eval_in "$DS_REPO_ROOT" "$1"
}

# inst_json EXPR: prints the JSON value of EXPR, failing the test when the
# evaluation fails.
inst_json() {
  nix_instance_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

# inst_raw EXPR: prints the string value of EXPR without JSON quoting.
inst_raw() {
  inst_json "$1" | jq -j .
}

# assert_inst_eq EXPECTED_JSON EXPR [MESSAGE]: EXPR evaluates to the JSON
# value EXPECTED_JSON (compared after jq normalization, key order ignored).
assert_inst_eq() {
  (($# >= 2)) || ds_fail "assert_inst_eq: usage: assert_inst_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_inst_eq: invalid expected JSON: $1"
  actual=$(inst_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

# assert_inst_fails EXPR NEEDLE... : evaluating EXPR fails and the error
# output contains every NEEDLE (fixed strings).
assert_inst_fails() {
  (($# >= 2)) || ds_fail "assert_inst_fails: usage: assert_inst_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if nix_instance_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}

# instance_copy SOURCE: copies the fixture instance directory SOURCE to a
# new directory under DS_TEST_ROOT and prints its path.
instance_copy() {
  local target
  target=$(mktemp -d "$DS_TEST_ROOT/instance.XXXXXX")
  cp -R "$1/." "$target/"
  chmod -R u+w "$target"
  printf '%s\n' "$target"
}

# write_mirrors INSTANCE_EXPR DIR: writes every dotstewardMirrors file of
# the instance INSTANCE_EXPR into DIR/.dotsteward/.
write_mirrors() {
  local mirrors name
  mirrors=$(inst_json "($1).dotstewardMirrors")
  mkdir -p "$2/.dotsteward"
  while IFS= read -r name; do
    jq -j --arg name "$name" '.[$name]' <<<"$mirrors" >"$2/.dotsteward/$name"
  done < <(jq -r 'keys[]' <<<"$mirrors")
}
