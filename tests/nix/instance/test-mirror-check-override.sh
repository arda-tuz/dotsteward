# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# checks.<system>.dotsteward-manifest under a framework override: the
# .dotsteward/ mirrors describe the framework that flake.lock pins, so when
# the evaluated framework is another one (`--override-input dotsteward`, as
# the contribute trial and `gate --framework-override` run it) the staleness
# check does not apply and the check passes; `dotsteward sync` refreshes the
# mirrors when the instance moves to that framework. A matching or unknown
# framework narHash keeps the check as it is.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

pinned="sha256-$(printf 'A%.0s' {1..43})="
other="sha256-$(printf 'B%.0s' {1..43})="

copy=$(instance_copy "$nix_instance_fixtures/example")
# The instance lock pins the framework through the root's dotsteward edge
# (any node name).
jq --arg hash "$pinned" '
  .nodes.root.inputs.dotsteward = "dotsteward_2"
  | .nodes.dotsteward_2 = {locked: {type: "git", url: "https://example.invalid/dotsteward.git",
      rev: "0000000000000000000000000000000000000000", narHash: $hash}, original: {type: "git",
      url: "https://example.invalid/dotsteward.git"}}' \
  "$copy/flake.lock" >"$copy/flake.lock.new"
mv "$copy/flake.lock.new" "$copy/flake.lock"

# framework HASH: the dotsteward input with narHash HASH ("" for none).
framework() {
  local hash=""
  [[ -z $1 ]] || hash="narHash = \"$1\";"
  printf '{ outPath = repo; %s inputs = { nixpkgs = nixpkgsInput; home-manager = homeManagerInput; }; }' "$hash"
}
inst() {
  printf 'instance { root = /. + "%s"; inputs = { dotsteward = %s; }; }' "$copy" "$(framework "$1")"
}

# Fresh mirrors pass with the pinned framework.
write_mirrors "$(inst "$pinned")" "$copy"
assert_inst_eq '"dotsteward-manifest"' "($(inst "$pinned")).checks.x86_64-linux.dotsteward-manifest.name" \
  "fresh mirrors, pinned framework"

# A stale mirror fails with the pinned framework and with an unknown one.
sed -i '0,/"schema_version": 1/s//"schema_version": 2/' "$copy/.dotsteward/manifest.x86_64-linux.json"
for hash in "$pinned" ""; do
  assert_inst_fails "($(inst "$hash")).checks.x86_64-linux.dotsteward-manifest.drvPath" \
    "dotsteward: .dotsteward/manifest.x86_64-linux.json is stale" "run \`dotsteward sync\`"
done

# Another framework (an override): stale and missing mirrors are not checked,
# on every system.
assert_inst_eq '{"linux":"dotsteward-manifest","darwin":"dotsteward-manifest"}' \
  "let i = $(inst "$other"); in {
    linux = builtins.seq i.checks.x86_64-linux.dotsteward-manifest.drvPath i.checks.x86_64-linux.dotsteward-manifest.name;
    darwin = builtins.seq i.checks.aarch64-darwin.dotsteward-manifest.drvPath i.checks.aarch64-darwin.dotsteward-manifest.name;
  }" "stale mirror under an override"
rm "$copy/.dotsteward/stage0.linux.env"
assert_inst_eq '"dotsteward-manifest"' \
  "let i = $(inst "$other"); in builtins.seq i.checks.x86_64-linux.dotsteward-manifest.drvPath i.checks.x86_64-linux.dotsteward-manifest.name" \
  "missing mirror under an override"

# Without a pin to compare (no flake.lock, or no dotsteward edge in it), the
# check stays as it is.
cp "$copy/flake.lock" "$DS_TEST_ROOT/flake.lock.saved"
jq 'del(.nodes.root.inputs.dotsteward)' "$DS_TEST_ROOT/flake.lock.saved" >"$copy/flake.lock"
assert_inst_fails "($(inst "$other")).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/stage0.linux.env is missing"
rm "$copy/flake.lock"
assert_inst_fails "($(inst "$other")).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/stage0.linux.env is missing"
