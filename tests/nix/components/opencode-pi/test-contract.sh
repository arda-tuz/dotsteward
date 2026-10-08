# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The contract values of the opencode-pi catalog component: the
# OpenCode official binary (at-least policy, one release pin per platform),
# the external alternative, the Pi probes, the agents checks, the Pi agent
# rules target, the OpenCode settings target, the pin rules and the latest
# declarations of the platforms of nix.systems, on Linux and on darwin.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

linux='component { }'
darwin='component { system = "aarch64-darwin"; }'

# --- Method, platforms, install blocks ------------------------------------------

for system in "$linux" "$darwin"; do
  assert_op_eq '"official-binary"' "($system).method" "default method"
  assert_op_eq '["linux","darwin"]' "($system).platforms" "platforms"
  assert_op_eq '{"linux":["official-binary","external"],"darwin":["official-binary","external"]}' \
    "($system).supportedMethods" "supported methods"
done
assert_op_eq '{"command":"opencode","versionArgv":["--version"],"minimum":"agent_tools.opencode"}' \
  "($linux).install.external" "external block on Linux"
assert_op_eq '{"command":"opencode","versionArgv":["--version"],"minimum":"agent_tools.opencode-darwin"}' \
  "($darwin).install.external" "external block on darwin"

official='{
  "asset": { "linux": "opencode-linux-x64.tar.gz", "darwin": "opencode-darwin-arm64.zip" },
  "member": "opencode",
  "dest": "~/.local/bin/opencode",
  "versionArgv": ["--version"],
  "versionRegex": "([0-9]+([.][0-9]+){2})",
  "policy": "at-least",
  "verify": "sha256"
}'
assert_op_eq "$(jq '. + { pin: "agent_tools.opencode" }' <<<"$official")" "($linux).install.official-binary" \
  "official-binary block on Linux"
assert_op_eq "$(jq '. + { pin: "agent_tools.opencode-darwin" }' <<<"$official")" "($darwin).install.official-binary" \
  "official-binary block on darwin"

# OpenCode has no Nix install block: Pi is added to home.packages by the
# component itself (test-packages.sh), whatever the OpenCode method is.
assert_op_eq '[]' "($linux).install.nix.packages" "no nix install block"

# The method the instance configures wins on its platform.
external_linux='cfgWith { table.method_by_platform.linux = "external"; }'
assert_op_eq '"external"' "(component { config = $external_linux; }).method" "external method on Linux"
assert_op_eq '"official-binary"' "(component { config = $external_linux; system = \"aarch64-darwin\"; }).method" \
  "official-binary stays on darwin"

# --- Probes and checks -----------------------------------------------------------

probes='[
  { "command": "pi", "kind": "version", "argv": ["--version"], "env": { "PI_OFFLINE": "1" },
    "extract": "first-line", "expected": "skills:nix_tools.pi", "needles": [], "profiles": null },
  { "command": "pi", "kind": "features", "argv": ["--help"], "env": { "PI_OFFLINE": "1" },
    "extract": "first-line", "expected": null, "needles": ["--offline", "--no-skills"], "profiles": null },
  { "command": "pi", "kind": "features", "argv": ["auth", "check", "--help"], "env": { "PI_OFFLINE": "1" },
    "extract": "first-line", "expected": null, "needles": ["--json", "--no-refresh"], "profiles": null }
]'
agents='[
  { "name": "opencode-version", "script": "opencode-version.sh", "phase": "main", "profiles": null },
  { "name": "opencode-skill-api", "script": "opencode-skill-api.sh", "phase": "main", "profiles": null },
  { "name": "pi-rpc", "script": "pi-rpc.sh", "phase": "main", "profiles": null }
]'
for system in "$linux" "$darwin"; do
  assert_op_eq "$probes" "($system).probes" "probes"
  assert_op_eq '["opencode","pi"]' "($system).checks.commands" "commands"
  assert_op_eq "$agents" "hookNames ($system).checks.agents" "agents checks"
  assert_op_eq '[]' "($system).checks.e2e ++ ($system).checks.floors" "no e2e hooks or floors"
done

# The agents checks are executable files of the component, referenced in
# place (the manifest mirror names them <dotsteward>/modules/...).
assert_op_eq 'true' "map (hook: hook.script) ($linux).checks.agents == map (name: toString (dir + \"/probes/\${name}.sh\")) [ \"opencode-version\" \"opencode-skill-api\" \"pi-rpc\" ]" \
  "agents check scripts in the component directory"
for script in opencode-version.sh opencode-skill-api.sh opencode-skill-api.py pi-rpc.sh; do
  [[ -f $op_dir/probes/$script && -x $op_dir/probes/$script ]] ||
    ds_fail "probes/$script is not an executable file"
done

# --- Agent rules, links, backups, settings ---------------------------------------

for system in "$linux" "$darwin"; do
  assert_op_eq '[{"path":".pi/agent/AGENTS.md","force":false}]' "($system).agentRulesTargets" "agent rules target"
  assert_op_eq '["~/.pi/agent/AGENTS.md"]' "($system).rollback.managedLinks" "managed links"
  assert_op_eq '[]' "($system).rollback.forceLinkedRestore" "force-linked restore"
  assert_op_eq '["~/.pi/agent/AGENTS.md"]' "($system).bootstrap.backupPaths" "backup paths"
  assert_op_eq '{"opencode":{"path":"~/.config/opencode/opencode.json","format":"jsonc","createIfMissing":true,"createMode":"0644","backup":true,"reload":null}}' \
    "($system).settingsTargets" "settings targets"
  assert_op_eq '{}' "($system).reloadHooks" "reload hooks"
  assert_op_eq '{"legacyRoots":[],"linkRoots":{},"excludedSubtrees":[]}' "($system).skillLayout" "skill layout"
  assert_op_eq '[]' "($system).pins.flakeInputs" "flake inputs"
  assert_op_eq "{\"pi\":$(jq '.versions_lock.agent_tools.pi.version' "$op_seed")}" "($system).pins.resolvedVersions" \
    "resolved versions"
  assert_op_eq '"README.md"' "baseNameOf ($system).docs" "docs"
done

# The Pi agent rules file is linked into the generation like every agent
# rules target (modules/core/agent-rules.nix).
assert_op_eq 'true' '(home { }).home.file ? ".pi/agent/AGENTS.md"' "agent rules link"

# --- Pin rules ---------------------------------------------------------------------

model_template='https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-{agent_tools.pi.version}.tgz'
pi_rules=$(jq -n --arg model "$model_template" '[
  { kind: "derive", name: "pi-nix-package", to: "nix_packages.pi.expected", from: "agent_tools.pi.version",
    formats: {
      "agent_tools.pi.tag_revision": "hex40",
      "agent_tools.pi.source_nix_sha256": "sri",
      "agent_tools.pi.npm_dependencies_nix_sha256": "sri",
      "agent_tools.pi.model_data_nix_sha256": "sri"
    } },
  { kind: "derive", name: "pi-official-tag", to: "agent_tools.pi.official_tag",
    template: "v{agent_tools.pi.version}" },
  { kind: "derive", name: "pi-model-data-url", to: "agent_tools.pi.model_data_url", template: $model },
  { kind: "skills-lock-mirror", name: "pi-nix-tool", pairs: [
    { from: "nix_packages.pi.resolved", to: "skills:nix_tools.pi" }
  ] }
]')
linux_rules='[
  { "kind": "download-pin", "name": "opencode-release-linux", "at": "agent_tools.opencode",
    "version_field": "minimum_version",
    "url_contains": "https://github.com/anomalyco/opencode/releases/download/v{.minimum_version}/opencode-linux-x64.tar.gz",
    "formats": { ".source_revision": "hex40" } },
  { "kind": "skills-lock-mirror", "name": "opencode-release-tool", "pairs": [
    { "from": "agent_tools.opencode.minimum_version", "to": "skills:release_tools.opencode.version" },
    { "from": "agent_tools.opencode.source_revision", "to": "skills:release_tools.opencode.source_revision" },
    { "from": "agent_tools.opencode.url", "to": "skills:release_tools.opencode.url" },
    { "from": "agent_tools.opencode.size", "to": "skills:release_tools.opencode.size" },
    { "from": "agent_tools.opencode.sha256", "to": "skills:release_tools.opencode.sha256" },
    { "from": "agent_tools.opencode.native_auto_updates", "to": "skills:release_tools.opencode.native_auto_updates" }
  ] }
]'
darwin_rules='[
  { "kind": "download-pin", "name": "opencode-release-darwin", "at": "agent_tools.opencode-darwin",
    "version_field": "minimum_version",
    "url_contains": "https://github.com/anomalyco/opencode/releases/download/v{.minimum_version}/opencode-darwin-arm64.zip",
    "formats": { ".source_revision": "hex40" } }
]'
same_version='[
  { "kind": "derive", "name": "opencode-same-version", "to": "agent_tools.opencode-darwin.minimum_version",
    "from": "agent_tools.opencode.minimum_version" }
]'

# rules_of SYSTEMS_NIX [TABLE_NIX]: the pin rules of the component on each
# system of the configuration; they must not depend on the system (one lock
# serves every system).
rules_of() {
  local table=${2:-'{ }'} config rules system
  config="cfgWith { systems = $1; table = $table; }"
  rules=$(op_json "(component { config = $config; system = builtins.head $1; }).pins.rules" | jq -S .)
  for system in $(op_json "$1" | jq -r '.[]'); do
    assert_eq "$rules" "$(op_json "(component { config = $config; system = \"$system\"; }).pins.rules" | jq -S .)" \
      "pin rules on $system equal those of the first system"
  done
  printf '%s\n' "$rules"
}

both='[ "x86_64-linux" "aarch64-darwin" ]'
assert_eq "$(jq -S -n --argjson a "$pi_rules" --argjson b "$linux_rules" --argjson c "$darwin_rules" \
  --argjson d "$same_version" '$a + $b + $c + $d')" "$(rules_of "$both")" "pin rules with both platforms"
assert_eq "$(jq -S -n --argjson a "$pi_rules" --argjson b "$linux_rules" '$a + $b')" \
  "$(rules_of '[ "x86_64-linux" ]')" "pin rules of a Linux instance"
assert_eq "$(jq -S -n --argjson a "$pi_rules" --argjson c "$darwin_rules" '$a + $c')" \
  "$(rules_of '[ "aarch64-darwin" ]')" "pin rules of a darwin instance"
# A platform whose method is external reads no release pin.
assert_eq "$(jq -S -n --argjson a "$pi_rules" --argjson b "$linux_rules" '$a + $b')" \
  "$(rules_of "$both" '{ method_by_platform.darwin = "external"; }')" "darwin external"
assert_eq "$(jq -S . <<<"$pi_rules")" "$(rules_of "$both" '{ method = "external"; }')" "external everywhere"

# The contract does not depend on the profile; the app-archive block
# is unset (no default for its required fields) and never read.
assert_op_eq 'true' 'let
    defined = c: removeAttrs c [ "install" ] // { install = removeAttrs c.install [ "app-archive" ]; };
  in defined (component { }) == defined (component { profile = "fresh"; })' "same contract in every profile"

# --- Latest declarations -------------------------------------------------------------

pi_latest='[
  { "id": "agent_tools.pi", "adapter": "npm", "at": "agent_tools.pi", "package_at": "agent_tools.pi.package" }
]'
opencode_latest='[
  { "id": "agent_tools.opencode", "adapter": "github-release", "repo": "anomalyco/opencode", "tag_prefix": "v",
    "at": "agent_tools.opencode", "asset": "opencode-linux-x64.tar.gz" },
  { "id": "agent_tools.opencode-darwin", "adapter": "github-release", "repo": "anomalyco/opencode", "tag_prefix": "v",
    "at": "agent_tools.opencode-darwin", "asset": "opencode-darwin-arm64.zip" }
]'
expected_latest=$(jq -S -n --argjson a "$pi_latest" --argjson b "$opencode_latest" '$a + $b')
assert_eq "$expected_latest" "$(op_json "($linux).pins.latest" | jq -S .)" "latest on Linux"
assert_eq "$expected_latest" "$(op_json "($darwin).pins.latest" | jq -S .)" "latest on darwin"
assert_eq "$(jq -S -n --argjson a "$pi_latest" --argjson b "$opencode_latest" '$a + [$b[0]]')" \
  "$(op_json '(component { config = cfgWith { systems = [ "x86_64-linux" ]; }; }).pins.latest' | jq -S .)" \
  "latest of a Linux instance"
