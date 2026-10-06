# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# lib.pinnedVersions and lib.pinnedVersionsFor: enabled components'
# pins.resolvedVersions, core's tomlkit and [pins] nixpkgs_versions.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

expected() {
  inst_json "let pkgs = import nixpkgsInput { system = \"$1\"; config.allowUnfree = false; }; in {
    example-app = \"1.2.3\";
    example-term = \"2.0.0\";
    tomlkit = pkgs.python3Packages.tomlkit.version;
    hello = pkgs.hello.version;
    example-lib = pkgs.python3Packages.six.version;
  }"
}

linux=$(expected x86_64-linux)
darwin=$(expected aarch64-darwin)
assert_eq "$(jq -S . <<<"$linux")" "$(inst_json 'example.lib.pinnedVersions' | jq -S .)" "primary system"
assert_eq "$(jq -S . <<<"$linux")" "$(inst_json 'example.lib.pinnedVersionsFor.x86_64-linux' | jq -S .)" \
  "pinnedVersionsFor x86_64-linux"
assert_eq "$(jq -S . <<<"$darwin")" "$(inst_json 'example.lib.pinnedVersionsFor.aarch64-darwin' | jq -S .)" \
  "pinnedVersionsFor aarch64-darwin"

# The manifest of each system carries the same map.
assert_inst_eq 'true' \
  'storeless example.dotstewardManifest.aarch64-darwin.pinned_versions == example.lib.pinnedVersionsFor.aarch64-darwin' \
  "manifest pinned_versions"

# Core's tomlkit alone for an instance without components.
assert_inst_eq 'true' \
  'minimal.lib.pinnedVersions == { tomlkit = (import nixpkgsInput { system = "x86_64-linux"; }).python3Packages.tomlkit.version; }' \
  "minimal"

# Problems name their source.
pins_case() {
  local copy=$1 table=$2
  sed -i '/^\[pins\]$/,$d' "$copy/workstation.toml"
  printf '[pins]\nnixpkgs_versions = %s\n' "$table" >>"$copy/workstation.toml"
}
copy=$(instance_copy "$nix_instance_fixtures/example")

pins_case "$copy" '{ nope = "example-no-such-package" }'
assert_inst_fails "(instance { root = /. + \"$copy\"; }).lib.pinnedVersions" \
  "dotsteward: [pins] nixpkgs_versions.nope: nixpkgs has no attribute example-no-such-package"

pins_case "$copy" '{ nope = "lib" }'
assert_inst_fails "(instance { root = /. + \"$copy\"; }).lib.pinnedVersions" \
  "dotsteward: [pins] nixpkgs_versions.nope: nixpkgs attribute lib is not a package with a version"

pins_case "$copy" '{ example-app = "hello" }'
assert_inst_fails "(instance { root = /. + \"$copy\"; }).lib.pinnedVersions" \
  "dotsteward: pinned version example-app is declared twice (by component example-app and by [pins] nixpkgs_versions)"

pins_case "$copy" '{ tomlkit = "python3Packages.tomlkit" }'
assert_inst_fails "(instance { root = /. + \"$copy\"; }).lib.pinnedVersions" \
  "dotsteward: pinned version tomlkit is declared twice (by core and by [pins] nixpkgs_versions)"

# Two components declaring the same key.
copy=$(instance_copy "$nix_instance_fixtures/example")
sed -i 's/pins.resolvedVersions.example-term = "2.0.0";/pins.resolvedVersions.example-app = "2.0.0";/' \
  "$copy/components/example-term/default.nix"
assert_inst_fails "(instance { root = /. + \"$copy\"; }).lib.pinnedVersions" \
  "dotsteward: pinned version example-app is declared twice (by component example-term and by component example-app)"
