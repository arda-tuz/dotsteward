# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# shellcheck disable=SC2034 # read by the test files that source this file
# Helpers for the claude-code component tests (tests/nix/components/
# claude-code). Not a test file.
#
# Builds on tests/nix/instance/helpers.sh: expressions are evaluated with
# tests/nix/instance/prelude.nix in scope against the framework under test,
# whose catalog holds modules/components/claude-code. In addition the scope
# of cc_json has:
#   ccRoot             the fixture instance (fixtures/instance)
#   ccCase NAME        a fixtures/cases/NAME.toml path (a config argument)
#   cc ARGS            instance (ARGS // { root = ccRoot; })
#   ccHome I SYSTEM    the Home Manager config of profile workstation
#   ccComponent I SYSTEM
#                      its dotsteward.components.claude-code
#   ccManifest I SYSTEM
#                      the manifest of SYSTEM (dotstewardManifest)
#   ccEntry I SYSTEM   the manifest entry of claude-code
#
#   cc_json EXPR       prints the JSON value of EXPR (fails the test when the
#                      evaluation fails)
#   assert_cc_eq EXPECTED_JSON EXPR [MESSAGE]
#                      EXPR evaluates to EXPECTED_JSON (key order ignored)
#   assert_cc_fails EXPR NEEDLE...
#                      evaluating EXPR fails with every NEEDLE in the error
#   cc_seed            path of the component seed
#   cc_fixture_root    path of the fixture instance
#
# Instance directories for the CLI runs (the plugins option):
#   cc_instance NAME [TOML_LINES]
#                      writes the instance DS_TEST_ROOT/NAME and prints its
#                      path: workstation.toml with the profile "workstation"
#                      (fresh mode), nix.systems ["x86_64-linux"] and
#                      [components.claude-code] enable = true followed by
#                      TOML_LINES; versions.lock.json = the minimal instance
#                      lock with the seed's versions_lock merged in; an empty
#                      skills lock; home/AGENTS.md; home.nix without framework
#                      skills
#   cc_expr DIR        the Nix expression of the instance in DIR
#   cc_lock_set DIR PATH JSON
#                      sets the dotted PATH of DIR/versions.lock.json
#   cc_mirror DIR      writes the mirrors of DIR (.dotsteward/)
#   cc_cli DIR ARG...  the framework CLI of the checkout under test with
#                      --instance DIR (standard input empty)
#   cc_hermetic_path   drops every PATH directory that holds a claude or
#                      local-maintained-files command of the host, then puts
#                      DS_TEST_ROOT/tools first: a stand-in for the
#                      local-maintained-files alias core requires
#   cc_home_state      a listing of HOME (paths, types, modes and file
#                      digests) for no-change comparisons

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

cc_component_dir=$DS_REPO_ROOT/modules/components/claude-code
cc_seed=$cc_component_dir/seed.json
cc_fixtures=$DS_REPO_ROOT/tests/nix/components/claude-code/fixtures
cc_fixture_root=$cc_fixtures/instance

_cc_scope() {
  printf 'let
    ccRoot = /. + "%s";
    ccCase = name: /. + "%s/cases/${name}.toml";
    cc = args: instance (args // { root = ccRoot; });
    ccHome = i: system: homeOf i system "workstation";
    ccComponent = i: system: (ccHome i system).dotsteward.components.claude-code;
    ccManifest = i: system: i.dotstewardManifest.${system};
    ccEntry = i: system: lib.findFirst (c: c.name == "claude-code") null (ccManifest i system).components;
  in ' "$cc_fixture_root" "$cc_fixtures"
}

cc_json() {
  inst_json "$(_cc_scope)($1)"
}

assert_cc_eq() {
  (($# >= 2)) || ds_fail "assert_cc_eq: usage: assert_cc_eq EXPECTED_JSON EXPR [MESSAGE]"
  assert_inst_eq "$1" "$(_cc_scope)($2)" "${3:-$2}"
}

assert_cc_fails() {
  (($# >= 2)) || ds_fail "assert_cc_fails: usage: assert_cc_fails EXPR NEEDLE..."
  local expr=$1
  shift
  assert_inst_fails "$(_cc_scope)($expr)" "$@"
}

_cc_minimal=$DS_REPO_ROOT/tests/fixtures/instances/minimal

cc_instance() {
  (($# >= 1 && $# <= 2)) || ds_fail "cc_instance: usage: cc_instance NAME [TOML_LINES]"
  local dir=$DS_TEST_ROOT/$1 extra=${2:-}
  [[ -f $cc_seed ]] || ds_fail "missing $cc_seed"
  rm -rf -- "$dir"
  mkdir -p "$dir/agent/skills"
  cp -R "$_cc_minimal/home" "$_cc_minimal/local-maintained-files" "$dir/"
  chmod -R u+w "$dir"
  cat >"$dir/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "git@github.com:alice/workstation.git"

[nix]
systems = ["x86_64-linux"]
state_version = "25.11"

[profiles]
names = ["workstation"]

[components.claude-code]
enable = true
$extra
EOF
  jq --indent 2 -s '.[0] * .[1].versions_lock' "$_cc_minimal/versions.lock.json" "$cc_seed" \
    >"$dir/versions.lock.json"
  jq -n '{ schema_version: "1.0", expected_skill_count: 0, skills: [] }' >"$dir/agent/skills.lock.json"
  printf '{ ... }:\n{\n  dotsteward.skills.framework = [ ];\n}\n' >"$dir/home.nix"
  printf '%s\n' "$dir"
}

cc_expr() {
  (($# == 1)) || ds_fail "cc_expr: usage: cc_expr DIR"
  printf 'instance { root = /. + "%s"; }' "$1"
}

cc_lock_set() {
  (($# == 3)) || ds_fail "cc_lock_set: usage: cc_lock_set DIR PATH JSON"
  local tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 --arg path "$2" --argjson value "$3" 'setpath($path | split("."); $value)' \
    "$1/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$1/versions.lock.json"
}

cc_mirror() {
  (($# == 1)) || ds_fail "cc_mirror: usage: cc_mirror DIR"
  write_mirrors "$(cc_expr "$1")" "$1"
}

cc_cli() {
  (($# >= 2)) || ds_fail "cc_cli: usage: cc_cli DIR ARG..."
  local dir=$1
  shift
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$dir" "$@" </dev/null
}

cc_hermetic_path() {
  local entry kept=() tools=$DS_TEST_ROOT/tools
  local IFS=:
  for entry in $PATH; do
    [[ -n $entry && ! -e $entry/claude && ! -e $entry/local-maintained-files ]] || continue
    kept+=("$entry")
  done
  mkdir -p "$tools"
  printf '#!%s\nexit 0\n' "$BASH" >"$tools/local-maintained-files"
  chmod 0755 "$tools/local-maintained-files"
  PATH="$tools:${kept[*]}"
  export PATH
  hash -r
}

cc_home_state() {
  (cd "$HOME" && find . -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort -k 2)
}
