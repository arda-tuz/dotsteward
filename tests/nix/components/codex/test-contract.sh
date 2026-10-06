# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and jq programs in single quotes
# The codex catalog component (SPEC 3.4, 3.5): its contract values as
# lib.mkInstance evaluates them for an instance that enables it, on both
# systems: default and supported methods, the official-binary and external
# install blocks, agent rules, rollback, settings target, backups, skill
# layout, pins declarations, docs and the plugins option.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

component=$DS_REPO_ROOT/modules/components/codex

# manifests INSTANCE_DIR [darwin]: { linux } manifests, plus darwin when
# asked (the instance must list aarch64-darwin), store contexts discarded.
manifests() {
  local systems='[ "x86_64-linux" ]'
  [[ ${2:-} != darwin ]] || systems='[ "x86_64-linux" "aarch64-darwin" ]'
  inst_json "let
    inst = $(codex_expr "$1");
    of = system: storeless (homeOf inst system \"workstation\").dotsteward.manifest;
  in lib.genAttrs (map dsLib.platform.platformOf $systems) (platform:
    of (if platform == \"linux\" then \"x86_64-linux\" else \"aarch64-darwin\"))"
}

# codex_entry MANIFEST_JSON: the manifest's codex component entry.
codex_entry() {
  jq -c '.components[] | select(.name == "codex")' <<<"$1"
}

# --- Defaults on both systems ---------------------------------------------------

both=$(codex_instance both '["x86_64-linux", "aarch64-darwin"]')
result=$(manifests "$both" darwin)
linux=$(jq -c .linux <<<"$result")
darwin=$(jq -c .darwin <<<"$result")

for platform in linux darwin; do
  manifest=$(jq -c ".$platform" <<<"$result")
  entry=$(codex_entry "$manifest")
  json_check "$entry" '[.source, .method, .profiles, .platforms, .options, .modes]' \
    '["catalog","official-binary",null,["linux","darwin"],{},{"workstation":"fresh"}]'
  json_check "$entry" '.supported_methods' \
    '{"darwin":["official-binary","external"],"linux":["official-binary","external"]}'
done

# The official-binary block: the release asset of each platform, its archive
# member, the user-level destination, the version the binary prints, the
# at-least policy (a newer binary is kept) and sha256 verification from the
# lock (the sigstore decision of SPEC 14, recorded in README.md).
json_check "$(codex_entry "$linux")" '.install' "$(jq -cS . <<'EOF'
{
  "pin": "agent_tools.codex.linux",
  "asset": {
    "linux": "codex-x86_64-unknown-linux-musl.tar.gz",
    "darwin": "codex-aarch64-apple-darwin.tar.gz"
  },
  "member": "codex-x86_64-unknown-linux-musl",
  "dest": "~/.local/bin/codex",
  "versionArgv": ["--version"],
  "versionRegex": "^codex-cli ([0-9]+([.][0-9]+)+(-[0-9A-Za-z.]+)?)",
  "policy": "at-least",
  "verify": "sha256"
}
EOF
)"
json_check "$(codex_entry "$darwin")" '[.install.pin, .install.member, .install.dest, .install.asset.darwin]' \
  '["agent_tools.codex.darwin","codex-aarch64-apple-darwin","~/.local/bin/codex","codex-aarch64-apple-darwin.tar.gz"]'

for platform in linux darwin; do
  manifest=$(jq -c ".$platform" <<<"$result")
  # Agent rules: ~/.codex/AGENTS.md, overwriting an existing file.
  json_check "$manifest" '[.agent_rules.targets[] | select(.component == "codex")]' \
    '[{"component":"codex","force":true,"path":".codex/AGENTS.md"}]'
  # The link is managed: rollback removes it and restores the backup as a
  # regular 0664 file.
  json_check "$manifest" '[.managed_links[] | select(startswith("~/.codex/"))]' '["~/.codex/AGENTS.md"]'
  json_check "$manifest" '[.force_linked_restore[] | select(.component == "codex")]' \
    '[{"component":"codex","mode":"0664","path":"~/.codex/AGENTS.md"}]'
  # Settings target "codex": the TOML configuration, created 0600 when a
  # buffer entry applies, backed up, no reload.
  json_check "$manifest" '.settings_targets.codex' \
    '{"backup":true,"component":"codex","create_if_missing":true,"create_mode":"0600","format":"toml","path":"~/.codex/config.toml","reload":null}'
  json_check "$manifest" '[.backup_paths[] | select(startswith("~/.codex/"))]' \
    '["~/.codex/AGENTS.md","~/.codex/config.toml"]'
  # Skill layout: the legacy skill root, whose .system subtree belongs to
  # Codex and is never touched.
  json_check "$manifest" '.skill_layout' \
    '{"excluded_subtrees":[".system"],"legacy_roots":["~/.codex/skills"],"link_roots":{}}'
  # Nothing else: no hooks without plugins, no probes, checks, snapshots,
  # adoption paths, detectors or resolved versions.
  json_check "$manifest" '[.hooks[][] | select(.component == "codex")]' '[]'
  json_check "$manifest" '[.probes[], .checks[][], .snapshots[] | select(.component == "codex")]' '[]'
  json_check "$manifest" '[.adopt_paths, .preflight_detectors, .pins.resolved_versions, .pins.flake_inputs]' \
    '[[],{},{},[]]'
done

# Pins: one download pin and one latest row per platform of nix.systems,
# read from agent_tools.codex.<platform> (the seed provides both).
expected_rules=$(jq -cS . <<'EOF'
[
  {
    "component": "codex",
    "kind": "download-pin",
    "name": "release-linux",
    "at": "agent_tools.codex.linux",
    "url_contains": "https://github.com/openai/codex/releases/download/rust-v{.version}/codex-x86_64-unknown-linux-musl.tar.gz"
  },
  {
    "component": "codex",
    "kind": "download-pin",
    "name": "release-darwin",
    "at": "agent_tools.codex.darwin",
    "url_contains": "https://github.com/openai/codex/releases/download/rust-v{.version}/codex-aarch64-apple-darwin.tar.gz"
  }
]
EOF
)
expected_latest=$(jq -cS . <<'EOF'
[
  {
    "component": "codex",
    "id": "agent_tools.codex.linux",
    "adapter": "github-release",
    "repo": "openai/codex",
    "tag_prefix": "rust-v",
    "at": "agent_tools.codex.linux",
    "asset": "codex-x86_64-unknown-linux-musl.tar.gz"
  },
  {
    "component": "codex",
    "id": "agent_tools.codex.darwin",
    "adapter": "github-release",
    "repo": "openai/codex",
    "tag_prefix": "rust-v",
    "at": "agent_tools.codex.darwin",
    "asset": "codex-aarch64-apple-darwin.tar.gz"
  }
]
EOF
)
for platform in linux darwin; do
  manifest=$(jq -c ".$platform" <<<"$result")
  json_check "$manifest" '[.pins.rules[] | select(.component == "codex")]' "$expected_rules"
  json_check "$manifest" '[.pins.latest[] | select(.component == "codex")]' "$expected_latest"
done

# The agent rules link (to the store copy of the shared source every target
# links), the docs and the module values behind the manifest.
values=$(inst_json "let c = homeOf ($(codex_expr "$both")) \"x86_64-linux\" \"workstation\"; in {
  force = c.home.file.\".codex/AGENTS.md\".force;
  source = toString c.home.file.\".codex/AGENTS.md\".source == c.dotsteward.agentRules.storePath;
  docs = toString c.dotsteward.components.codex.docs;
}")
json_check "$values" '[.force, .source]' '[true,true]'
assert_eq "$component/README.md" "$(jq -r .docs <<<"$values")" "docs"

# --- One system: one pin -----------------------------------------------------------

single=$(codex_instance single)
manifest=$(manifests "$single" | jq -c .linux)
json_check "$manifest" '[.pins.rules[] | select(.component == "codex") | .at]' '["agent_tools.codex.linux"]'
json_check "$manifest" '[.pins.latest[] | select(.component == "codex") | .id]' '["agent_tools.codex.linux"]'

# --- external: nothing installed, codex expected on PATH, no pins -------------------

external=$(codex_instance external '["x86_64-linux", "aarch64-darwin"]' 'method = "external"')
result=$(manifests "$external" darwin)
for platform in linux darwin; do
  manifest=$(jq -c ".$platform" <<<"$result")
  json_check "$(codex_entry "$manifest")" '[.method, .install]' \
    '["external",{"command":"codex","minimum":null,"versionArgv":["--version"]}]'
  json_check "$manifest" '[.pins.rules[], .pins.latest[] | select(.component == "codex")]' '[]'
  json_check "$manifest" '.settings_targets.codex.path' '"~/.codex/config.toml"'
done
by_platform=$(codex_instance by-platform '["x86_64-linux", "aarch64-darwin"]' \
  'method_by_platform = { darwin = "external" }')
result=$(manifests "$by_platform" darwin)
json_check "$result" '[.linux, .darwin | .components[] | select(.name == "codex") | .method]' \
  '["official-binary","external"]'
# Pins are declared for the platforms whose method is official-binary, in
# the manifest of every system (one lock serves them all).
for platform in linux darwin; do
  json_check "$result" "[.$platform.pins.rules[], .$platform.pins.latest[] | select(.component == \"codex\") | .at]" \
    '["agent_tools.codex.linux","agent_tools.codex.linux"]'
done

# --- The plugins option ---------------------------------------------------------------

plugins=$(codex_instance plugins '["x86_64-linux"]' 'options = { plugins = [
  { spec = "example-plugin@example-market", minimumAt = "agent_tools.example-plugin.minimum_version", requiredSkillDirectories = ["alpha", "beta"] },
  { spec = "other-plugin@example-market" },
] }')
codex_lock_set "$plugins" agent_tools.example-plugin '{"minimum_version": "1.2.0"}'
manifest=$(manifests "$plugins" | jq -c .linux)
json_check "$(codex_entry "$manifest")" '.options' "$(jq -cS . <<'EOF'
{
  "plugins": [
    {
      "spec": "example-plugin@example-market",
      "minimumAt": "agent_tools.example-plugin.minimum_version",
      "requiredSkillDirectories": ["alpha", "beta"]
    },
    { "spec": "other-plugin@example-market" }
  ]
}
EOF
)"
# One agentsPost hook, the framework's plugins.sh, read from the framework
# source in place (the mirror names it <dotsteward>/...).
json_check "$manifest" '[.hooks.agents_post[] | select(.component == "codex")]' \
  "[{\"component\":\"codex\",\"name\":\"plugins\",\"phase\":\"main\",\"profiles\":null,\"script\":\"$component/plugins.sh\"}]"
json_check "$manifest" '[.hooks | to_entries[] | select(.key != "agents_post") | .value[] | select(.component == "codex")]' '[]'
[[ -x $component/plugins.sh ]] || ds_fail "plugins.sh is not executable"
codex_mirror "$plugins"
assert_json "$plugins/.dotsteward/manifest.x86_64-linux.json" \
  '[.hooks.agents_post[] | select(.component == "codex") | .script] == ["<dotsteward>/modules/components/codex/plugins.sh"]'

# An empty list is no hook.
empty=$(codex_instance empty '["x86_64-linux"]' 'options = { plugins = [] }')
manifest=$(manifests "$empty" | jq -c .linux)
json_check "$manifest" '[.hooks.agents_post[] | select(.component == "codex")]' '[]'

# Invalid options fail the evaluation with every problem at once.
username() {
  printf '(homeOf (%s) "x86_64-linux" "workstation").home.username' "$(codex_expr "$1")"
}
invalid=$(codex_instance invalid '["x86_64-linux"]' 'options = { colour = true, plugins = [
  { spec = "no-market" },
  { spec = "alpha@market", minimumAt = "agent_tools.missing.minimum_version" },
  { spec = "beta@market", minimumAt = "agent_tools", requiredSkillDirectories = ["../escape", ""], extra = 1 },
  { spec = "alpha@market" },
] }')
assert_inst_fails "$(username "$invalid")" \
  "Failed assertions:" \
  "- dotsteward: component codex: unknown option colour (known: plugins)" \
  '- dotsteward: component codex: options.plugins[0].spec must look like NAME@MARKETPLACE, got "no-market"' \
  "- dotsteward: component codex: options.plugins[1].minimumAt: versions.lock.json lacks agent_tools.missing.minimum_version" \
  "- dotsteward: component codex: options.plugins[2].minimumAt: versions.lock.json agent_tools is not a version (a string, or an entry with minimum_version or version)" \
  '- dotsteward: component codex: options.plugins[2].requiredSkillDirectories[0] must be a plain directory name, got "../escape"' \
  '- dotsteward: component codex: options.plugins[2].requiredSkillDirectories[1] must be a plain directory name, got ""' \
  "- dotsteward: component codex: options.plugins[2] has unknown key extra (known: spec, minimumAt, requiredSkillDirectories)" \
  "- dotsteward: component codex: options.plugins[3].spec alpha@market is listed twice"

invalid=$(codex_instance invalid-types '["x86_64-linux"]' 'options = { plugins = [
  "example-plugin@example-market",
  { spec = 1 },
  { spec = "gamma@market", minimumAt = 3, requiredSkillDirectories = "alpha" },
] }')
assert_inst_fails "$(username "$invalid")" \
  "- dotsteward: component codex: options.plugins[0] must be a table" \
  "- dotsteward: component codex: options.plugins[1].spec must look like NAME@MARKETPLACE, got 1" \
  "- dotsteward: component codex: options.plugins[2].minimumAt must be a versions.lock.json path, got 3" \
  "- dotsteward: component codex: options.plugins[2].requiredSkillDirectories must be a list of directory names"

invalid=$(codex_instance invalid-list '["x86_64-linux"]' 'options = { plugins = "example-plugin@example-market" }')
assert_inst_fails "$(username "$invalid")" \
  "- dotsteward: component codex: options.plugins must be a list of tables"
