# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core agent rules: one source file linked to every target of the
# active components.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# rules ARGS: the agent rules home.file entries of a configuration.
rules() {
  core_json "let c = homeOf ($1); files = lib.filterAttrs (n: _: lib.hasPrefix \".example-\" n) c.home.file; in {
    targets = lib.mapAttrs (_: f: { inherit (f) force; source = \"\${f.source}\"; }) files;
    source = if c.dotsteward.agentRules.source == null then null else \"\${c.dotsteward.agentRules.source}\";
  }"
}

# The default source is root + "/" + agent_rules.source.
assert_core_eq 'true' '(homeOf { }).dotsteward.agentRules.source == fixtures + "/instance/home/AGENTS.md"'
assert_core_eq 'true' '(homeOf { config = "workstation"; }).dotsteward.agentRules.source == fixtures + "/instance/agent/AGENTS.md"'

# Every target of the active components links the same store file; force
# comes from the target.
actual=$(rules '{ config = "workstation"; modules = componentModules; }')
json_check "$actual" '.targets | keys' '[".example-app/AGENTS.md",".example-term/RULES.md"]'
json_check "$actual" '[.targets[".example-app/AGENTS.md"].force, .targets[".example-term/RULES.md"].force]' '[false,true]'
json_check "$actual" '[.targets[].source] | unique | length' '1'
json_check "$actual" '.targets[".example-term/RULES.md"].source == .source' 'true'
json_check "$actual" '.source | test("^/.*/store/[a-z0-9]{32}-AGENTS\\.md$")' 'true'
assert_eq "$(core_json '"${fixtures + "/instance/agent/AGENTS.md"}"')" "$(jq .source <<<"$actual")" "store copy of the source"

# A component outside the current profile contributes no target.
actual=$(rules '{ config = "workstation"; profile = "fresh"; modules = componentModules; }')
json_check "$actual" '.targets | keys' '[".example-app/AGENTS.md"]'

# No source: no agent rules files.
actual=$(rules '{ config = "workstation"; modules = componentModules ++ [ { dotsteward.agentRules.source = lib.mkForce null; } ]; }')
json_check "$actual" '[.targets, .source]' '[{},null]'

# A missing source fails an assertion when a target needs it, and is fine
# when nothing does.
assert_core_fails '(homeOf { config = "workstation"; root = fixtures + "/missing"; modules = componentModules; }).home.username' \
  "- dotsteward: agent rules source " "/missing/agent/AGENTS.md does not exist"
assert_core_eq '"alice"' '(homeOf { root = fixtures + "/missing"; }).home.username'

# A target must be home relative.
assert_core_fails '(homeOf { config = "workstation"; modules = componentModules ++ [ { dotsteward.components.example-app.agentRulesTargets = [ { path = "/etc/AGENTS.md"; } ]; } ]; }).home.file' \
  "agentRulesTargets"
