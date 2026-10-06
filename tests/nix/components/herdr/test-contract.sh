# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and herdr_* variables come from the harness and helpers.sh
# The herdr component's contract values (SPEC 3.5), as lib.mkInstance
# evaluates them on both systems: method nix with the package of the
# instance input herdr, the settings target and its reload hook (identical
# on Linux and darwin), the backup path, the presence probe, the E2E command,
# the pins contributions and the docs.
# shellcheck source=tests/nix/components/herdr/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/herdr/helpers.sh"

# The reload hook as the settings engine consumes it (the registry entry of
# the targets file in tests/engines/settings/core/test-reload.sh), without
# the owning component, which is checked on its own.
engine_hook=$(awk '/^cat >"\$targets" <<.EOF.$/ { on = 1; next } on && /^EOF$/ { exit } on' \
  "$DS_REPO_ROOT/tests/engines/settings/core/test-reload.sh" | jq -cS '.reload_hooks["herdr-server"] | del(.component)')
[[ $engine_hook == '{"command":'* ]] || ds_fail "the herdr-server registry entry of test-reload.sh was not found"

target='{"component":"herdr","path":"~/.config/herdr/config.toml","format":"toml","create_if_missing":true,"create_mode":"0644","backup":true,"reload":"herdr-server"}'

# facts SYSTEM: one evaluation of everything the checks below read.
facts() {
  herdr_json "let
    inst = herdrInstance { };
    config = home inst \"$1\";
    herdr = config.dotsteward.components.herdr;
    package = lib.findFirst (p: lib.getName p == \"herdr\") null config.home.packages;
  in {
    manifest = manifestOf inst \"$1\";
    package_version = if package == null then null else package.version;
    pinned = inst.lib.pinnedVersionsFor.\"$1\".herdr;
    inherit (herdr) rollback agentRulesTargets;
    docs = toString herdr.docs == toString (repoRoot + \"/modules/components/herdr/README.md\");
    target_path = herdr.settingsTargets.herdr.path;
    targets_file = builtins.fromJSON (builtins.unsafeDiscardStringContext config.dotsteward.cli.aliasPackage.passthru.targetsFile.text);
  }"
}

for system in x86_64-linux aarch64-darwin; do
  all=$(facts "$system")
  manifest=$(jq -c .manifest <<<"$all")

  # Method, supported methods, platforms, the installed package (the
  # input's package for the system).
  json_check "$manifest" '.components[] | select(.name == "herdr") | {source, method, platforms, profiles, supported_methods, install}' \
    '{"install":{"packages":["herdr"]},"method":"nix","platforms":["linux","darwin"],"profiles":null,"source":"catalog","supported_methods":{"darwin":["nix"],"linux":["nix"]}}'
  json_check "$all" .package_version '"0.9.3"'

  # The settings target: one path on both platforms (verified upstream),
  # and its reload hook exactly as the settings engine consumes it.
  json_check "$all" .target_path '"~/.config/herdr/config.toml"'
  json_check "$manifest" '.settings_targets.herdr' "$(jq -cS . <<<"$target")"
  json_check "$manifest" '.reload_hooks["herdr-server"] | del(.component)' "$engine_hook"
  json_check "$manifest" '.reload_hooks["herdr-server"].component' '"herdr"'
  # The generation's local-maintained-files alias carries both.
  json_check "$all" '.targets_file.targets.herdr' "$(jq -cS . <<<"$target")"
  json_check "$all" '.targets_file.reload_hooks["herdr-server"] | del(.component)' "$engine_hook"

  # Backup path, probe, E2E command.
  json_check "$manifest" '.backup_paths | index("~/.config/herdr/config.toml") != null' 'true'
  json_check "$manifest" '[.probes[] | select(.component == "herdr")]' \
    '[{"argv":["--version"],"command":"herdr","component":"herdr","env":{},"expected":null,"extract":"first-line","kind":"presence","needles":[],"profiles":null}]'
  json_check "$manifest" '[.checks.commands[] | select(.component == "herdr")]' '[{"command":"herdr","component":"herdr"}]'

  # Pins: the flake input, the derived expected version, the latest row,
  # the resolved version (the input package's version).
  json_check "$manifest" '.pins.flake_inputs' '["herdr"]'
  json_check "$manifest" '[.pins.rules[] | select(.component == "herdr")]' \
    '[{"component":"herdr","from":"flake_inputs.herdr.version","kind":"derive","to":"nix_packages.herdr.expected"}]'
  json_check "$manifest" '[.pins.latest[] | select(.component == "herdr")]' \
    '[{"adapter":"github-release","component":"herdr","id":"flake_inputs.herdr","repo":"herdrdev/herdr"}]'
  json_check "$manifest" '.pins.resolved_versions.herdr' '"0.9.3"'
  json_check "$all" .pinned '"0.9.3"'

  # Nothing herdr owns is linked by Home Manager or restored by rollback:
  # its configuration file is a normal user file that the application
  # writes itself.
  json_check "$all" .rollback '{"forceLinkedRestore":[],"managedLinks":[]}'
  json_check "$all" .agentRulesTargets '[]'
  json_check "$manifest" '.managed_links | map(select(contains("herdr"))) | length' '0'

  # The user documentation is the component README.
  json_check "$all" .docs 'true'
done
