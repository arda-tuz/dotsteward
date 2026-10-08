# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A manifest section the E2E checks read with the wrong shape is
# a refusal, never "nothing to check": the run and --list exit 1 before any
# check runs, with one setup finding (code error) whose path is the manifest
# file. The same missing command in a well-formed entry fails with
# missing-command, so a malformed section cannot turn a failure into a pass.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

add_component example-app external '{"command": null, "versionArgv": null, "minimum": null}'
hook_log_script shape-check | add_e2e_hook example-app shape-check early
publish_instance
original=$DS_TEST_ROOT/manifest.original.json
cp -- "$agents_manifest" "$original"

# The well-formed instance passes, and a well-formed missing command fails.
assert_exit 0 run_e2e --skip-repo-checks --json
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$DS_STDOUT")"
manifest_edit '.checks.commands = [{component: "example-app", command: "example-missing-cmd"}]'
assert_exit 1 run_e2e --skip-repo-checks --json
assert_eq '[["core:commands","missing-command","example-missing-cmd"]]' "$(findings)"

malformed=(
  '.checks.commands = {}'
  '.checks.commands = {"x": "example-missing-cmd"}'
  '.checks.commands = ["example-missing-cmd"]'
  '.checks.commands = [{component: "example-app", command: 5}]'
  '.checks.e2e = {}'
  '.checks.e2e = {"a": 1}'
  '.checks.e2e = [1]'
  '.checks.e2e[0].profiles = "workstation"'
  '.checks.e2e[0].script = 5'
  '.checks = []'
  '.files = "x"'
  '.files = {"example": "x"}'
  '.files = {"example": {source: "<instance>/a", target: 5}}'
  '.managed_links = {}'
  '.managed_links = [5]'
  '.agent_rules = []'
  '.agent_rules.targets = {}'
  '.agent_rules = {source: "<instance>/AGENTS.md", targets: [{component: "example-app", path: 5}]}'
  '.agent_rules.source = 5'
  '.skills.framework = "dotsteward-example"'
  '.login_shell = 5'
  '.components = 5'
  '.components = [5]'
  '.components[0].name = 5'
  '.components[0].modes = []'
  '.components[0].platforms = "linux"'
)
for filter in "${malformed[@]}"; do
  cp -- "$original" "$agents_manifest"
  manifest_edit "$filter"
  : >"$e2e_hook_log"
  assert_exit 1 run_e2e --skip-repo-checks --json
  assert_eq "$(jq -cn --arg path "$agents_manifest" '[["setup", "error", $path]]')" "$(findings)" \
    "$filter: one setup finding"
  assert_json - '.result == "failed"' <<<"$DS_STDOUT"
  assert_contains "$(jq -r '.findings[0].message' <<<"$DS_STDOUT")" "invalid manifest $agents_manifest"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid manifest $agents_manifest"
  assert_eq "" "$(<"$e2e_hook_log")" "$filter: no hook runs"
  assert_exit 1 run_e2e --list
  assert_contains "$DS_STDERR" "invalid manifest $agents_manifest"
  assert_exit 1 run_e2e --list --json
  assert_contains "$DS_STDERR" "invalid manifest $agents_manifest"
done

# Optional sections may be absent or null: nothing to check is not an error.
cp -- "$original" "$agents_manifest"
manifest_edit 'del(.checks.commands, .files, .managed_links, .login_shell) | .agent_rules = null
  | .checks.e2e = null | .skills.framework = null'
assert_exit 0 run_e2e --skip-repo-checks --json
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$DS_STDOUT")"
assert_exit 0 run_e2e --list
assert_eq $'core:agents\ncore:repo-clean\ncore:repo-origin\ncore:repo-remote\ncore:repo-skill-count\ncore:framework-skills' \
  "$DS_STDOUT"
