# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the github-release-deb component tests (tests/nix/components/github-release-deb).
#
# Builds on tests/nix/instance/helpers.sh (isolated Nix store, lib.mkInstance
# with constructed inputs). Expressions are evaluated with the instance
# prelude and tests/nix/components/github-release-deb/scope.nix in scope.
#
#   craft_eval EXPR          evaluates EXPR strictly to JSON; output and
#                             status land in DS_STDOUT, DS_STDERR, DS_STATUS
#   craft_json EXPR          the JSON value of EXPR (fails the test when the
#                             evaluation fails)
#   assert_craft_eq EXPECTED_JSON EXPR [MESSAGE]
#                             EXPR evaluates to EXPECTED_JSON (jq-normalized)
#   assert_craft_fails EXPR NEEDLE...
#                             evaluating EXPR fails, the error output
#                             contains every NEEDLE

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

craft_dir=$DS_REPO_ROOT/tests/nix/components/github-release-deb
# shellcheck disable=SC2034 # used by the test files that source this file
craft_fixture=$craft_dir/fixtures/instance
# shellcheck disable=SC2034 # used by the test files that source this file
craft_core=$DS_REPO_ROOT/modules/core

craft_eval() {
  (($# == 1)) || ds_fail "craft_eval: usage: craft_eval EXPR"
  nix_instance_eval "with import (repoRoot + \"/tests/nix/components/github-release-deb/scope.nix\") { inherit lib instance repoRoot storeless; }; ($1)"
}

craft_json() {
  craft_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

assert_craft_eq() {
  (($# >= 2)) || ds_fail "assert_craft_eq: usage: assert_craft_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_craft_eq: invalid expected JSON: $1"
  actual=$(craft_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

assert_craft_fails() {
  (($# >= 2)) || ds_fail "assert_craft_fails: usage: assert_craft_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if craft_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}
