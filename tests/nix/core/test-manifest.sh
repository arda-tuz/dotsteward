# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core manifest: the contract values of the enabled components and
# core, identical in every profile (D20), shipped in the generation as
# share/dotsteward/manifest.json.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

modules='componentModules ++ [ {
  dotsteward.skills.frameworkRoot = fixtures + "/framework/skills";
  dotsteward.skills.homeManaged.example-skill = fixtures + "/instance/skills/example-skill";
} ]'

manifest() {
  core_json "(homeOf { config = \"workstation\"; $1 modules = $modules; }).dotsteward.manifest"
}

actual=$(manifest '')

# Everything but store paths, the configuration and the framework facts.
without_paths='del(.config, .framework, .checks.e2e[].script, .checks.agents[].script, .hooks.pre_activate[].script, .agent_rules.source)'
json_check "$actual" "$without_paths" "$(jq -cS . "$nix_core_fixtures/manifest.workstation.json")"

# The resolved configuration with its defaults, and the framework version.
assert_eq "$(core_json 'loadToml "workstation"' | jq -cS .)" "$(jq -cS .config <<<"$actual")" "resolved configuration"
json_check "$actual" .framework "{\"version\":\"$(<"$DS_REPO_ROOT/VERSION")\"}"

# Hook scripts are the store copies of their sources; the agent rules
# source is the store file the targets link to.
hook=$(core_json '"${fixtures + "/instance/hook.sh"}"')
for filter in '.checks.e2e[0].script' '.checks.agents[0].script' '.hooks.pre_activate[0].script'; do
  assert_eq "$hook" "$(jq "$filter" <<<"$actual")" "$filter"
done
assert_eq "$(core_json '(homeOf { config = "workstation"; modules = componentModules; }).home.file.".example-term/RULES.md".source')" \
  "$(jq .agent_rules.source <<<"$actual")" "agent rules source: the file the targets link to"

# D20: the manifest does not depend on the profile.
assert_eq "$actual" "$(manifest 'profile = "fresh";')" "same manifest in every profile"

# The platform selects per-platform settings paths.
darwin=$(manifest 'system = "aarch64-darwin"; homeDirectory = "/Users/alice";')
json_check "$darwin" '[.system, .platform, .settings_targets.beta.path]' \
  '["aarch64-darwin","darwin","~/Library/Application Support/example-term/beta.toml"]'

# Without the alias, the core commands lose local-maintained-files.
assert_core_eq '[{"component":"core","command":"jq"}]' \
  '(homeOf { modules = [ { dotsteward.cli.alias = false; } ]; }).dotsteward.manifest.checks.commands'

# The minimal instance: no components, core contributions only.
minimal=$(core_json '(homeOf { }).dotsteward.manifest')
json_check "$minimal" '[.components, .backup_paths, .managed_links, .login_shell, .agent_rules.targets, .skills.hm_root]' \
  '[[],["~/.config/nix/nix.conf","~/.agents/skills"],["~/.config/nix/nix.conf"],null,[],".agents/skills"]'

# manifestExtra (set by mkInstance) is merged at the top level.
assert_core_eq '{"zsh":"5.9"}' \
  '(homeOf { modules = [ { dotsteward.manifestExtra.pinned_versions.zsh = "5.9"; } ]; }).dotsteward.manifest.pinned_versions'
assert_core_fails '(homeOf { modules = [ { dotsteward.manifest = { }; } ]; }).dotsteward.manifest' \
  "dotsteward.manifest" "read-only"

# The generation ships the manifest as share/dotsteward/manifest.json.
actual=$(core_json "let
  c = homeOf { config = \"workstation\"; modules = $modules; };
  package = lib.findFirst (p: lib.getName p == \"dotsteward-manifest\") null c.home.packages;
in {
  inherit (package) destination;
  same = package == c.dotsteward.manifestPackage;
  json = builtins.fromJSON (builtins.unsafeDiscardStringContext package.text) == c.dotsteward.manifest;
}")
json_check "$actual" . '{"destination":"/share/dotsteward/manifest.json","json":true,"same":true}'
