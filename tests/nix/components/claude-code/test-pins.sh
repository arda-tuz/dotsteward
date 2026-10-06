# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs in single quotes
# The pins the claude-code component declares, run by the pins engine
# (`dotsteward pins check`) on an instance that enables it: the fixture
# instance with the seed merged into its lock (as `dotsteward init` does)
# and its manifest mirrors, once with official-binary (the release pins of
# both platforms) and once with deb. The seed passes; a broken digest or a
# URL that does not carry the pinned version is reported at its lock path.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

# pins_instance CONFIG_EXPR: a new git instance at $inst, from the fixture
# instance with workstation.toml taken from CONFIG_EXPR (a Nix path
# expression), the seed merged into versions.lock.json, the flake.nix and
# flake.lock of the inputs the fixture lock records (from the example
# instance of tests/nix/instance), and the manifest mirrors.
pins_instance() {
  local config mirrors name
  config=$(cc_json "toString ($1)" | jq -r .)
  inst=$(instance_copy "$cc_fixture_root")
  cp -- "$config" "$inst/workstation.toml"
  cp -- "$nix_instance_fixtures/example/flake.nix" "$nix_instance_fixtures/example/flake.lock" "$inst/"
  jq -s '.[0] * .[1].versions_lock' "$cc_fixture_root/versions.lock.json" "$cc_seed" >"$inst/versions.lock.json"
  mirrors=$(cc_json "(cc { config = $1; }).dotstewardMirrors")
  mkdir -p "$inst/.dotsteward"
  while IFS= read -r name; do
    jq -j --arg name "$name" '.[$name]' <<<"$mirrors" >"$inst/.dotsteward/$name"
  done < <(jq -r 'keys[]' <<<"$mirrors")
  git -C "$inst" init -q
  git -C "$inst" add -A
  git -C "$inst" -c user.name=test -c user.email=test@example.invalid commit -q -m instance
}

pins_check() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check
}

# official-binary on both systems: the release pins of linux-x64 and
# darwin-arm64.
pins_instance 'ccRoot + "/workstation.toml"'
assert_exit 0 pins_check
assert_contains "$DS_STDOUT" "All pin consistency checks passed"

lock_edit() {
  jq "$1" "$inst/versions.lock.json" >"$DS_TEST_ROOT/lock.json"
  mv -- "$DS_TEST_ROOT/lock.json" "$inst/versions.lock.json"
}

lock_edit '.agent_tools["claude-code"]["darwin-arm64"].sha256 = "not-a-digest"'
assert_exit 1 pins_check
assert_contains "$DS_STDERR" "agent_tools.claude-code.darwin-arm64.sha256"

pins_instance 'ccRoot + "/workstation.toml"'
lock_edit '.agent_tools["claude-code"]["linux-x64"].version = "2.1.286"'
assert_exit 1 pins_check
assert_contains "$DS_STDERR" "agent_tools.claude-code.linux-x64.url"
assert_contains "$DS_STDERR" "/2.1.286/linux-x64/claude"

# deb: the DEB pin.
pins_instance 'ccCase "method-deb"'
assert_exit 0 pins_check
assert_contains "$DS_STDOUT" "All pin consistency checks passed"

lock_edit '.desktop_packages["claude-code"].minimum_version = "2.1.286-1"'
assert_exit 1 pins_check
assert_contains "$DS_STDERR" "desktop_packages.claude-code.url"
assert_contains "$DS_STDERR" "/claude-code_2.1.286-1_amd64.deb"
