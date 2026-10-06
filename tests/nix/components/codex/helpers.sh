# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the codex catalog component tests (tests/nix/components/codex).
# Not a test file.
#
# Builds on tests/nix/instance/helpers.sh: expressions are evaluated with
# tests/nix/instance/prelude.nix in scope, so an instance directory written
# here is evaluated by the real lib.mkInstance with the real catalog.
#
#   codex_seed              modules/components/codex/seed.json
#   codex_instance NAME [SYSTEMS_JSON] [TOML_LINES]
#                           writes the instance DS_TEST_ROOT/NAME and prints
#                           its path: workstation.toml with the profile
#                           "workstation" (fresh mode), nix.systems
#                           SYSTEMS_JSON (default ["x86_64-linux"]) and
#                           [components.codex] enable = true followed by
#                           TOML_LINES; versions.lock.json = the minimal
#                           instance lock with the seed's versions_lock
#                           merged in (what dotsteward init writes); an empty
#                           skills lock; home/AGENTS.md; home.nix without
#                           framework skills, so the agents runs do not
#                           depend on a built generation
#   codex_expr DIR          the Nix expression of the instance in DIR
#   codex_lock_set DIR PATH JSON
#                           sets the dotted PATH of DIR/versions.lock.json
#   codex_mirror DIR        writes the mirrors of DIR (.dotsteward/)
#   codex_cli DIR ARG...    the framework CLI of the checkout under test with
#                           --instance DIR (standard input empty)
#   codex_hermetic_path     drops every PATH directory that holds a codex or
#                           local-maintained-files command of the host, then
#                           puts DS_TEST_ROOT/tools first: a stand-in for the
#                           local-maintained-files alias core requires
#   codex_home_state        a listing of HOME (paths, types, modes and file
#                           digests) for no-change comparisons

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

# The isolated store and the nixpkgs and home-manager paths, once per test
# file (evaluations run in command substitutions, whose setup would be lost).
nix_core_init

codex_seed=$DS_REPO_ROOT/modules/components/codex/seed.json
_codex_minimal=$DS_REPO_ROOT/tests/fixtures/instances/minimal

codex_instance() {
  (($# >= 1 && $# <= 3)) || ds_fail "codex_instance: usage: codex_instance NAME [SYSTEMS_JSON] [TOML_LINES]"
  local dir=$DS_TEST_ROOT/$1 systems=${2:-'["x86_64-linux"]'} extra=${3:-}
  [[ -f $codex_seed ]] || ds_fail "missing $codex_seed"
  rm -rf -- "$dir"
  mkdir -p "$dir/agent/skills"
  cp -R "$_codex_minimal/home" "$_codex_minimal/local-maintained-files" "$dir/"
  chmod -R u+w "$dir"
  cat >"$dir/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "git@github.com:alice/workstation.git"

[nix]
systems = $systems
state_version = "25.11"

[profiles]
names = ["workstation"]

[components.codex]
enable = true
$extra
EOF
  jq --indent 2 -s '.[0] * .[1].versions_lock' "$_codex_minimal/versions.lock.json" "$codex_seed" \
    >"$dir/versions.lock.json"
  jq -n '{ schema_version: "1.0", expected_skill_count: 0, skills: [] }' >"$dir/agent/skills.lock.json"
  printf '{ ... }:\n{\n  dotsteward.skills.framework = [ ];\n}\n' >"$dir/home.nix"
  printf '%s\n' "$dir"
}

codex_expr() {
  (($# == 1)) || ds_fail "codex_expr: usage: codex_expr DIR"
  printf 'instance { root = /. + "%s"; }' "$1"
}

codex_lock_set() {
  (($# == 3)) || ds_fail "codex_lock_set: usage: codex_lock_set DIR PATH JSON"
  local tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 --arg path "$2" --argjson value "$3" 'setpath($path | split("."); $value)' \
    "$1/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$1/versions.lock.json"
}

codex_mirror() {
  (($# == 1)) || ds_fail "codex_mirror: usage: codex_mirror DIR"
  write_mirrors "$(codex_expr "$1")" "$1"
}

codex_cli() {
  (($# >= 2)) || ds_fail "codex_cli: usage: codex_cli DIR ARG..."
  local dir=$1
  shift
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$dir" "$@" </dev/null
}

codex_hermetic_path() {
  local entry kept=() tools=$DS_TEST_ROOT/tools
  local IFS=:
  for entry in $PATH; do
    [[ -n $entry && ! -e $entry/codex && ! -e $entry/local-maintained-files ]] || continue
    kept+=("$entry")
  done
  mkdir -p "$tools"
  printf '#!%s\nexit 0\n' "$BASH" >"$tools/local-maintained-files"
  chmod 0755 "$tools/local-maintained-files"
  PATH="$tools:${kept[*]}"
  export PATH
  hash -r
}

codex_home_state() {
  (cd "$HOME" && find . -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort -k 2)
}
