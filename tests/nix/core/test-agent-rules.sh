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
    source = c.dotsteward.agentRules.storePath;
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
# The store copy has the name Home Manager gives a path source (hm_ and the
# file name), so the link target equals that of a home.nix linking the file
# directly.
json_check "$actual" '.source | test("^/.*/store/[a-z0-9]{32}-hm_AGENTS\\.md$")' 'true'
assert_eq "$(core_json 'builtins.path { path = fixtures + "/instance/agent/AGENTS.md"; name = "hm_AGENTS.md"; }')" \
  "$(jq .source <<<"$actual")" "store copy of the source"

# mkInstance passes root as a store path string with context ("${self}").
# The links still point at a store file of their own, not into the instance
# source: the same file as with a path root, so the generation does not
# depend on the rest of the instance tree. The manifest names that file, so
# the E2E byte comparison reads what the links point at.
string_root='root = "${fixtures + "/instance"}";'
string_rules() {
  nix_core_read_write=1 core_json "let c = homeOf ({ config = \"workstation\"; modules = componentModules; } // { $1 }); in {
    targets = lib.mapAttrs (_: f: \"\${f.source}\") (lib.filterAttrs (n: _: lib.hasPrefix \".example-\" n) c.home.file);
    manifest = c.dotsteward.manifest.agent_rules.source;
  }"
}
from_path=$(string_rules '')
from_string=$(string_rules "$string_root")
json_check "$from_string" '[.targets[]] | unique | length' '1'
json_check "$from_string" '.targets[".example-term/RULES.md"] | test("^/.*/store/[a-z0-9]{32}-hm_AGENTS\\.md$")' 'true'
json_check "$from_string" '.manifest == .targets[".example-term/RULES.md"]' 'true'
assert_eq "$(jq -cS . <<<"$from_path")" "$(jq -cS . <<<"$from_string")" "the same links for a path root and a string root"
assert_eq "$(nix_core_read_write=1 core_json '(mkHome { config = "workstation"; modules = componentModules; }).config.home-files.drvPath')" \
  "$(nix_core_read_write=1 core_json "(mkHome { config = \"workstation\"; modules = componentModules; $string_root }).config.home-files.drvPath")" \
  "the same home-files for a path root and a string root"

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
nix_core_read_write=1 assert_core_fails '(homeOf { config = "workstation"; root = "${fixtures + "/instance"}/missing"; modules = componentModules; }).home.username' \
  "- dotsteward: agent rules source " "/missing/agent/AGENTS.md does not exist"

# A target must be home relative.
assert_core_fails '(homeOf { config = "workstation"; modules = componentModules ++ [ { dotsteward.components.example-app.agentRulesTargets = [ { path = "/etc/AGENTS.md"; } ]; } ]; }).home.file' \
  "agentRulesTargets"
