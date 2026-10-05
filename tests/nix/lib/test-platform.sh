# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/platform.nix: supported systems, platform facts, per-platform value
# selection, check homes and home expansion.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

assert_nix_eq '["x86_64-linux","aarch64-darwin"]' 'dsLib.platform.systems'
assert_nix_eq '["linux","darwin"]' 'dsLib.platform.platforms'
assert_nix_eq '{"system":"x86_64-linux","platform":"linux","arch":"x86_64","unameArch":"x86_64","isLinux":true,"isDarwin":false}' \
  'dsLib.platform.forSystem "x86_64-linux"'
assert_nix_eq '{"system":"aarch64-darwin","platform":"darwin","arch":"aarch64","unameArch":"arm64","isLinux":false,"isDarwin":true}' \
  'dsLib.platform.forSystem "aarch64-darwin"'
assert_nix_eq '["linux","darwin"]' 'map dsLib.platform.platformOf [ "x86_64-linux" "aarch64-darwin" ]'
for system in i686-linux x86_64-darwin aarch64-linux; do
  assert_nix_fails "dsLib.platform.forSystem \"$system\"" \
    "error: dotsteward: unsupported system $system (supported: x86_64-linux, aarch64-darwin)"
done

# selectPath: a string is used on every platform; a table picks the entry
# of the system's platform.
assert_nix_eq '["~/.config/example-app/settings.json","~/.config/example-app/settings.json"]' \
  'map (s: dsLib.platform.selectPath s "~/.config/example-app/settings.json") dsLib.platform.systems'
assert_nix_eq '["~/.config/Example/settings.json","~/Library/Application Support/Example/settings.json"]' \
  'map (s: dsLib.platform.selectPath s { linux = "~/.config/Example/settings.json"; darwin = "~/Library/Application Support/Example/settings.json"; }) dsLib.platform.systems'
assert_nix_eq '"~/.config/example-app"' 'dsLib.platform.selectPath "x86_64-linux" { linux = "~/.config/example-app"; }' "a missing branch is never forced"
assert_nix_fails 'dsLib.platform.selectPath "aarch64-darwin" { linux = "~/.config/example-app"; }' \
  'error: dotsteward: per-platform value {"linux":"~/.config/example-app"} has no darwin entry'
assert_nix_fails 'dsLib.platform.selectPath "x86_64-linux" { linux = "~/a"; windows = "C:/a"; }' \
  'error: dotsteward: per-platform value has unknown keys: windows (expected linux, darwin)'
assert_nix_fails 'dsLib.platform.selectPath "x86_64-linux" 42' \
  'error: dotsteward: expected a string or a { linux, darwin } table, got an integer'

# checkHome: the check identity's home per system.
assert_nix_eq '["/home/alice","/Users/alice"]' \
  'let c = loadFixture "valid/minimal"; in map (dsLib.platform.checkHome c) dsLib.platform.systems'

# expandHome: "~" and "~/..." only.
# shellcheck disable=SC2016 # literal shell parameter syntax inside Nix and JSON
assert_nix_eq '["/home/alice","/home/alice/.config/x","/etc/shells","relative/x","~user/x","${XDG_STATE_HOME:-~/.local/state}/x"]' \
  'map (dsLib.platform.expandHome "/home/alice") [ "~" "~/.config/x" "/etc/shells" "relative/x" "~user/x" "\${XDG_STATE_HOME:-~/.local/state}/x" ]'
