# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The methods of claude-code: official-binary (default, both platforms), deb
# (Linux) and external (both), selected with [components.claude-code]
# method and method_by_platform. The manifest carries the install block of
# the resolved method. The pins declarations (download-pin rules, latest
# adapters) follow the method of each platform in nix.systems and are the
# same on every system, so an instance lock needs only the pins its methods
# read.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

# pins_of INSTANCE_EXPR SYSTEM: the claude-code rules and latest
# declarations of the manifest, without the component tag.
pins_of() {
  cc_json "let
    m = ccManifest ($1) \"$2\";
    own = lib.filter (e: e.component == \"claude-code\");
    untag = map (e: removeAttrs e [ \"component\" ]);
  in { rules = untag (own m.pins.rules); latest = untag (own m.pins.latest); }" | jq -S .
}

releases=https://downloads.claude.ai/claude-code-releases

# official_pins RELEASE_PLATFORM...: the expected official-binary pins, one
# download-pin rule and one official-manifest row per release platform.
official_pins() {
  printf '%s\n' "$@" | jq -S -s -R --arg base "$releases" 'split("\n") | map(select(. != "")) | {
    rules: map({
      kind: "download-pin",
      at: ("agent_tools.claude-code." + .),
      url_contains: ("/{.version}/" + . + "/claude")
    }),
    latest: map({
      id: ("agent_tools.claude-code." + .),
      adapter: "official-manifest",
      at: ("agent_tools.claude-code." + .),
      version_url: ($base + "/stable"),
      manifest_url: ($base + "/{version}/manifest.json"),
      version_field: "version",
      sha256_field: ("platforms." + . + ".checksum"),
      size_field: ("platforms." + . + ".size"),
      url_template: ($base + "/{version}/" + . + "/claude")
    })
  }'
}

# official-binary: the pins cover the release platform of every system in
# nix.systems (one lock serves them all), the same on each system; the
# install block pins the release platform of its own system.
for system in x86_64-linux aarch64-darwin; do
  assert_eq "$(official_pins linux-x64 darwin-arm64)" "$(pins_of 'cc { }' "$system")" \
    "official-binary pins on $system"
done
assert_cc_eq '["agent_tools.claude-code.linux-x64","agent_tools.claude-code.darwin-arm64"]' \
  'let i = cc { }; in [ (ccEntry i "x86_64-linux").install.pin (ccEntry i "aarch64-darwin").install.pin ]' \
  "release pin of each system"
# A Linux-only instance declares the Linux release pin only.
assert_eq "$(official_pins linux-x64)" "$(pins_of 'cc { config = ccCase "linux-only"; }' x86_64-linux)" \
  "official-binary pins of a Linux-only instance"

# deb (Linux): the DEB pin, the package name and architecture asserted after
# the download, and the stable APT index.
assert_cc_eq '{
  "method": "deb",
  "install": {
    "pin": "desktop_packages.claude-code",
    "packageNames": ["claude-code"],
    "architecture": "amd64",
    "verifyAfterInstall": true,
    "apt": []
  }
}' 'let e = ccEntry (cc { config = ccCase "method-deb"; }) "x86_64-linux"; in { inherit (e) method install; }' \
  "deb install block"
deb_pins=$(jq -S -n '{
  rules: [{
    kind: "download-pin",
    at: "desktop_packages.claude-code",
    version_field: "minimum_version",
    url_contains: "/claude-code_{.minimum_version}_amd64.deb"
  }],
  latest: [{
    id: "desktop_packages.claude-code",
    adapter: "apt-index",
    at: "desktop_packages.claude-code",
    base: "https://downloads.claude.ai/claude-code/apt/stable",
    package: "claude-code",
    dist: "stable"
  }]
}')
assert_eq "$deb_pins" "$(pins_of 'cc { config = ccCase "method-deb"; }' x86_64-linux)" "deb pins"

# external: claude on PATH, no floor and no pins.
assert_cc_eq '{
  "method": "external",
  "install": { "command": "claude", "versionArgv": ["--version"], "minimum": null }
}' 'let e = ccEntry (cc { config = ccCase "method-external"; }) "x86_64-linux"; in { inherit (e) method install; }' \
  "external install block"
assert_eq '{"latest":[],"rules":[]}' "$(pins_of 'cc { config = ccCase "method-external"; }' x86_64-linux | jq -c .)" \
  "external pins"

# method_by_platform: deb on Linux, external on darwin.
assert_cc_eq '["deb","external"]' 'let i = cc { config = ccCase "method-by-platform"; }; in
  [ (ccEntry i "x86_64-linux").method (ccEntry i "aarch64-darwin").method ]' "method_by_platform"
assert_cc_eq '["deb","external"]' 'let i = cc { config = ccCase "method-by-platform"; }; in
  [ (ccComponent i "x86_64-linux").method (ccComponent i "aarch64-darwin").method ]' "resolved methods"

# The pins of a mixed method_by_platform follow the method of each
# platform, never the method of the system being evaluated, and every
# system declares the same set: deb on Linux and external on darwin need the
# deb pin only.
for system in x86_64-linux aarch64-darwin; do
  assert_eq "$deb_pins" "$(pins_of 'cc { config = ccCase "method-by-platform"; }' "$system")" \
    "deb (Linux) and external (darwin) pins on $system"
done
# official-binary on Linux and external on darwin: the Linux release pin
# only.
for system in x86_64-linux aarch64-darwin; do
  assert_eq "$(official_pins linux-x64)" \
    "$(pins_of 'cc { config = ccCase "official-linux-external-darwin"; }' "$system")" \
    "official-binary (Linux) and external (darwin) pins on $system"
done
# deb on Linux and official-binary on darwin (the README example): the darwin
# release pin and the deb pin, no Linux release pin.
deb_official_pins=$(jq -S -n --argjson official "$(official_pins darwin-arm64)" --argjson deb "$deb_pins" \
  '{ rules: ($official.rules + $deb.rules), latest: ($official.latest + $deb.latest) }')
for system in x86_64-linux aarch64-darwin; do
  assert_eq "$deb_official_pins" \
    "$(pins_of 'cc { config = ccCase "deb-linux-official-darwin"; }' "$system")" \
    "deb (Linux) and official-binary (darwin) pins on $system"
done
assert_cc_eq '["deb","official-binary"]' 'let i = cc { config = ccCase "deb-linux-official-darwin"; }; in
  [ (ccEntry i "x86_64-linux").method (ccEntry i "aarch64-darwin").method ]' \
  "deb (Linux) and official-binary (darwin) methods"
assert_cc_eq '"agent_tools.claude-code.darwin-arm64"' \
  '(ccEntry (cc { config = ccCase "deb-linux-official-darwin"; }) "aarch64-darwin").install.pin' \
  "darwin release pin with deb on Linux"

# deb on darwin is refused by the supported-methods assertion; Linux still
# evaluates.
assert_cc_eq '"deb"' '(ccEntry (cc { config = ccCase "darwin-deb"; }) "x86_64-linux").method' \
  "deb on Linux in a two-system instance"
assert_cc_fails '(cc { config = ccCase "darwin-deb"; }).dotstewardManifest.aarch64-darwin.system' \
  "Failed assertions:" \
  "dotsteward: component claude-code does not support method deb on darwin (supported: official-binary, external)"

# The settings targets, agent rules target and skill layout do not depend
# on the method.
assert_cc_eq 'true' 'let
  keep = m: {
    settings = lib.filterAttrs (_: t: t.component == "claude-code") m.settings_targets;
    inherit (m) skill_layout managed_links backup_paths;
    rules = m.agent_rules.targets;
  };
in keep (ccManifest (cc { }) "x86_64-linux") == keep (ccManifest (cc { config = ccCase "method-deb"; }) "x86_64-linux")
  && keep (ccManifest (cc { }) "x86_64-linux") == keep (ccManifest (cc { config = ccCase "method-external"; }) "x86_64-linux")' \
  "method-independent contributions"
