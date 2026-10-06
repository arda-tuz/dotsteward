# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The template lock files (SPEC 10.1, 5.1, 5.2): versions.lock.json holds the
# framework sections only (policy, the Nix installer pin, nixpkgs and
# home-manager at the framework's revisions, and of the packages only core's
# tomlkit, which lib.pinnedVersions of every instance holds), the base that
# `dotsteward init` merges the component seeds into; agent/skills.lock.json
# holds no skill; local-maintained-files/buffer.toml no target and no entry.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

versions=$tpl/versions.lock.json
skills=$tpl/agent/skills.lock.json
buffer=$tpl/local-maintained-files/buffer.toml

# --- versions.lock.json ---------------------------------------------------------

jq -e . "$versions" >/dev/null || ds_fail "template/versions.lock.json is not valid JSON"
# Serialized as the pins engine writes it: two-space indentation, insertion
# order, a final newline.
assert_eq "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, ensure_ascii=False))' "$versions")" \
  "$(<"$versions")" "versions.lock.json serialization"

assert_eq '["schema_version","generated_at","policy","nix","flake_inputs","nix_packages"]' \
  "$(jq -c keys_unsorted "$versions")" "versions.lock.json sections"
assert_json "$versions" '.schema_version == "1.0"'
assert_json "$versions" '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\+00:00$")' \
  "generated_at is an ISO time with +00:00"
assert_json "$versions" '.policy == {
  official_sources_only: true,
  persistent_agentic_updates: false,
  scheduled_repository_updates: false,
  native_application_updates: true,
  major_version_review_required: true
}' "policy"
# Only core's pinned package before init: tomlkit, from the locked nixpkgs
# (`dotsteward sync --nix` writes its resolved version).
assert_json "$versions" '.nix_packages | keys == ["tomlkit"]' "only core's package before init"
assert_json "$versions" '.nix_packages.tomlkit.expected == "locked nixpkgs package"' "tomlkit follows nixpkgs"
assert_json "$versions" '.nix_packages.tomlkit.resolved | test("^[0-9]+([.][0-9]+)+$")' "tomlkit resolved version"

# The Nix installer pin stage-0 and tests/ci/install-nix.sh read: the
# official release installer, verified by size and SHA-256.
assert_eq '["version","installer_url","installer_size","installer_sha256"]' \
  "$(jq -c '.nix | keys_unsorted' "$versions")" "nix pin fields"
assert_json "$versions" '.nix.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "nix version"
assert_json "$versions" '.nix.installer_url == "https://releases.nixos.org/nix/nix-\(.nix.version)/install"' \
  "installer URL of the pinned version"
assert_json "$versions" '.nix.installer_size | type == "number" and . > 0 and . == floor' "installer size"
assert_json "$versions" '.nix.installer_sha256 | test("^[0-9a-f]{64}$")' "installer sha256"

# flake_inputs: nixpkgs and home-manager, the references of template/flake.nix
# and the revisions of the framework flake.lock; each follows a release
# channel of the same series, the series of the Home Manager state version.
assert_eq '["nixpkgs","home-manager"]' "$(jq -c '.flake_inputs | keys_unsorted' "$versions")" "flake inputs"
inputs=$(template_flake_inputs)
for input in nixpkgs home-manager; do
  node=$(lock_node "$input")
  pin=$(jq -c --arg input "$input" '.flake_inputs[$input]' "$versions")
  assert_eq '["reference","channel","revision"]' "$(jq -c keys_unsorted <<<"$pin")" "flake_inputs.$input fields"
  assert_eq "$(jq -r --arg input "$input" '.[$input].url' <<<"$inputs")" "$(jq -r .reference <<<"$pin")" \
    "flake_inputs.$input.reference is the template flake.nix URL"
  assert_eq "$(jq -r .locked.rev <<<"$node")" "$(jq -r .revision <<<"$pin")" \
    "flake_inputs.$input.revision is the framework flake.lock revision"
done
nixpkgs_channel=$(jq -r '.flake_inputs.nixpkgs.channel' "$versions")
home_manager_channel=$(jq -r '.flake_inputs["home-manager"].channel' "$versions")
[[ $nixpkgs_channel =~ ^nixos-([0-9]{2}\.[0-9]{2})$ ]] || ds_fail "nixpkgs channel [$nixpkgs_channel]"
series=${BASH_REMATCH[1]}
assert_eq "release-$series" "$home_manager_channel" "home-manager channel of the nixpkgs series"
state_version=$(python3 -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["nix"]["state_version"])' \
  "$tpl/workstation.toml")
assert_eq "$series" "$state_version" "nix.state_version is the channel series"

# --- agent/skills.lock.json -----------------------------------------------------

jq -e . "$skills" >/dev/null || ds_fail "template/agent/skills.lock.json is not valid JSON"
assert_eq "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, ensure_ascii=False))' "$skills")" \
  "$(<"$skills")" "skills.lock.json serialization"
assert_eq '["schema_version","generated_at","expected_skill_count","layout","skills"]' \
  "$(jq -c keys_unsorted "$skills")" "skills.lock.json sections"
assert_json "$skills" '.schema_version == "1.0" and .expected_skill_count == 0 and .skills == []'
assert_json "$skills" '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
  "generated_at is an ISO time with Z"
assert_json "$skills" '.layout == { canonical_user_directory: "~/.agents/skills" }' "layout"

# --- local-maintained-files/buffer.toml -----------------------------------------

assert_eq '{"schema_version": 1}' \
  "$(python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$buffer")" \
  "buffer.toml holds no target and no entry"
head -n 1 "$buffer" | grep -q '^# ' || ds_fail "buffer.toml lacks its header comment"
