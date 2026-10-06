# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core identity, profile and nix.conf: what every generation sets.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

summary='c: {
  inherit (c.home) username homeDirectory stateVersion sessionPath;
  homeManager = c.programs.home-manager.enable;
  xdg = c.xdg.enable;
  nixConf = c.xdg.configFile."nix/nix.conf".text;
  inherit (c.dotsteward) profile profileMode;
}'

# The minimal instance: identity from mkHome, state version from the
# configuration, the profile defaults to profiles.default.
actual=$(core_json "($summary) (homeOf { })")
json_check "$actual" . "$(jq -cS . <<'EOF'
{
  "username": "alice",
  "homeDirectory": "/home/alice",
  "stateVersion": "26.05",
  "sessionPath": ["$HOME/.local/bin"],
  "homeManager": true,
  "xdg": true,
  "nixConf": "experimental-features = nix-command flakes\nwarn-dirty = false\n",
  "profile": "main",
  "profileMode": "fresh"
}
EOF
)"

# Another identity and home (the check identity of a CI runner, a darwin
# home): taken from mkHome, never from workstation.toml.
actual=$(core_json "($summary) (homeOf { username = \"runner\"; homeDirectory = \"/Users/runner\"; system = \"aarch64-darwin\"; })")
json_check "$actual" '[.username, .homeDirectory]' '["runner","/Users/runner"]'

# Profiles carry their mode; the default profile is profiles.default.
actual=$(core_json "($summary) (homeOf { config = \"workstation\"; })")
json_check "$actual" '[.profile, .profileMode, .stateVersion]' '["workstation","adopt","25.11"]'
actual=$(core_json "($summary) (homeOf { config = \"workstation\"; profile = \"fresh\"; })")
json_check "$actual" '[.profile, .profileMode]' '["fresh","fresh"]'

# An unknown profile fails the assertions with the documented message.
assert_core_fails '(homeOf { config = "workstation"; profile = "nightly"; }).home.username' \
  "Failed assertions:" "- Unsupported dotsteward profile: nightly"

# home.username must stay the requested username.
assert_core_fails '(homeOf { modules = [ { home.username = lib.mkForce "bob"; } ]; }).home.username' \
  "- dotsteward: home.username bob differs from the requested username alice"

# The profile and its mode are read-only.
assert_core_fails '(homeOf { modules = [ { dotsteward.profile = "main"; } ]; }).dotsteward.profile' \
  "dotsteward.profile" "read-only"
assert_core_fails '(homeOf { modules = [ { dotsteward.profileMode = "adopt"; } ]; }).dotsteward.profileMode' \
  "dotsteward.profileMode" "read-only"

# nix.conf is identical on darwin.
assert_core_eq '"experimental-features = nix-command flakes\nwarn-dirty = false\n"' \
  '(homeOf { system = "aarch64-darwin"; homeDirectory = "/Users/alice"; }).xdg.configFile."nix/nix.conf".text'
