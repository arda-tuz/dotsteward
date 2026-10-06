# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# checks.<system>.dotsteward-manifest: every committed mirror under
# .dotsteward/ equals the evaluated value (all systems and platforms, so a
# darwin problem also fails the Linux check); a stale or missing mirror fails
# the evaluation and names `dotsteward sync`.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

copy=$(instance_copy "$nix_instance_fixtures/example")
inst="instance { root = /. + \"$copy\"; }"

# Without mirrors.
assert_inst_fails "($inst).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/manifest.x86_64-linux.json is missing" "run \`dotsteward sync\`"

# Fresh mirrors pass on every system.
write_mirrors "$inst" "$copy"
assert_eq '["cli.sh","manifest.aarch64-darwin.json","manifest.x86_64-linux.json","stage0.darwin.env","stage0.linux.env"]' \
  "$(cd "$copy/.dotsteward" && printf '%s\n' * | jq -Rsc 'split("\n") | map(select(. != ""))')" "written mirrors"
assert_inst_eq '{"linux":"dotsteward-manifest","darwin":"dotsteward-manifest"}' \
  "let i = $inst; in {
    linux = i.checks.x86_64-linux.dotsteward-manifest.name;
    darwin = i.checks.aarch64-darwin.dotsteward-manifest.name;
  }" "fresh mirrors"

# A mirror written for the fixture directory is the same in a copy: no
# value depends on where the instance lives.
other=$(instance_copy "$copy")
assert_inst_eq '"dotsteward-manifest"' \
  "(instance { root = /. + \"$other\"; }).checks.x86_64-linux.dotsteward-manifest.name" "location independent"

# One changed byte in any mirror fails every system's check.
sed -i '0,/"schema_version": 1/s//"schema_version": 2/' "$copy/.dotsteward/manifest.aarch64-darwin.json"
assert_inst_fails "($inst).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/manifest.aarch64-darwin.json is stale" "run \`dotsteward sync\`"
write_mirrors "$inst" "$copy"
printf '# local edit\n' >>"$copy/.dotsteward/stage0.linux.env"
assert_inst_fails "($inst).checks.aarch64-darwin.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/stage0.linux.env is stale"

# A missing stage-0 file.
write_mirrors "$inst" "$copy"
rm "$copy/.dotsteward/stage0.darwin.env"
assert_inst_fails "($inst).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/stage0.darwin.env is missing"

# A change of the instance that changes the contract makes the mirror stale.
write_mirrors "$inst" "$copy"
sed -i 's|"~/.config/example-app/state"|"~/.config/example-app/state2"|' "$copy/components/example-app/default.nix"
assert_inst_fails "($inst).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/manifest.x86_64-linux.json is stale" ".dotsteward/stage0.linux.env is stale"
