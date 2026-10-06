# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2034 # the gate_* paths are read by the test files
# Helpers for the gate tests (tests/cli/gate). Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   gate_fw        a copy of the framework under test (cli/, schema/,
#                  VERSION and an empty modules/components) whose static,
#                  pins and probes commands are replaced by fakes: each one
#                  records its call as "dotsteward-<command> ARG..." in the
#                  call log, followed by the line "dotsteward-<command>:env"
#                  with DOTSTEWARD_INSTANCE and DOTSTEWARD_FRAMEWORK_OVERRIDE,
#                  prints "fake <command> output" and exits with the status
#                  set by step_fail (default 0). The commands have suites of
#                  their own; the gate tests prove when and how the gate
#                  calls them.
#   gate_inst      a synthetic instance: a git repository on main with
#                  workstation.toml (remote GATE_REMOTE, cache URL
#                  GATE_CACHE_URL, min_free_gib 0, the instance allowlist
#                  entry notes/[^/]+\.txt), versions.lock.json, flake.nix,
#                  flake.lock, agent/skills.lock.json, the manifest mirror
#                  .dotsteward/manifest.x86_64-linux.json (update_allowlist
#                  components/example-app/version\.txt), the settings buffer
#                  local-maintained-files/buffer.toml, docs/guide.md and
#                  components/example-app/{default.nix,version.txt}, all
#                  committed; origin is a local bare repository (so
#                  origin/main exists) whose URL is then set to GATE_REMOTE
#   gate_state     the gate state directory (<state root>/update)
#   gate_validation, gate_candidate, gate_log, gate_lockfile
#                  the files inside it
#
#   run_gate ARG...           dotsteward --instance <instance> gate ARG...
#                             through the copied dispatcher, standard input
#                             empty
#   step_fail COMMAND STATUS  the fake COMMAND (static, pins or probes)
#                             exits with STATUS from now on
#   serve_cache               the curl stub answers the binary cache probe
#   gate_config TOML          appends TOML to workstation.toml and commits
#                             it
#   commit_all MESSAGE        git add -A and commit in the instance
#   head_oid                  the instance HEAD commit
#   add_tree_oid              the tree `git add -A && git write-tree` would
#                             write, computed in a scratch copy of the
#                             instance
#   step_lines                the "[dotsteward] <step> ..." lines of DS_STDOUT,
#                             reduced to their step names
#   fake_calls                the fake command calls of the call log, in
#                             order, as "<command> ARG..."
#   nix_line ARG...           the call-log line of `nix_cmd ARG...` (nix
#                             with the experimental features option)
#   publish_base              moves origin/main to HEAD (as if HEAD were
#                             published), so committed changes become the
#                             base
#   set_toml TABLE KEY VALUE  sets KEY = VALUE (TOML text) in [TABLE] of
#                             workstation.toml, adding the table or key
#                             when missing (not committed)
#   temp_dirs                 the dotsteward-* directories left in TMPDIR,
#                             except the ones of the test helpers themselves

# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"

GATE_REMOTE=git@github.com:alice/workstation.git
GATE_CACHE_URL=https://cache.example.invalid

gate_fw=$DS_TEST_ROOT/framework
gate_inst=$DS_TEST_ROOT/instance
gate_state=$DOTSTEWARD_STATE_ROOT/update
gate_validation=$gate_state/validation.json
gate_candidate=$gate_state/candidate.json
gate_log=$gate_state/validate.log
gate_lockfile=$gate_state/validate.lock

# --- framework copy -----------------------------------------------------------

mkdir -p "$gate_fw/modules/components"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$gate_fw/"
find "$gate_fw/cli" -name __pycache__ -prune -exec rm -rf {} +

_write_fake_command() {
  local command=$1
  cat >"$gate_fw/cli/commands/$command.sh" <<EOF
#!/usr/bin/env bash
# summary: Fake $command command of the gate tests
set -euo pipefail
# shellcheck source=tests/lib/harness.sh
source "\$DS_REPO_ROOT/tests/lib/harness.sh"
DS_STUB_ENV_DEFAULT="DOTSTEWARD_INSTANCE DOTSTEWARD_FRAMEWORK_OVERRIDE"
ds_stub_begin --no-routes dotsteward-$command "\$@"
printf 'fake %s output\n' $command
exit "\$(ds_stub_value status 0)"
EOF
  chmod 0755 "$gate_fw/cli/commands/$command.sh"
}
for _command in static pins probes; do
  _write_fake_command "$_command"
done
unset _command

step_fail() {
  (($# == 2)) || ds_fail "usage: step_fail COMMAND STATUS"
  mkdir -p "$DS_STUB_STATE/dotsteward-$1"
  printf '%s\n' "$2" >"$DS_STUB_STATE/dotsteward-$1/status"
}

# --- instance -----------------------------------------------------------------

ds_git_repo "$gate_inst"
cat >"$gate_inst/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "$GATE_REMOTE"

[nix]
state_version = "25.11"

[profiles]
names = ["workstation"]

[gate]
min_free_gib = 0
cache_url = "$GATE_CACHE_URL"
update_allowlist = ['notes/[^/]+\.txt']
EOF
printf '{\n  "schema_version": "1.0"\n}\n' >"$gate_inst/versions.lock.json"
printf '{ outputs = _: { }; }\n' >"$gate_inst/flake.nix"
printf '{\n  "nodes": {},\n  "version": 7\n}\n' >"$gate_inst/flake.lock"
mkdir -p "$gate_inst/agent/skills" "$gate_inst/.dotsteward" "$gate_inst/local-maintained-files" \
  "$gate_inst/docs" "$gate_inst/components/example-app"
printf '{\n  "schema_version": "1.0",\n  "skills": []\n}\n' >"$gate_inst/agent/skills.lock.json"
jq -n '{schema_version: 1, system: "x86_64-linux", update_allowlist: ["components/example-app/version\\.txt"]}' \
  >"$gate_inst/.dotsteward/manifest.x86_64-linux.json"
printf 'schema_version = 1\n' >"$gate_inst/local-maintained-files/buffer.toml"
printf '# Guide\n' >"$gate_inst/docs/guide.md"
printf '{ ... }: { }\n' >"$gate_inst/components/example-app/default.nix"
printf '1.0.0\n' >"$gate_inst/components/example-app/version.txt"
printf '/ignored/\n' >"$gate_inst/.gitignore"
git -C "$gate_inst" add -A
git -C "$gate_inst" commit -q -m "chore: add the instance"
ds_bare_remote "$DS_TEST_ROOT/remote.git" "$gate_inst"
git -C "$gate_inst" remote set-url origin "$GATE_REMOTE"

# --- helpers ------------------------------------------------------------------

run_gate() {
  "$gate_fw/cli/dotsteward" --instance "$gate_inst" gate "$@" </dev/null
}

serve_cache() {
  local file=$DS_TEST_ROOT/nix-cache-info
  printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n' >"$file"
  ds_curl_serve "$GATE_CACHE_URL/nix-cache-info" "$file"
}

gate_config() {
  (($# == 1)) || ds_fail "usage: gate_config TOML"
  printf '%s\n' "$1" >>"$gate_inst/workstation.toml"
  commit_all "chore: configure the instance"
}

commit_all() {
  git -C "$gate_inst" add -A
  git -C "$gate_inst" commit -q -m "$1"
}

head_oid() {
  git -C "$gate_inst" rev-parse HEAD
}

add_tree_oid() {
  local copy=$DS_TEST_ROOT/tree-copy
  rm -rf -- "$copy"
  cp -a "$gate_inst" "$copy"
  git -C "$copy" add -A
  git -C "$copy" write-tree
  rm -rf -- "$copy"
}

step_lines() {
  sed -n 's/^\[dotsteward\] \([a-z-]*\) \{1,\}ok ([0-9]*s)$/\1/p' <<<"$DS_STDOUT"
}

fake_calls() {
  [[ -f $DS_CALL_LOG ]] || return 0
  awk '$1 ~ /^dotsteward-[a-z]+$/ { sub(/^dotsteward-/, ""); print }' "$DS_CALL_LOG"
}

nix_line() {
  _ds_call_line nix --extra-experimental-features 'nix-command flakes' "$@"
}

publish_base() {
  git -C "$gate_inst" update-ref refs/remotes/origin/main HEAD
}

set_toml() {
  (($# == 3)) || ds_fail "usage: set_toml TABLE KEY VALUE"
  python3 - "$gate_inst/workstation.toml" "$1" "$2" "$3" <<'PY'
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

temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -printf '%f\n' |
    LC_ALL=C sort
}
