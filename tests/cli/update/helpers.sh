# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2034 # the up_* paths are read by the test files
# Helpers for the update tests (tests/cli/update). Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   up_inst        a synthetic instance: a git repository on main with
#                  workstation.toml (remote UP_REMOTE, cache URL
#                  UP_CACHE_URL, prepare_warn_free_gib 0, min_free_gib 0),
#                  versions.lock.json, flake.nix, flake.lock and docs/guide.md,
#                  all committed and pushed to
#   up_bare        a bare repository served for UP_REMOTE through the fake
#                  SSH transport (tests/lib/fakessh.sh), so every network git
#                  call of the command under test uses the byte-identical
#                  SSH URL; origin/main of the instance exists
#   up_state       the update state directory (<state root>/update)
#   up_candidate, up_validation, up_log
#                  the files inside it
#
#   run_update ARG...         dotsteward --instance <instance> update ARG...
#                             through the dispatcher under test, standard
#                             input empty
#   serve_cache               the curl stub answers the binary cache probe
#   commit_all MESSAGE        git add -A and commit in the instance
#   change_and_commit MESSAGE appends a line to docs/guide.md and commits
#   head_oid, head_tree       the instance HEAD commit and its tree
#   remote_oid                main of the bare repository
#   write_validation [JQ_FILTER]
#                             writes a passed validation.json (schema 1.1)
#                             for the HEAD tree, scope maintain, no
#                             framework override, then applies JQ_FILTER
#   write_candidate BASE [ROOT]
#                             writes candidate.json with BASE for ROOT
#                             (default: the instance)
#   push_from_elsewhere MESSAGE
#                             a second clone commits and pushes to the bare
#                             repository (the remote moves)
#   set_toml TABLE KEY VALUE  sets KEY = VALUE (TOML text) in [TABLE] of
#                             workstation.toml, adding the table or key when
#                             missing (not committed)
#   path_without NAME...      PATH with every directory that holds one of
#                             NAME... replaced by a directory of links to
#                             its other entries
#   network_calls             the fake SSH log (one line per connection)
#   assert_no_network         no connection was made since the log was reset
#   reset_logs                empties the call log and the fake SSH log
#   temp_dirs                 the dotsteward-* directories left in TMPDIR,
#                             except the ones of the test helpers themselves

# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

UP_REMOTE=git@github.com:alice/workstation.git
UP_CACHE_URL=https://cache.example.invalid
UP_UPDATE_SUBJECT='chore: update pinned tool versions'

up_inst=$DS_TEST_ROOT/instance
up_bare=$DS_TEST_ROOT/remote.git
up_state=$DOTSTEWARD_STATE_ROOT/update
up_candidate=$up_state/candidate.json
up_validation=$up_state/validation.json
up_log=$up_state/validate.log

# --- instance -----------------------------------------------------------------

ds_git_repo "$up_inst"
cat >"$up_inst/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "$UP_REMOTE"

[nix]
state_version = "25.11"

[profiles]
names = ["workstation"]

[gate]
min_free_gib = 0
prepare_warn_free_gib = 0
cache_url = "$UP_CACHE_URL"
EOF
printf '{\n  "schema_version": "1.0"\n}\n' >"$up_inst/versions.lock.json"
printf '{ outputs = _: { }; }\n' >"$up_inst/flake.nix"
printf '{\n  "nodes": {},\n  "version": 7\n}\n' >"$up_inst/flake.lock"
mkdir -p "$up_inst/docs"
printf '# Guide\n' >"$up_inst/docs/guide.md"
printf '/ignored/\n' >"$up_inst/.gitignore"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: add the instance"
ds_bare_remote "$up_bare" "$up_inst"
git -C "$up_inst" remote set-url origin "$UP_REMOTE"
ds_fakessh_enable
ds_fakessh_map "$UP_REMOTE" "$up_bare"

# --- helpers ------------------------------------------------------------------

run_update() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update "$@" </dev/null
}

serve_cache() {
  local file=$DS_TEST_ROOT/nix-cache-info
  printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n' >"$file"
  ds_curl_serve "$UP_CACHE_URL/nix-cache-info" "$file"
}

commit_all() {
  git -C "$up_inst" add -A
  git -C "$up_inst" commit -q -m "$1"
}

change_and_commit() {
  printf 'change %s\n' "$1" >>"$up_inst/docs/guide.md"
  commit_all "$1"
}

head_oid() {
  git -C "$up_inst" rev-parse HEAD
}

head_tree() {
  git -C "$up_inst" rev-parse 'HEAD^{tree}'
}

remote_oid() {
  git -C "$up_bare" rev-parse refs/heads/main
}

write_validation() {
  local filter=${1:-.}
  mkdir -p "$up_state"
  jq -n --arg tree "$(head_tree)" --arg root "$up_inst" --arg log "$up_log" '{
    schema_version: "1.1", result: "passed", tree_oid: $tree,
    base_oid: "0000000000000000000000000000000000000000", scope: "maintain",
    nix_version: "nix (Nix) 2.31.2", gate_version: "0.0.0", framework_override: null,
    denylist_sha256: null, root: $root, validated_at: "2026-01-01T00:00:00Z",
    total_seconds: 7, step_seconds: {preflight: 1, static: 1, pins: 1, "flake-check": 3, "cli-probes": 1},
    log: $log}' | jq "$filter" >"$up_validation"
}

write_candidate() {
  (($# == 1 || $# == 2)) || ds_fail "usage: write_candidate BASE [ROOT]"
  mkdir -p "$up_state"
  jq -n --arg base "$1" --arg root "${2:-$up_inst}" '{
    schema_version: "1.1", prepared_at: "2026-01-01T00:00:00Z", base_oid: $base,
    root: $root, scope: "maintain", official_sources_only: true,
    persistent_agentic_updates: false, native_application_updates: true}' >"$up_candidate"
}

push_from_elsewhere() {
  local clone=$DS_TEST_ROOT/elsewhere-clone
  rm -rf -- "$clone"
  git clone -q "$up_bare" "$clone"
  printf 'elsewhere %s\n' "$1" >>"$clone/docs/guide.md"
  git -C "$clone" commit -q -am "$1"
  git -C "$clone" push -q origin HEAD:main
  rm -rf -- "$clone"
}

set_toml() {
  (($# == 3)) || ds_fail "usage: set_toml TABLE KEY VALUE"
  python3 - "$up_inst/workstation.toml" "$1" "$2" "$3" <<'PY'
import re
import sys

path, table, key, value = sys.argv[1:]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
header = f"[{table}]"
out, in_table, done = [], False, False
for line in lines:
    if line.startswith("["):
        if in_table and not done:
            out.append(f"{key} = {value}")
            done = True
        in_table = line.strip() == header
    if in_table and re.match(rf"{re.escape(key)}\s*=", line):
        line, done = f"{key} = {value}", True
    out.append(line)
if not done:
    if not in_table:
        out.append(header)
    out.append(f"{key} = {value}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

path_without() {
  (($#)) || ds_fail "usage: path_without NAME..."
  local entry name skip copy index=0 result=""
  local -a dirs=()
  IFS=: read -r -a dirs <<<"$PATH"
  for entry in "${dirs[@]}"; do
    [[ -n $entry ]] || continue
    copy=""
    for skip in "$@"; do
      if [[ -e $entry/$skip ]]; then
        index=$((index + 1))
        copy=$DS_TEST_ROOT/path-without/$index
        break
      fi
    done
    if [[ -z $copy ]]; then
      result+=${result:+:}$entry
      continue
    fi
    rm -rf -- "$copy"
    mkdir -p "$copy"
    for name in "$entry"/*; do
      [[ -e $name ]] || continue
      for skip in "$@"; do
        [[ ${name##*/} != "$skip" ]] || continue 2
      done
      ln -s "$name" "$copy/${name##*/}"
    done
    result+=${result:+:}$copy
  done
  printf '%s\n' "$result"
}

network_calls() {
  cat -- "$DS_FAKESSH_LOG"
}

assert_no_network() {
  assert_eq "" "$(network_calls)" "unexpected network git calls"
}

reset_logs() {
  : >"$DS_CALL_LOG"
  : >"$DS_FAKESSH_LOG"
}

temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -printf '%f\n' |
    LC_ALL=C sort
}
