# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the Nix library tests (tests/nix/lib).
#
# Expressions are evaluated with nix-instantiate against an isolated, empty
# Nix store and state directory inside DS_TEST_ROOT, so the same tests run on
# a developer machine and inside the Nix build sandbox (checks.nix-lib), and
# never write to the host store. Each expression sees, through
# tests/nix/lib/prelude.nix: lib (nixpkgs lib), dsLib (the dotsteward library
# under test), fixtures (tests/nix/lib/fixtures), loadFixture, resolveToml
# and evalComponents.
#
# Inputs:
#   DS_NIXPKGS             nixpkgs source path; the sandbox check exports it.
#                          Without it the path is computed from the locked
#                          narHash in flake.lock (offline), and fetched only
#                          when it is missing from the host store.
#   DS_JSONSCHEMA_PYTHON   python interpreter with the jsonschema package;
#                          the sandbox check exports it. Without it,
#                          nix_lib_jsonschema_python builds one from the
#                          locked nixpkgs with the host Nix.

nix_lib_dir=$DS_REPO_ROOT/tests/nix/lib
# shellcheck disable=SC2034 # used by the test files that source this file
nix_lib_fixtures=$nix_lib_dir/fixtures
# Host Nix commands run with these features: the harness replaced HOME, so
# the user's own Nix configuration is not read.
nix_lib_host_features=(--extra-experimental-features 'nix-command flakes')

# Prints the store path of the locked nixpkgs input.
_nix_lib_locked_nixpkgs() {
  local lock=$DS_REPO_ROOT/flake.lock sri hex base32 path
  sri=$(jq -er '.nodes[.nodes.root.inputs.nixpkgs].locked.narHash' "$lock")
  [[ $sri == sha256-* ]] || ds_fail "unexpected nixpkgs narHash in flake.lock: [$sri]"
  hex=$(printf '%s' "${sri#sha256-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')
  base32=$(nix-hash --type sha256 --to-base32 "$hex")
  path=$(nix-store --print-fixed-path --recursive sha256 "$base32" source)
  if [[ ! -d $path ]]; then
    # Not in the host store yet: fetch the locked tree once.
    path=$(nix "${nix_lib_host_features[@]}" eval --raw --impure --expr \
      "(builtins.fetchTree (builtins.fromJSON (builtins.readFile $lock)).nodes.nixpkgs.locked).outPath")
  fi
  [[ -d $path/lib ]] || ds_fail "locked nixpkgs not found: [$path]"
  printf '%s\n' "$path"
}

nix_lib_init() {
  command -v nix-instantiate >/dev/null || ds_fail "nix-instantiate is required"
  if [[ -z ${DS_NIXPKGS:-} ]]; then
    DS_NIXPKGS=$(_nix_lib_locked_nixpkgs)
  fi
  export DS_NIXPKGS
  nix_lib_store=$DS_TEST_ROOT/nix
  mkdir -p "$nix_lib_store"/{store,state,log,etc}
}

# nix_lib_eval EXPR: evaluates EXPR strictly to JSON. Output and status land
# in DS_STDOUT, DS_STDERR and DS_STATUS (as for assert_exit); the status of
# the evaluation is returned.
nix_lib_eval() {
  (($# == 1)) || ds_fail "nix_lib_eval: usage: nix_lib_eval EXPR"
  [[ -n ${nix_lib_store:-} ]] || nix_lib_init
  local expr="{ nixpkgs, repo }: with import (/. + repo + \"/tests/nix/lib/prelude.nix\") { inherit nixpkgs repo; }; ($1)"
  local out_file=$DS_TEST_ROOT/nix-eval.out err_file=$DS_TEST_ROOT/nix-eval.err
  DS_STATUS=0
  env -u NIX_REMOTE -u NIX_PATH \
    NIX_STORE_DIR="$nix_lib_store/store" \
    NIX_STATE_DIR="$nix_lib_store/state" \
    NIX_LOG_DIR="$nix_lib_store/log" \
    NIX_CONF_DIR="$nix_lib_store/etc" \
    NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
    nix-instantiate --eval --strict --json --show-trace \
    --argstr nixpkgs "$DS_NIXPKGS" --argstr repo "$DS_REPO_ROOT" \
    --expr "$expr" >"$out_file" 2>"$err_file" || DS_STATUS=$?
  DS_STDOUT=$(<"$out_file")
  DS_STDERR=$(<"$err_file")
  return "$DS_STATUS"
}

# nix_lib_json EXPR: prints the JSON value of EXPR, failing the test when the
# evaluation fails.
nix_lib_json() {
  nix_lib_eval "$1" || ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

# assert_nix_eq EXPECTED_JSON EXPR [MESSAGE]: EXPR evaluates to the JSON value
# EXPECTED_JSON (compared after jq normalization, key order ignored).
assert_nix_eq() {
  (($# >= 2)) || ds_fail "assert_nix_eq: usage: assert_nix_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_nix_eq: invalid expected JSON: $1"
  actual=$(nix_lib_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

# assert_nix_fails EXPR NEEDLE... : evaluating EXPR fails and the error
# output contains every NEEDLE (fixed strings).
assert_nix_fails() {
  (($# >= 2)) || ds_fail "assert_nix_fails: usage: assert_nix_fails EXPR NEEDLE..."
  local expr=$1 needle
  shift
  if nix_lib_eval "$expr"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}

# nix_lib_jsonschema_python: prints a python interpreter that has jsonschema.
nix_lib_jsonschema_python() {
  if [[ -n ${DS_JSONSCHEMA_PYTHON:-} ]]; then
    printf '%s\n' "$DS_JSONSCHEMA_PYTHON"
    return 0
  fi
  [[ -n ${DS_NIXPKGS:-} ]] || nix_lib_init
  local env_path
  env_path=$(nix-build --no-out-link --expr \
    "(import $DS_NIXPKGS { config = { }; overlays = [ ]; }).python3.withPackages (ps: [ ps.jsonschema ])") ||
    ds_fail "cannot build a python with jsonschema"
  printf '%s\n' "$env_path/bin/python3"
}

# toml_fixture NAME CONTENT: writes CONTENT to $DS_TEST_ROOT/toml/NAME.toml
# and prints the path.
toml_fixture() {
  local dir=$DS_TEST_ROOT/toml
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/$1.toml"
  printf '%s\n' "$dir/$1.toml"
}
