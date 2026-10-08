# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The Pi package of opencode-pi: package.nix builds Pi from the lock
# (agent_tools.pi) exactly like the reference derivation (pinned source tag,
# npm dependency hash, model data from the pi-ai package of the same version,
# the coding-agent workspace with --ignore-scripts and build:offline, the
# workspace copy loop, ripgrep and fd on the wrapper's PATH, the version
# check, no PI_* defaults), on Linux and darwin (evaluation); and the module
# adds it to home.packages wherever the component is active, whatever the
# OpenCode method is.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

# --- package.nix -------------------------------------------------------------------

assert_op_eq '["pi"]' 'builtins.attrNames (packagesFor "x86_64-linux" seedLock)' "package attributes"
# Published as packages.<system>.pi and built as checks.<system>.pi of the
# instance (lib/packages.nix), like the reference flake's checks.pi.
assert_op_eq 'true' '(packagesFor "x86_64-linux" seedLock).pi.check' "Pi package check"

facts='let p = piFor "x86_64-linux"; in {
  inherit (p) pname version npmWorkspace npmRebuildFlags doInstallCheck versionCheckProgramArg
    versionCheckKeepEnvironment;
  node = p.nodejs.version == (pkgsFor "x86_64-linux").nodejs_22.version;
  src = { inherit (p.src) outputHash tag; owner = p.src.owner or null; repo = p.src.repo or null; };
  deps = p.npmDeps.outputHash;
  model = { inherit (p.modelData) outputHash urls; };
  mainProgram = p.meta.mainProgram;
}'
expected=$(jq -c '.versions_lock.agent_tools.pi as $pi | {
  pname: "pi-coding-agent",
  version: $pi.version,
  npmWorkspace: "packages/coding-agent",
  npmRebuildFlags: ["--ignore-scripts"],
  doInstallCheck: true,
  versionCheckProgramArg: "--version",
  versionCheckKeepEnvironment: ["HOME"],
  node: true,
  src: { outputHash: $pi.source_nix_sha256, tag: $pi.official_tag, owner: "earendil-works", repo: "pi" },
  deps: $pi.npm_dependencies_nix_sha256,
  model: { outputHash: $pi.model_data_nix_sha256, urls: [$pi.model_data_url] },
  mainProgram: "pi"
}' "$op_seed")
assert_op_eq "$expected" "$facts" "Pi package facts"

# The model data URL is the template of the pi-model-data-url rule.
assert_op_eq 'true' 'let
    rule = lib.findFirst (r: (r.name or "") == "pi-model-data-url") null (component { }).pins.rules;
    url = builtins.replaceStrings [ "{agent_tools.pi.version}" ] [ seedLock.agent_tools.pi.version ] rule.template;
  in [ url ] == (piFor "x86_64-linux").modelData.urls' "model data URL and its derive rule"

# The build steps of the reference derivation.
phases=$(op_json 'let p = piFor "x86_64-linux"; in { inherit (p) preConfigure buildPhase postInstall postFixup; }')
pre=$(jq -r .preConfigure <<<"$phases")
assert_contains "$pre" 'mkdir -p packages/ai/src/providers/data'
assert_contains "$pre" '--strip-components=4'
assert_contains "$pre" 'package/dist/providers/data'
assert_contains "$(jq -r .buildPhase <<<"$phases")" 'npm run build:offline'
install=$(jq -r .postInstall <<<"$phases")
for workspace in chord:packages/chord pi-ai:packages/ai pi-agent-core:packages/agent pi-client:packages/client \
  pi-codemode:packages/codemode pi-durable:packages/durable pi-mcp:packages/mcp pi-protocol:packages/protocol \
  pi-server:packages/server pi-telemetry:packages/telemetry pi-tui:packages/tui; do
  assert_contains "$install" "@earendil-works/$workspace" "workspace copy loop"
done
assert_contains "$install" "find \"\$nm\" -type l -lname '*/packages/*' -delete"
assert_contains "$install" "find \"\$nm/.bin\" -xtype l -delete"
fixup=$(jq -r .postFixup <<<"$phases")
assert_contains "$fixup" 'wrapProgram $out/bin/pi --prefix PATH : '
assert_contains "$fixup" "$(op_raw '"${(pkgsFor "x86_64-linux").ripgrep}/bin"')"
assert_contains "$fixup" "$(op_raw '"${(pkgsFor "x86_64-linux").fd}/bin"')"
# No Pi environment defaults: the wrapper only extends PATH.
assert_not_contains "$fixup" 'PI_'
assert_not_contains "$fixup" '--set'

# darwin: the derivation evaluates (the Pi darwin build).
drv_suffix='"-pi-coding-agent-${seedLock.agent_tools.pi.version}.drv"'
assert_op_eq 'true' "let p = piFor \"aarch64-darwin\"; in p.meta.available && lib.hasSuffix $drv_suffix p.drvPath" \
  "Pi derivation on darwin"
assert_op_eq 'true' "lib.hasSuffix $drv_suffix (piFor \"x86_64-linux\").drvPath" "Pi derivation on Linux"

# A lock without a Pi field names it and the component.
assert_op_fails '(packagesFor "x86_64-linux" (seedLock // {
    agent_tools = seedLock.agent_tools // { pi = builtins.removeAttrs seedLock.agent_tools.pi [ "source_nix_sha256" ]; };
  })).pi.package.drvPath' \
  'dotsteward: versions.lock.json lacks agent_tools.pi.source_nix_sha256 (required by component opencode-pi)'

# --- home.packages -------------------------------------------------------------------

# pi_names ARGS: the Pi packages in home.packages of (home ARGS).
pi_names() {
  op_json "map lib.getName (lib.filter (p: lib.getName p == \"pi-coding-agent\") (home ($1)).home.packages)" | jq -c .
}

assert_eq '["pi-coding-agent"]' "$(pi_names '{ }')" "active on Linux"
assert_eq '["pi-coding-agent"]' "$(pi_names '{ system = "aarch64-darwin"; }')" "active on darwin"
assert_eq '["pi-coding-agent"]' "$(pi_names '{ profile = "fresh"; }')" "active in every profile"
assert_eq '[]' "$(pi_names '{ enable = false; }')" "disabled"
assert_eq '["pi-coding-agent"]' "$(pi_names '{ profiles = [ "workstation" ]; }')" "active profile"
assert_eq '[]' "$(pi_names '{ profiles = [ "workstation" ]; profile = "fresh"; }')" "inactive profile"
assert_eq '[]' "$(pi_names '{ modules = [ { dotsteward.components.opencode-pi.platforms = lib.mkForce [ "darwin" ]; } ]; }')" \
  "unsupported platform"
assert_eq '["pi-coding-agent"]' \
  "$(pi_names '{ modules = [ { dotsteward.components.opencode-pi.method = "external"; } ]; }')" \
  "Pi stays with the external OpenCode method"

# The installed package is the package set's pi (an instance may replace it
# through extraPackages).
assert_op_eq 'true' 'lib.elem (piFor "x86_64-linux") (home { }).home.packages' "package from the package set"

# Without pi in the package set the contract still evaluates (the seed
# lock-path check reads it that way), and home.packages names what is
# missing.
bare='homeOf { config = cfg; modules = [ (dir + "/default.nix") { dotsteward.components.opencode-pi.enable = true; } ]; }'
assert_op_eq '"agent_tools.opencode"' "($bare).dotsteward.components.opencode-pi.install.official-binary.pin" \
  "contract without the package"
assert_op_fails "builtins.length ($bare).home.packages" \
  'dotsteward: component opencode-pi needs the package pi (modules/components/opencode-pi/package.nix)'
