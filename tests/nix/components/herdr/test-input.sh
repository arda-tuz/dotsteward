# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The herdr package comes from the instance flake input herdr. Without the
# input, or with an input that has no herdr package for the system, the
# generation fails with a message that names the component, the input and
# the line to add to flake.nix (the URL of the component seed). The other
# contract values never need the package, so tools that only read them (the
# seed lock-path check, the manifest of another component) keep working.
# shellcheck source=tests/nix/components/herdr/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/herdr/helpers.sh"

url=$(jq -er '.flake_inputs.herdr.url' "$herdr_component/seed.json")
[[ $url == github:herdrdev/herdr/v* ]] || ds_fail "unexpected seed URL: $url"

# No herdr input: home.packages and the manifest name the fix.
assert_herdr_fails 'map lib.getName (home (bareInstance { }) "x86_64-linux").home.packages' \
  'dotsteward: component herdr needs the instance flake input herdr' \
  "inputs.herdr.url = \"$url\";"
assert_herdr_fails 'manifestOf (bareInstance { }) "aarch64-darwin"' \
  'dotsteward: component herdr needs the instance flake input herdr'
assert_herdr_fails '(bareInstance { }).lib.pinnedVersions' \
  'dotsteward: component herdr needs the instance flake input herdr'

# An input without a herdr package for the system.
assert_herdr_fails 'map lib.getName (home (herdrInstance { inputs.herdr.packages = { }; }) "x86_64-linux").home.packages' \
  'dotsteward: component herdr: the instance flake input herdr has no packages.x86_64-linux.herdr'

# The contract values that do not install anything evaluate without the
# input.
assert_herdr_eq '{"path":"~/.config/herdr/config.toml","reload":"herdr-server","flakeInputs":["herdr"]}' \
  'let herdr = herdrOf (bareInstance { }) "x86_64-linux"; in {
    inherit (herdr.settingsTargets.herdr) path reload;
    inherit (herdr.pins) flakeInputs;
  }'
