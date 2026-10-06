# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the vscode component tests (tests/nix/components/vscode).
#
# Builds on tests/nix/instance/helpers.sh (isolated Nix store, lib.mkInstance
# with constructed inputs). Expressions are evaluated with the instance
# prelude and tests/nix/components/vscode/scope.nix in scope.
#
#   vscode_eval EXPR          evaluates EXPR strictly to JSON; output and
#                             status land in DS_STDOUT, DS_STDERR, DS_STATUS
#   vscode_json EXPR          the JSON value of EXPR (fails the test when the
#                             evaluation fails)
#   assert_vscode_eq EXPECTED_JSON EXPR [MESSAGE]
#                             EXPR evaluates to EXPECTED_JSON (jq-normalized)
#   assert_vscode_fails EXPR NEEDLE...
#                             evaluating EXPR fails, the error output
#                             contains every NEEDLE

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

vscode_dir=$DS_REPO_ROOT/tests/nix/components/vscode
# shellcheck disable=SC2034 # used by the test files that source this file
vscode_fixture=$vscode_dir/fixtures/instance
# shellcheck disable=SC2034 # used by the test files that source this file
vscode_component=$DS_REPO_ROOT/modules/components/vscode

vscode_eval() {
  (($# == 1)) || ds_fail "vscode_eval: usage: vscode_eval EXPR"
  nix_instance_eval "with import (repoRoot + \"/tests/nix/components/vscode/scope.nix\") { inherit lib instance repoRoot storeless; }; ($1)"
}

vscode_json() {
  vscode_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

assert_vscode_eq() {
  (($# >= 2)) || ds_fail "assert_vscode_eq: usage: assert_vscode_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_vscode_eq: invalid expected JSON: $1"
  actual=$(vscode_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

assert_vscode_fails() {
  (($# >= 2)) || ds_fail "assert_vscode_fails: usage: assert_vscode_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if vscode_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}
