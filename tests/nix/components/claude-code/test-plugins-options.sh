# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The claude-code plugins option as lib.mkInstance evaluates it: the options
# in the manifest entry, the agentsPost hook plugins.sh (only with a
# non-empty list, read from the framework source in place), one git-compare
# review row per plugin that names a tracking entry (trackAt) with every
# method, and the validation that fails the evaluation with every problem
# listed.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

component=$DS_REPO_ROOT/modules/components/claude-code

# manifest INSTANCE_DIR: the x86_64-linux manifest, store contexts discarded.
manifest() {
  inst_json "storeless (homeOf ($(cc_expr "$1")) \"x86_64-linux\" \"workstation\").dotsteward.manifest"
}

# cc_entry MANIFEST_JSON: the manifest's claude-code component entry.
cc_entry() {
  jq -c '.components[] | select(.name == "claude-code")' <<<"$1"
}

revision=0123456789abcdef0123456789abcdef01234567

# --- A plugin list with every key -------------------------------------------------------

plugins=$(cc_instance plugins 'method = "external"
options = { plugins = [
  { spec = "example-plugin@example-market", marketplace = "example-org/example-marketplace", minimumAt = "agent_tools.example-plugin.minimum_version", requiredFiles = [".claude-plugin/plugin.json", "skills/alpha/SKILL.md"], trackAt = "agent_tools.example-plugin", watched = ["plugins/example-plugin/.+"] },
  { spec = "other-plugin@example-market" },
] }')
cc_lock_set "$plugins" agent_tools.example-plugin \
  "{\"minimum_version\": \"1.2.0\", \"source\": \"https://github.com/example-org/example-marketplace\", \"observed_marketplace_revision\": \"$revision\"}"
result=$(manifest "$plugins")
json_check "$(cc_entry "$result")" '.options' "$(jq -cS . <<'EOF'
{
  "plugins": [
    {
      "spec": "example-plugin@example-market",
      "marketplace": "example-org/example-marketplace",
      "minimumAt": "agent_tools.example-plugin.minimum_version",
      "requiredFiles": [".claude-plugin/plugin.json", "skills/alpha/SKILL.md"],
      "trackAt": "agent_tools.example-plugin",
      "watched": ["plugins/example-plugin/.+"]
    },
    { "spec": "other-plugin@example-market" }
  ]
}
EOF
)"

# One agentsPost hook, the framework's plugins.sh, read from the framework
# source in place (the mirror names it <dotsteward>/...).
json_check "$result" '[.hooks.agents_post[] | select(.component == "claude-code")]' \
  "[{\"component\":\"claude-code\",\"name\":\"plugins\",\"phase\":\"main\",\"profiles\":null,\"script\":\"$component/plugins.sh\"}]"
json_check "$result" '[.hooks | to_entries[] | select(.key != "agents_post") | .value[] | select(.component == "claude-code")]' '[]'
[[ -x $component/plugins.sh ]] || ds_fail "plugins.sh is not executable"
cc_mirror "$plugins"
assert_json "$plugins/.dotsteward/manifest.x86_64-linux.json" \
  '[.hooks.agents_post[] | select(.component == "claude-code") | .script] == ["<dotsteward>/modules/components/claude-code/plugins.sh"]'

# The tracked plugin is a git-compare review row of its marketplace, also
# with the external method (which declares no install pins); the other
# plugin is not tracked.
json_check "$result" '[.pins.rules[] | select(.component == "claude-code")]' '[]'
json_check "$result" '[.pins.latest[] | select(.component == "claude-code")]' "$(jq -cS . <<'EOF'
[
  {
    "component": "claude-code",
    "id": "agent_tools.example-plugin",
    "adapter": "git-compare",
    "at": "agent_tools.example-plugin",
    "repo_at": ".source",
    "revision_at": ".observed_marketplace_revision",
    "watched": ["plugins/example-plugin/.+"]
  }
]
EOF
)"

# With the default method the row follows the release pins.
tracked=$(cc_instance tracked 'options = { plugins = [
  { spec = "example-plugin@example-market", trackAt = "agent_tools.example-plugin", watched = ["plugins/example-plugin/.+", "README[.]md"] },
] }')
cc_lock_set "$tracked" agent_tools.example-plugin \
  "{\"source\": \"https://github.com/example-org/example-marketplace\", \"observed_marketplace_revision\": \"$revision\"}"
json_check "$(manifest "$tracked")" '[.pins.latest[] | select(.component == "claude-code") | [.id, .adapter]]' \
  '[["agent_tools.claude-code.linux-x64","official-manifest"],["agent_tools.example-plugin","git-compare"]]'

# `dotsteward pins check` accepts the declarations.
cc_mirror "$tracked"
assert_exit 0 cc_cli "$tracked" pins check

# --- No plugins: no hook, no rows ---------------------------------------------------------

for options in '' 'options = { plugins = [] }'; do
  empty=$(cc_instance empty "method = \"external\"
$options")
  result=$(manifest "$empty")
  json_check "$result" '[.hooks[][] | select(.component == "claude-code")]' '[]'
  json_check "$result" '[.pins.latest[] | select(.component == "claude-code")]' '[]'
done

# --- Invalid options fail the evaluation with every problem at once -----------------------

username() {
  printf '(homeOf (%s) "x86_64-linux" "workstation").home.username' "$(cc_expr "$1")"
}

invalid=$(cc_instance invalid 'options = { colour = true, plugins = [
  { spec = "no-market" },
  { spec = "alpha@market", minimumAt = "agent_tools.missing.minimum_version", marketplace = "not a repository" },
  { spec = "beta@market", minimumAt = "agent_tools", requiredFiles = ["../escape", "/abs/path", ""], extra = 1 },
  { spec = "alpha@market" },
  { spec = "gamma@market", trackAt = "agent_tools.missing", watched = ["plugins/.+"] },
  { spec = "delta@market", trackAt = "agent_tools.half" },
  { spec = "epsilon@market", watched = ["plugins/.+"] },
] }')
cc_lock_set "$invalid" agent_tools.half '{"source": "https://example.com/not-github", "observed_marketplace_revision": "abc"}'
assert_inst_fails "$(username "$invalid")" \
  "Failed assertions:" \
  "- dotsteward: component claude-code: unknown option colour (known: plugins)" \
  '- dotsteward: component claude-code: options.plugins[0].spec must look like NAME@MARKETPLACE, got "no-market"' \
  "- dotsteward: component claude-code: options.plugins[1].minimumAt: versions.lock.json lacks agent_tools.missing.minimum_version" \
  '- dotsteward: component claude-code: options.plugins[1].marketplace must be a GitHub repository OWNER/REPO, got "not a repository"' \
  "- dotsteward: component claude-code: options.plugins[2].minimumAt: versions.lock.json agent_tools is not a version (a string, or an entry with minimum_version or version)" \
  '- dotsteward: component claude-code: options.plugins[2].requiredFiles[0] must be a relative path inside the plugin, got "../escape"' \
  '- dotsteward: component claude-code: options.plugins[2].requiredFiles[1] must be a relative path inside the plugin, got "/abs/path"' \
  '- dotsteward: component claude-code: options.plugins[2].requiredFiles[2] must be a relative path inside the plugin, got ""' \
  "- dotsteward: component claude-code: options.plugins[2] has unknown key extra (known: spec, marketplace, minimumAt, requiredFiles, trackAt, watched)" \
  "- dotsteward: component claude-code: options.plugins[3].spec alpha@market is listed twice" \
  "- dotsteward: component claude-code: options.plugins[4].trackAt: versions.lock.json lacks agent_tools.missing" \
  "- dotsteward: component claude-code: options.plugins[5].trackAt: versions.lock.json agent_tools.half.source must be a GitHub repository URL https://github.com/OWNER/REPO" \
  "- dotsteward: component claude-code: options.plugins[5].trackAt: versions.lock.json agent_tools.half.observed_marketplace_revision must be a 40-digit commit" \
  "- dotsteward: component claude-code: options.plugins[5].trackAt needs watched, a non-empty list of path patterns" \
  "- dotsteward: component claude-code: options.plugins[6].watched needs trackAt"

invalid=$(cc_instance invalid-types 'options = { plugins = [
  "example-plugin@example-market",
  { spec = 1 },
  { spec = "gamma@market", minimumAt = 3, requiredFiles = "alpha", trackAt = 4, watched = "plugins/.+" },
] }')
assert_inst_fails "$(username "$invalid")" \
  "- dotsteward: component claude-code: options.plugins[0] must be a table" \
  "- dotsteward: component claude-code: options.plugins[1].spec must look like NAME@MARKETPLACE, got 1" \
  "- dotsteward: component claude-code: options.plugins[2].minimumAt must be a versions.lock.json path, got 3" \
  "- dotsteward: component claude-code: options.plugins[2].requiredFiles must be a list of relative paths" \
  "- dotsteward: component claude-code: options.plugins[2].trackAt must be a versions.lock.json path, got 4" \
  "- dotsteward: component claude-code: options.plugins[2].watched must be a list of path patterns"

invalid=$(cc_instance invalid-list 'options = { plugins = "example-plugin@example-market" }')
assert_inst_fails "$(username "$invalid")" \
  "- dotsteward: component claude-code: options.plugins must be a list of tables"
