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
