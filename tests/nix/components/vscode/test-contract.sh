# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and vscode_* variables come from the harness and helpers.sh
# shellcheck disable=SC2088 # settings paths are compared as text, never expanded
# The vscode component's contract values (SPEC 3.5), as lib.mkInstance
# evaluates them on both systems with the default methods: deb on Linux
# (the official DEB of package code, pinned at desktop_packages.vscode),
# app-archive on darwin (the official arm64 archive, pinned at
# desktop_packages.vscode-darwin-arm64), the JSONC settings target with its
# per-platform path, the pins declarations of every pinned platform in both
# manifests, and nothing else: no probe, E2E command, hook, backup path,
# managed link or agent rules target.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

updates=https://update.code.visualstudio.com

rules=$(jq -cS -n --arg u "$updates" '[
  { component: "vscode", kind: "download-pin", name: "deb",
    at: "desktop_packages.vscode", version_field: "minimum_version",
    url_contains: ($u + "/{.minimum_version}/linux-deb-x64/stable") },
  { component: "vscode", kind: "download-pin", name: "app-archive",
    at: "desktop_packages.vscode-darwin-arm64", version_field: "minimum_version",
    url_contains: ($u + "/{.minimum_version}/darwin-arm64/stable") }
]')
latest=$(jq -cS -n --arg u "$updates" '[
  { component: "vscode", id: "desktop_packages.vscode", adapter: "official-manifest",
    at: "desktop_packages.vscode", current_field: "minimum_version",
    manifest_url: ($u + "/api/update/linux-deb-x64/stable/latest"),
    version_field: "productVersion", sha256_field: "sha256hash", size_url_field: "url",
    url_template: ($u + "/{version}/linux-deb-x64/stable"),
    source: "https://code.visualstudio.com/updates" },
  { component: "vscode", id: "desktop_packages.vscode-darwin-arm64", adapter: "official-manifest",
    at: "desktop_packages.vscode-darwin-arm64", current_field: "minimum_version",
    manifest_url: ($u + "/api/update/darwin-arm64/stable/latest"),
    version_field: "productVersion", sha256_field: "sha256hash", size_url_field: "url",
    url_template: ($u + "/{version}/darwin-arm64/stable"),
    source: "https://code.visualstudio.com/updates" }
]')

declare -A method=(
  [x86_64-linux]=deb
  [aarch64-darwin]=app-archive
)
declare -A install=(
  [x86_64-linux]='{"pin":"desktop_packages.vscode","packageNames":["code"],"architecture":"amd64","verifyAfterInstall":true,"apt":[]}'
  [aarch64-darwin]='{"pin":"desktop_packages.vscode-darwin-arm64","appName":"Visual Studio Code.app","dest":"~/Applications"}'
)
declare -A settings_path=(
  [x86_64-linux]='~/.config/Code/User/settings.json'
  [aarch64-darwin]='~/Library/Application Support/Code/User/settings.json'
)

# facts SYSTEM: one evaluation of everything the checks below read.
facts() {
  vscode_json "let
    inst = vscode { };
    config = home inst \"$1\";
    component = config.dotsteward.components.vscode;
  in {
    manifest = manifestOf inst \"$1\";
    inherit (component) rollback agentRulesTargets bootstrap skillLayout preflight gate rebuild checks probes;
    hooks = lib.filterAttrs (_: list: list != [ ]) component.hooks;
    docs = toString component.docs == toString (repoRoot + \"/modules/components/vscode/README.md\");
    target_path = component.settingsTargets.vscode-settings.path;
    targets_file = builtins.fromJSON (builtins.unsafeDiscardStringContext config.dotsteward.cli.aliasPackage.passthru.targetsFile.text);
  }"
}

for system in x86_64-linux aarch64-darwin; do
  all=$(facts "$system")
  manifest=$(jq -c .manifest <<<"$all")
  entry=$(jq -c '.components[] | select(.name == "vscode")' <<<"$manifest")
  [[ -n $entry ]] || ds_fail "vscode is not in the $system manifest"

  # The resolved default method, its install block, the supported methods.
  json_check "$entry" '{source, method, platforms, profiles, options, modes, supported_methods}' \
    "$(jq -cS -n --arg m "${method[$system]}" '{
      source: "catalog", method: $m, platforms: ["linux", "darwin"], profiles: null,
      options: { set_default_editor: true },
      modes: { workstation: "adopt", fresh: "fresh" },
      supported_methods: { linux: ["deb", "external"], darwin: ["app-archive", "external"] }
    }')"
  json_check "$entry" .install "$(jq -cS . <<<"${install[$system]}")"

  # The settings target: JSONC, the platform's path (the component declares
  # both), created when a tracked entry needs it, backed up, no reload (the
  # application watches the file).
  json_check "$all" .target_path \
    '{"darwin":"~/Library/Application Support/Code/User/settings.json","linux":"~/.config/Code/User/settings.json"}'
  target=$(jq -cS -n --arg p "${settings_path[$system]}" '{
    component: "vscode", path: $p, format: "jsonc", create_if_missing: true,
    create_mode: "0644", backup: true, reload: null }')
  json_check "$manifest" '.settings_targets["vscode-settings"]' "$target"
  json_check "$manifest" '.settings_targets | keys' '["vscode-settings"]'
  json_check "$manifest" '.reload_hooks' '{}'
  json_check "$all" '.targets_file.targets["vscode-settings"]' "$target"

  # Pins: the download pin and the official update API declaration of every
  # pinned platform of nix.systems, in both manifests (one lock serves every
  # system); no resolved version, no flake input.
  json_check "$manifest" '[.pins.rules[] | select(.component == "vscode")]' "$rules"
  json_check "$manifest" '[.pins.latest[] | select(.component == "vscode")]' "$latest"
  json_check "$manifest" '.pins.resolved_versions' '{}'
  json_check "$manifest" '.pins.flake_inputs' '[]'

  # Nothing else: VS Code is a system-level application whose files the
  # application owns; the owner's probe registry, E2E commands and stage-0
  # backup paths stay what they are.
  json_check "$manifest" '[.probes[] | select(.component == "vscode")]' '[]'
  json_check "$manifest" '[.checks[][] | select(.component == "vscode")]' '[]'
  json_check "$manifest" '[.hooks[][] | select(.component == "vscode")]' '[]'
  json_check "$all" .probes '[]'
  json_check "$all" .checks '{"agents":[],"commands":[],"e2e":[],"floors":[]}'
  json_check "$all" .hooks '{}'
  json_check "$all" .bootstrap '{"backupPaths":[],"prerequisites":{"apt":[]},"snapshots":[]}'
  json_check "$all" .rollback '{"forceLinkedRestore":[],"managedLinks":[]}'
  json_check "$all" .rebuild '{"adoptPaths":[]}'
  json_check "$all" .agentRulesTargets '[]'
  json_check "$all" .skillLayout '{"excludedSubtrees":[],"legacyRoots":[],"linkRoots":{}}'
  json_check "$all" .preflight '{"detectors":{}}'
  json_check "$all" .gate '{"updatePaths":[]}'

  # The user documentation is the component README.
  json_check "$all" .docs 'true'
done
