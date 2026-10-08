# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Helpers for the init tests (tests/instance/init): `dotsteward init`
# end to end, with the nix stub answering through
# fake-nix.sh (an offline `nix flake lock` and evaluations of the staged
# instance by lib.mkInstance of the framework under test), so the tests run
# the same on a developer machine and inside checks.init.
#
# Builds on tests/instance/template/helpers.sh: DS_CLI, tpl, python3 with
# tomlkit first on PATH, instance_contract and commit_all.
#
#   init_use_nix               puts the nix stub (with the fake-nix.sh
#                              override) first on PATH
#   init_run STATUS ARG...     runs `dotsteward init ARG...` and asserts its
#                              exit status (DS_STDOUT, DS_STDERR, DS_STATUS)
#   init_staged                the directory of the last copy fake-nix.sh
#                              took of a staged instance at `nix flake lock`
#                              (what init composed before any Nix step)
#   init_staged_count          how many instances were staged
#   toml_json FILE             the TOML file FILE as JSON
#   assert_jq INPUT EXPR [JQ_ARG...]
#                              `jq -e EXPR` is true for the file INPUT (or
#                              standard input when INPUT is -), with extra jq
#                              arguments such as --arg NAME VALUE
#   init_temp_dirs             the dotsteward-init temporary directories
#                              left in TMPDIR, one per line
#   tree_state DIR             a listing of every path below DIR with its
#                              type, mode, size and content digest
#   assert_unchanged DIR STATE [MESSAGE]
#                              DIR still has the tree_state STATE
#   flake_inputs_block FILE    the lines between the inputs markers of FILE
#   framework_copy             a writable copy of the framework under test
#                              (prints its path), for seed mutations
#   seed_merge FIELD LOCK SEED...
#                              the jq deep merge of the seeds' FIELD
#                              (versions_lock or skills_lock) into LOCK in
#                              seed order, as init composes it (generated_at
#                              removed; jq keeps the key order: the lock's
#                              keys first, then the new ones)

# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

init_tests=$DS_REPO_ROOT/tests/instance/init
# shellcheck disable=SC2034 # used by the test files that source this file
init_fixtures=$init_tests/fixtures
# The remote every test instance records.
# shellcheck disable=SC2034 # used by the test files that source this file
init_remote=git@github.com:alice/workstation.git
# shellcheck disable=SC2034 # used by the test files that source this file
init_catalog=(shell herdr claude-code codex opencode-pi vscode)

init_use_nix() {
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  export DS_NIXPKGS DS_HOME_MANAGER
  export DS_INIT_NIX_STORE=$nix_lib_store
  ds_use_stubs nix
  ds_stub_override nix <<'EOF'
#!/usr/bin/env bash
exec bash "$DS_REPO_ROOT/tests/instance/init/fake-nix.sh" "$@"
EOF
}

init_run() {
  (($# >= 1)) || ds_fail "init_run: usage: init_run STATUS ARG..."
  local status=$1
  shift
  assert_exit "$status" "${DS_INIT_CLI:-$DS_CLI}" init "$@"
}

tree_state() {
  [[ -e $1 || -L $1 ]] || {
    printf 'absent\n'
    return 0
  }
  (
    cd "$1"
    find . -mindepth 0 -printf '%p %y %m %s\n' | LC_ALL=C sort |
      while IFS= read -r line; do
        path=${line%% *}
        if [[ -f $path && ! -L $path ]]; then
          printf '%s %s\n' "$line" "$(sha256sum <"$path" | cut -d' ' -f1)"
        elif [[ -L $path ]]; then
          printf '%s -> %s\n' "$line" "$(readlink "$path")"
        else
          printf '%s\n' "$line"
        fi
      done
  )
}

assert_unchanged() {
  (($# >= 2)) || ds_fail "assert_unchanged: usage: assert_unchanged DIR STATE [MESSAGE]"
  local now
  now=$(tree_state "$1")
  [[ $now == "$2" ]] || ds_fail "${3:-$1 changed}: $(diff <(printf '%s\n' "$2") <(printf '%s\n' "$now") || true)"
}

flake_inputs_block() {
  sed -n '/# dotsteward:inputs:begin/,/# dotsteward:inputs:end/{/# dotsteward:inputs:/d;p}' "$1"
}

framework_copy() {
  local fw
  fw=$(mktemp -d "$DS_TEST_ROOT/framework.XXXXXX")
  (cd "$DS_REPO_ROOT" && tar --exclude=./.git -cf - .) | (cd "$fw" && tar -xf -)
  chmod -R u+w "$fw"
  printf '%s\n' "$fw"
}

seed_merge() {
  local field=$1 lock=$2
  shift 2
  jq --slurpfile seeds <(jq -s --arg field "$field" 'map(.[$field] // {})' "$@") \
    'del(.generated_at) | reduce $seeds[0][] as $fragment (.; . * $fragment)' "$lock"
}

init_staged() {
  local count
  count=$(init_staged_count)
  ((count > 0)) || ds_fail "no instance was staged (nix flake lock never ran)"
  printf '%s\n' "$DS_STUB_STATE/nix/staged/$count"
}

init_staged_count() {
  if [[ -d $DS_STUB_STATE/nix/staged ]]; then
    find "$DS_STUB_STATE/nix/staged" -mindepth 1 -maxdepth 1 -type d | wc -l
  else
    printf '0\n'
  fi
}

toml_json() {
  python3 -c 'import json, sys, tomllib
with open(sys.argv[1], "rb") as handle:
    print(json.dumps(tomllib.load(handle)))' "$1"
}

init_temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-init*' -print
}

assert_jq() {
  (($# >= 2)) || ds_fail "assert_jq: usage: assert_jq INPUT EXPR [JQ_ARG...]"
  local input=$1 expression=$2 document
  shift 2
  if [[ $input == - ]]; then
    document=$(cat)
  else
    [[ -f $input ]] || ds_fail "assert_jq: no such file [$input]"
    document=$(<"$input")
  fi
  jq -e "$@" "$expression" >/dev/null 2>&1 <<<"$document" ||
    ds_fail "jq expression [$expression] ($*) is false or invalid for [$document]"
}
