# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the core Home Manager module tests (tests/nix/core).
#
# Builds on tests/nix/lib/helpers.sh (isolated Nix store, locked nixpkgs).
# Expressions are evaluated with tests/nix/core/prelude.nix in scope, which
# adds Home Manager configurations built with modules/core.
#
# Inputs (besides those of tests/nix/lib/helpers.sh):
#   DS_HOME_MANAGER   home-manager source path; the sandbox check exports it.
#                     Without it the path is computed from the locked narHash
#                     in flake.lock (offline), and fetched only when it is
#                     missing from the host store.

# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

nix_core_dir=$DS_REPO_ROOT/tests/nix/core
# shellcheck disable=SC2034 # used by the test files that source this file
nix_core_fixtures=$nix_core_dir/fixtures

# Prints the store path of the locked home-manager input.
_nix_core_locked_home_manager() {
  local lock=$DS_REPO_ROOT/flake.lock sri hex base32 path
  sri=$(jq -er '.nodes[.nodes.root.inputs["home-manager"]].locked.narHash' "$lock")
  [[ $sri == sha256-* ]] || ds_fail "unexpected home-manager narHash in flake.lock: [$sri]"
  hex=$(printf '%s' "${sri#sha256-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')
  base32=$(nix-hash --type sha256 --to-base32 "$hex")
  path=$(nix-store --print-fixed-path --recursive sha256 "$base32" source)
  if [[ ! -d $path ]]; then
    path=$(nix "${nix_lib_host_features[@]}" eval --raw --impure --expr \
      "(builtins.fetchTree (builtins.fromJSON (builtins.readFile $lock)).nodes.\"home-manager\".locked).outPath")
  fi
  [[ -d $path/modules ]] || ds_fail "locked home-manager not found: [$path]"
  printf '%s\n' "$path"
}

nix_core_init() {
  [[ -n ${nix_lib_store:-} ]] || nix_lib_init
  if [[ -z ${DS_HOME_MANAGER:-} ]]; then
    DS_HOME_MANAGER=$(_nix_core_locked_home_manager)
  fi
  export DS_HOME_MANAGER
}

# nix_core_eval EXPR: evaluates EXPR strictly to JSON with the core prelude
# in scope. Output and status land in DS_STDOUT, DS_STDERR and DS_STATUS; the
# status of the evaluation is returned.
nix_core_eval() {
  (($# == 1)) || ds_fail "nix_core_eval: usage: nix_core_eval EXPR"
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  local expr="{ nixpkgs, homeManager, repo }: with import (/. + repo + \"/tests/nix/core/prelude.nix\") { inherit nixpkgs homeManager repo; }; ($1)"
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
    --argstr repo "$DS_REPO_ROOT" \
    --expr "$expr" >"$out_file" 2>"$err_file" || DS_STATUS=$?
  DS_STDOUT=$(<"$out_file")
  DS_STDERR=$(<"$err_file")
  return "$DS_STATUS"
}

# core_json EXPR: prints the JSON value of EXPR, failing the test when the
# evaluation fails.
core_json() {
  nix_core_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

# core_raw EXPR: prints the string value of EXPR without JSON quoting.
core_raw() {
  core_json "$1" | jq -j .
}

# assert_core_eq EXPECTED_JSON EXPR [MESSAGE]: EXPR evaluates to the JSON
# value EXPECTED_JSON (compared after jq normalization, key order ignored).
assert_core_eq() {
  (($# >= 2)) || ds_fail "assert_core_eq: usage: assert_core_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_core_eq: invalid expected JSON: $1"
  actual=$(core_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

# assert_core_fails EXPR NEEDLE... : evaluating EXPR fails and the error
# output contains every NEEDLE (fixed strings).
assert_core_fails() {
  (($# >= 2)) || ds_fail "assert_core_fails: usage: assert_core_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if nix_core_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}

# json_check JSON JQ_FILTER EXPECTED_COMPACT_JSON: the jq filter applied to
# JSON gives EXPECTED (compact, sorted keys).
json_check() {
  (($# == 3)) || ds_fail "json_check: usage: json_check JSON FILTER EXPECTED"
  assert_eq "$3" "$(jq -cS "$2" <<<"$1")" "$2"
}
