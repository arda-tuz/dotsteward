# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the settings engine tests (tests/engines/settings/core). Not a
# test file. Sourcing it puts a python3 with tomlkit first on PATH: the one on
# PATH when it has tomlkit (the Nix check sandbox), else the framework's own
# interpreter (packages.<system>.dotsteward.python) built with Nix.
#
#   settings ARG...           runs `cli/dotsteward settings ARG...` of the
#                             framework under test
#   lmf MACHINE ARG...        settings with --repo, --home and --state-dir of
#                             machine MACHINE (directories below
#                             $settings_work/MACHINE)
#   settings_machines [BUFFER_DIR]
#                             a bare remote seeded with BUFFER_DIR (default:
#                             fixtures/buffer) as local-maintained-files/,
#                             and machines A and B cloned from it
#   settings_repo DIR [BUFFER_DIR]
#                             a git repository at DIR holding BUFFER_DIR as
#                             local-maintained-files/ (one commit, no remote)
#   settings_buffer MACHINE   writes standard input as the buffer of machine
#                             MACHINE (a repository without remote, created
#                             on first use) and commits it
#   state_of MACHINE ID       the state of entry ID in `status --json`
#   status_field MACHINE ID JQ
#                             a jq filter over entry ID of `status --json`
#   toml_get FILE DOTTED      the value at DOTTED as compact sorted JSON, or
#   json_get FILE DOTTED      <absent>
#   buffer_get MACHINE ID     the buffer value of entry ID as compact sorted
#                             JSON, or <absent>
#   buffer_has REPO ID        status 0 when the buffer of REPO has entry ID
#   publish MACHINE           commits and pushes the repository, then runs
#                             reconcile
#   pull MACHINE              fast-forwards the repository from origin
#   sha FILE                  the sha256 of FILE
#   set_line FILE REGEX TEXT  replaces every line matching REGEX with TEXT
#   json_edit FILE PYTHON     runs PYTHON with `data` bound to the parsed
#                             JSON of FILE, then writes it back with indent 2
#                             (and a trailing newline unless NO_NEWLINE=1)

# shellcheck disable=SC2034 # used by the test files that source this file
settings_fixtures=$DS_REPO_ROOT/tests/engines/settings/core/fixtures
settings_work=$DS_TEST_ROOT/settings

_settings_use_python() {
  if python3 -c 'import tomlkit' >/dev/null 2>&1; then
    return 0
  fi
  command -v nix >/dev/null 2>&1 ||
    ds_fail "the settings tests need python3 with tomlkit on PATH, or nix to build it"
  local machine system out
  machine=$(uname -m)
  case $machine in
    x86_64 | amd64) machine=x86_64 ;;
    arm64 | aarch64) machine=aarch64 ;;
  esac
  case $(uname -s) in
    Linux) system=$machine-linux ;;
    Darwin) system=$machine-darwin ;;
    *) ds_fail "unsupported system: $(uname -s)" ;;
  esac
  out=$(nix --extra-experimental-features 'nix-command flakes' build --no-link \
    --print-out-paths "$DS_REPO_ROOT#packages.$system.dotsteward.python") ||
    ds_fail "cannot build the framework python with Nix"
  mkdir -p "$DS_TEST_ROOT/python/bin"
  ln -s "$out/bin/python3" "$DS_TEST_ROOT/python/bin/python3"
  export PATH=$DS_TEST_ROOT/python/bin:$PATH
}
_settings_use_python

settings() {
  "$DS_REPO_ROOT/cli/dotsteward" settings "$@"
}

lmf() {
  local machine=$1
  shift
  settings --repo "$settings_work/$machine/repo" --home "$settings_work/$machine/home" \
    --state-dir "$settings_work/$machine/state" "$@"
}

settings_repo() {
  local dir=$1 buffer=${2:-$settings_fixtures/buffer}
  mkdir -p "$dir"
  git init -q -b main "$dir"
  cp -R "$buffer" "$dir/local-maintained-files"
  chmod -R u+w "$dir/local-maintained-files"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: seed local maintained settings"
}

settings_buffer() {
  local machine=$1 repo=$settings_work/$1/repo
  mkdir -p "$settings_work/$machine/home"
  if [[ ! -d $repo/.git ]]; then
    mkdir -p "$repo"
    git init -q -b main "$repo"
  fi
  mkdir -p "$repo/local-maintained-files/files"
  cat >"$repo/local-maintained-files/buffer.toml"
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "chore: write the settings buffer"
}

settings_machines() {
  local machine
  mkdir -p "$settings_work"
  settings_repo "$settings_work/seed" "${1:-$settings_fixtures/buffer}"
  git init -q --bare -b main "$settings_work/remote.git"
  git -C "$settings_work/seed" remote add origin "$settings_work/remote.git"
  git -C "$settings_work/seed" push -q origin main
  for machine in A B; do
    mkdir -p "$settings_work/$machine/home"
    git clone -q "$settings_work/remote.git" "$settings_work/$machine/repo"
  done
}

status_field() {
  lmf "$1" status --json | jq -c --arg id "$2" ".entries[] | select(.id == \$id) | $3"
}

state_of() {
  lmf "$1" status --json | jq -r --arg id "$2" '.entries[] | select(.id == $id) | .state'
}

toml_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], "rb") as handle:
    node = tomllib.load(handle)
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        print("<absent>")
        raise SystemExit
    node = node[part]
print(json.dumps(node, sort_keys=True))
PY
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    node = json.load(handle)
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        print("<absent>")
        raise SystemExit
    node = node[part]
print(json.dumps(node, sort_keys=True))
PY
}

buffer_get() {
  python3 - "$settings_work/$1/repo/local-maintained-files/buffer.toml" "$2" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
entry = next(item for item in data["entries"] if item["id"] == sys.argv[2])
print("<absent>" if entry.get("absent") else json.dumps(entry["value"], sort_keys=True))
PY
}

buffer_has() {
  python3 - "$1/local-maintained-files/buffer.toml" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
sys.exit(0 if any(item.get("id") == sys.argv[2] for item in data.get("entries", [])) else 1)
PY
}

publish() {
  local repo=$settings_work/$1/repo
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore: sync local maintained settings"
  git -C "$repo" push -q origin main
  lmf "$1" reconcile >/dev/null
}

pull() {
  git -C "$settings_work/$1/repo" pull -q --ff-only
}

sha() {
  local line
  line=$(sha256sum -- "$1")
  printf '%s\n' "${line%% *}"
}

set_line() {
  python3 - "$@" <<'PY'
import re, sys
path, pattern, text = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
lines = [text if re.fullmatch(pattern, line) else line for line in lines]
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
}

json_edit() {
  NO_NEWLINE=${NO_NEWLINE:-0} python3 - "$1" "$2" <<'PY'
import json, os, sys
path, code = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
scope = {"data": data}
exec(code, scope)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(scope["data"], handle, indent=2)
    if os.environ["NO_NEWLINE"] != "1":
        handle.write("\n")
PY
}
