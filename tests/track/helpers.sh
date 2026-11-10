# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and up_* variables come from the harness and the helpers
# shellcheck disable=SC2034 # the paths are read by the test files
# Helpers for the tests of `dotsteward add`, `dotsteward remove` and `dotsteward status`
# (tests/track). Not a test file.
#
# Sourcing this file sources tests/apply/helpers.sh: the synthetic instance up_inst with a bare
# remote behind the fake SSH transport, a machine named example-host with the profile workstation,
# the real dispatcher, maintain begin, apply, gate and txn, and the fakes of generate, rebuild, e2e,
# install, preflight, settings, pins, static, probes and scan that log to UP_LOG. The catalog of
# the framework copy also holds example-viewer, which the instance does not enable. It adds:
#
#   add ARG...              dotsteward add through the dispatcher, standard input empty, no terminal
#   remove ARG...           dotsteward remove, the same way
#   status ARG...           dotsteward status, the same way
#   on_terminal_run ANSWER... -- COMMAND ARG...
#                           a dotsteward COMMAND on a terminal of its own
#   toml_at REF FILTER      jq FILTER over workstation.toml of REF (a commit, or "work" for the
#                           checkout) is true
#   component_entry NAME JSON
#                           a component NAME in the manifest mirror, its fields JSON, committed and
#                           published
#   enable_component NAME [TOML]
#                           a [components.NAME] table with enable = true and TOML lines, committed
#                           and published
#   snapshot                every ref, the work tree, the index and the state root, as one listing

# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

ds_use_stubs apt-cache
# The stubs went first on PATH: the wrapper that logs each sudo call goes before them again.
export PATH=$DS_TEST_ROOT/up-bin:$PATH
mkdir -p "$fw/modules/components/example-viewer"

add() {
  "$fw/cli/dotsteward" --instance "$up_inst" add "$@" </dev/null
}

remove() {
  "$fw/cli/dotsteward" --instance "$up_inst" remove "$@" </dev/null
}

status() {
  "$fw/cli/dotsteward" --instance "$up_inst" status "$@" </dev/null
}

on_terminal_run() {
  local answers=()
  while (($#)) && [[ $1 != -- ]]; do
    answers+=(--answer "$1")
    shift
  done
  shift
  python3 "$DS_REPO_ROOT/tests/upgrade/terminal.py" ${answers[@]+"${answers[@]}"} -- \
    "$fw/cli/dotsteward" --instance "$up_inst" "$@"
}

toml_at() {
  local text
  if [[ $1 == work ]]; then
    text=$(<"$up_inst/workstation.toml")
  else
    text=$(git -C "$up_inst" show "$1:workstation.toml")
  fi
  printf '%s\n' "$text" | python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read())))' \
    >"$DS_TEST_ROOT/toml.json"
  assert_json "$DS_TEST_ROOT/toml.json" "$2"
}

component_entry() {
  local name=$1 fields=$2
  jq --arg name "$name" --argjson fields "$fields" \
    '.components += [{name: $name, profiles: null, platforms: ["linux"], install: {}} + $fields]' \
    "$mirror" >"$mirror.new"
  mv -- "$mirror.new" "$mirror"
  git -C "$up_inst" add -A
  git -C "$up_inst" commit -q -m "chore: the mirror knows $name"
  git -C "$up_inst" push -q origin HEAD:main
}

enable_component() {
  printf '\n[components.%s]\nenable = true\n%s\n' "$1" "${2:-}" >>"$up_inst/workstation.toml"
  git -C "$up_inst" add -A
  git -C "$up_inst" commit -q -m "feat: track $1"
  git -C "$up_inst" push -q origin HEAD:main
}

snapshot() {
  {
    git -C "$up_inst" for-each-ref --format='%(refname) %(objectname)'
    git -C "$up_inst" rev-parse HEAD
    git -C "$up_inst" status --porcelain --untracked-files=all
    git -C "$up_inst" stash list
    sha256sum "$up_inst/.git/index"
    find "$DOTSTEWARD_STATE_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort
  } 2>&1
}
