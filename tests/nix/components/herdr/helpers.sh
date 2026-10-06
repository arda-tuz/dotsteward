# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the herdr component tests (tests/nix/components/herdr).
#
# Builds on tests/nix/instance/helpers.sh (isolated Nix store, lib.mkInstance
# with constructed inputs). Expressions are evaluated with the instance
# prelude and tests/nix/components/herdr/scope.nix in scope.
#
#   herdr_eval EXPR           evaluates EXPR strictly to JSON; output and
#                             status land in DS_STDOUT, DS_STDERR, DS_STATUS
#   herdr_json EXPR           the JSON value of EXPR (fails the test when the
#                             evaluation fails)
#   assert_herdr_eq EXPECTED_JSON EXPR [MESSAGE]
#                             EXPR evaluates to EXPECTED_JSON (jq-normalized)
#   assert_herdr_fails EXPR NEEDLE...
#                             evaluating EXPR fails, the error output
#                             contains every NEEDLE

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

herdr_dir=$DS_REPO_ROOT/tests/nix/components/herdr
# shellcheck disable=SC2034 # used by the test files that source this file
herdr_fixture=$herdr_dir/fixtures/instance
# shellcheck disable=SC2034 # used by the test files that source this file
herdr_component=$DS_REPO_ROOT/modules/components/herdr

herdr_eval() {
  (($# == 1)) || ds_fail "herdr_eval: usage: herdr_eval EXPR"
  nix_instance_eval "with import (repoRoot + \"/tests/nix/components/herdr/scope.nix\") { inherit lib instance nixpkgsInput repoRoot storeless; }; ($1)"
}

herdr_json() {
  herdr_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

assert_herdr_eq() {
  (($# >= 2)) || ds_fail "assert_herdr_eq: usage: assert_herdr_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_herdr_eq: invalid expected JSON: $1"
  actual=$(herdr_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

assert_herdr_fails() {
  (($# >= 2)) || ds_fail "assert_herdr_fails: usage: assert_herdr_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if herdr_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}
