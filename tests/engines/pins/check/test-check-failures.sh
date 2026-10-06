# shellcheck shell=bash
# `dotsteward pins check`: one mutation per failure class of every rule
# kind, each asserting exit 1, the exact English failure lines and the
# summary. Lines have the shape "[pins] ERROR: <label>: <problem>".
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance

rev_n=$(jq -r '.flake_inputs.nixpkgs.revision' "$versions")
nar_n=$(jq -r '.flake_inputs.nixpkgs.nar_hash' "$versions")
a40=$(printf 'a%.0s' {1..40})
b40=$(printf 'b%.0s' {1..40})
sri_b="sha256-$(printf 'B%.0s' {1..43})="
sri_fake="sha256-$(printf 'A%.0s' {1..43})="
E='[pins] ERROR: '

# The full summary text.
pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-lint"]["resolved"] = "0.9.1"'
check_fails 1 "${E}nix_packages.example-lint.resolved: expected '0.9.0', found '0.9.1'"
assert_eq "[pins] 1 inconsistency; fix the source value in the lock files, then run 'dotsteward pins sync' for derived mirrors" \
  "$(tail -n 1 <<<"$DS_STDERR")"

# --- flake-inputs ---------------------------------------------------------------

pins_fresh
json_edit "$versions" "data['flake_inputs']['example-extra'] = {'reference': 'github:example/example-extra/$a40', 'revision': '$a40'}"
check_fails 2 \
  "${E}flake.lock root inputs: expected ['example-extra', 'example-term', 'nixpkgs'], found ['example-term', 'nixpkgs']" \
  "${E}flake_inputs.example-extra.reference: 'github:example/example-extra/$a40' not found in flake.nix"

pins_fresh
sed -i "s|github:example/nixpkgs/$rev_n|github:example/nixpkgs/$b40|" "$inst/flake.nix"
check_fails 1 "${E}flake_inputs.nixpkgs.reference: 'github:example/nixpkgs/$rev_n' not found in flake.nix"

pins_fresh
json_edit "$versions" "data['flake_inputs']['nixpkgs']['revision'] = '$b40'"
check_fails 1 "${E}flake_inputs.nixpkgs.revision (flake.lock): expected '$b40', found '$rev_n'"

pins_fresh
json_edit "$versions" "data['flake_inputs']['nixpkgs']['revision'] = 'main'"
check_fails 2 \
  "${E}flake_inputs.nixpkgs.revision: invalid format 'main', expected hex40" \
  "${E}flake_inputs.nixpkgs.revision (flake.lock): expected 'main', found '$rev_n'"

pins_fresh
json_edit "$versions" "data['flake_inputs']['nixpkgs']['nar_hash'] = '$sri_b'"
check_fails 1 "${E}flake_inputs.nixpkgs.nar_hash (flake.lock): expected '$sri_b', found '$nar_n'"

pins_fresh
json_edit "$versions" 'data["flake_inputs"]["example-term"]["version"] = "1.3.0"'
check_fails 2 \
  "${E}flake_inputs.example-term.version: reference 'github:example/example-term/v1.2.0' does not end with '/v1.3.0'" \
  "${E}nix_packages.example-term.expected: expected '1.3.0', found '1.2.0'"

pins_fresh
json_edit "$versions" 'data["flake_inputs"]["example-term"]["reference"] = "github:example/example-term/v1.1.0"'
sed -i 's|github:example/example-term/v1.2.0|github:example/example-term/v1.1.0|' "$inst/flake.nix"
check_fails 2 \
  "${E}flake_inputs.example-term.version: reference 'github:example/example-term/v1.1.0' does not end with '/v1.2.0'" \
  "${E}flake_inputs.example-term.reference (flake.lock): expected 'github:example/example-term/v1.1.0', found 'github:example/example-term/v1.2.0'"

# --- nix-package-format ---------------------------------------------------------

pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-term"]["official_tag"] = "1.2.0"'
check_fails 1 "${E}nix_packages.example-term.official_tag: expected 'v1.2.0', found '1.2.0'"

pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-term"]["tag_revision"] = "not-a-revision"; data["nix_packages"]["example-term"]["source_nix_sha256"] = "sha256-short"'
check_fails 2 \
  "${E}nix_packages.example-term.tag_revision: invalid format 'not-a-revision', expected hex40" \
  "${E}nix_packages.example-term.source_nix_sha256: invalid format 'sha256-short', expected sri"

pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-shell"]["resolved"] = ""'
check_fails 1 "${E}nix_packages.example-shell.resolved: invalid format '', expected nonempty"

# --- derive ---------------------------------------------------------------------

pins_fresh
json_edit "$versions" 'data["agent_tools"]["example-app"]["model_data_url"] = "https://registry.example.invalid/example-app/-/example-app-3.0.0.tgz"'
check_fails 1 "${E}agent_tools.example-app.model_data_url: expected 'https://registry.example.invalid/example-app/-/example-app-3.1.0.tgz', found 'https://registry.example.invalid/example-app/-/example-app-3.0.0.tgz'"

pins_fresh
json_edit "$versions" 'del data["agent_tools"]["example-app"]["official_tag"]'
check_fails 1 "${E}agent_tools.example-app.official_tag: expected 'v3.1.0', found None"

pins_fresh
json_edit "$versions" 'data["agent_tools"]["example-app"]["source_nix_sha256"] = "sha256-short"'
check_fails 1 "${E}agent_tools.example-app.source_nix_sha256: invalid format 'sha256-short', expected sri"

# for_each over a map, with the text-guard over the same map.
pins_fresh
json_edit "$versions" 'data["example_policy"]["exact_versions"]["example-lint"] = "0.9.5"'
check_fails 2 \
  "${E}nix_packages.example-lint.expected: expected '0.9.5', found '0.9.0'" \
  "${E}home.nix: missing 'pkgs.example-lint.version == \"0.9.5\"'"

# --- text-guard -----------------------------------------------------------------

pins_fresh
sed -i 's|pkgs.example-lint.version == "0.9.0"|pkgs.example-lint.version != null|' "$inst/home.nix"
check_fails 1 "${E}home.nix: missing 'pkgs.example-lint.version == \"0.9.0\"'"

pins_fresh
rm "$inst/home.nix"
check_fails 1 "${E}home.nix: no such file"

# --- download-pin ---------------------------------------------------------------

pins_fresh
json_edit "$versions" 'data["desktop_packages"]["example-desktop"]["url"] = "https://downloads.example.invalid/example-desktop_amd64.deb"'
check_fails 1 "${E}desktop_packages.example-desktop.url: expected to contain '1.5.0', found 'https://downloads.example.invalid/example-desktop_amd64.deb'"

pins_fresh
json_edit "$versions" 'data["desktop_packages"]["example-desktop"]["url"] = "http://downloads.example.invalid/example-desktop_1.5.0_amd64.deb"'
check_fails 1 "${E}desktop_packages.example-desktop.url: invalid format 'http://downloads.example.invalid/example-desktop_1.5.0_amd64.deb', expected https-url"

pins_fresh
json_edit "$versions" 'd = data["desktop_packages"]["example-desktop"]; d["size"] = 0; d["sha256"] = "ABC"; d["minimum_version"] = ""'
check_fails 3 \
  "${E}desktop_packages.example-desktop.minimum_version: invalid format '', expected nonempty" \
  "${E}desktop_packages.example-desktop.size: invalid format 0, expected positive-int" \
  "${E}desktop_packages.example-desktop.sha256: invalid format 'ABC', expected hex64"

# A URL that is not a string is a format failure, not a crash.
pins_fresh
json_edit "$versions" 'data["desktop_packages"]["example-desktop"]["url"] = 5'
check_fails 2 \
  "${E}desktop_packages.example-desktop.url: invalid format 5, expected https-url" \
  "${E}desktop_packages.example-desktop.url: expected to contain '1.5.0', found 5"

# Entries without the only_with field are skipped.
pins_fresh
json_edit "$versions" 'data["desktop_packages"]["example-apt-only"]["minimum_version"] = ""'
assert_exit 0 pins check

pins_fresh
json_edit "$versions" 'data["nix"]["installer_url"] = "https://releases.example.invalid/nix/latest/install"'
check_fails 1 "${E}nix.installer_url: expected to contain '/nix-2.31.2/', found 'https://releases.example.invalid/nix/latest/install'"

pins_fresh
json_edit "$versions" 'data["nix"]["installer_size"] = "4499"'
check_fails 1 "${E}nix.installer_size: invalid format '4499', expected positive-int"

pins_fresh
url=$(jq -r '.agent_tools."example-release".url' "$versions")
json_edit "$versions" 'data["agent_tools"]["example-release"]["minimum_version"] = "4.1.0"'
check_fails 2 \
  "${E}agent_tools.example-release.url: expected to contain '/v4.1.0/', found '$url'" \
  "${E}skills:release_tools.example-release.version: expected '4.1.0', found '4.0.0'"

pins_fresh
json_edit "$versions" 'data["agent_tools"]["example-release"]["source_revision"] = "abc"'
check_fails 2 \
  "${E}agent_tools.example-release.source_revision: invalid format 'abc', expected hex40" \
  "${E}skills:release_tools.example-release.source_revision: expected 'abc', found '$(jq -r '.release_tools."example-release".source_revision' "$skills")'"

# --- no-literal -----------------------------------------------------------------

pins_fresh
printf '# %s\n' "$url" >>"$inst/scripts/install-example.sh"
check_fails 1 "${E}scripts/install-example.sh: contains the literal value of agent_tools.example-release.url"

pins_fresh
printf '# %s\n' "$sri_b" >>"$inst/components/example-app/default.nix"
check_fails 1 "${E}components/example-app/default.nix: contains a literal matching sri ('$sri_b')"

pins_fresh
printf '# %s\n' "$sri_b" >>"$inst/flake.nix"
check_fails 1 "${E}flake.nix: contains a literal matching sri ('$sri_b')"

pins_fresh
json_edit "$versions" "data['agent_tools']['example-app']['source_nix_sha256'] = '$sri_fake'"
check_fails 1 "${E}versions.lock.json: contains a literal matching fake-hash ('$sri_fake')"

pins_fresh
json_edit "$skills" 'data["layout"]["note"] = "use lib.fakeHash first"'
check_fails 1 "${E}agent/skills.lock.json: contains a literal matching fake-hash ('lib.fakeHash')"

pins_fresh
printf '# lib.fakeHash\n' >>"$inst/home.nix"
check_fails 1 "${E}home.nix: contains a literal matching fake-hash ('lib.fakeHash')"

pins_fresh
printf '# %s\n' "$sri_fake" >>"$inst/components/example-app/default.nix"
check_fails 2 \
  "${E}components/example-app/default.nix: contains a literal matching sri ('$sri_fake')" \
  "${E}components/example-app/default.nix: contains a literal matching fake-hash ('$sri_fake')"

# --- npm-bundle -----------------------------------------------------------------

lock=$inst/packages/example-bundle/package-lock.json
cli_integrity=$(jq -r '.packages."node_modules/example-cli".integrity' "$pins_template/packages/example-bundle/package-lock.json")

pins_fresh
json_edit "$lock" 'data["packages"][""]["dependencies"]["example-cli"] = "1.9.0"'
check_fails 1 "${E}packages/example-bundle/package-lock.json root dependencies: expected {'example-cli': '2.0.0'}, found {'example-cli': '1.9.0'}"

pins_fresh
json_edit "$lock" 'data["lockfileVersion"] = 2'
check_fails 1 "${E}packages/example-bundle/package-lock.json lockfileVersion: expected 3, found 2"

pins_fresh
json_edit "$versions" 'data["agent_tools"]["example-cli"]["integrity"] = "sha512-example"'
check_fails 1 "${E}agent_tools.example-cli.integrity (package-lock): expected '$cli_integrity', found 'sha512-example'"

pins_fresh
json_edit "$versions" 'data["agent_tools"]["example-cli"]["node_engine"] = ">=18"'
check_fails 1 "${E}agent_tools.example-cli.node_engine (package-lock): expected '>=20', found '>=18'"

pins_fresh
json_edit "$lock" 'data["packages"]["node_modules/example-cli"]["integrity"] = "sha1-example"'
check_fails 2 \
  "${E}packages/example-bundle/package-lock.json example-cli.integrity: invalid format 'sha1-example', expected sha512" \
  "${E}agent_tools.example-cli.integrity (package-lock): expected 'sha1-example', found '$cli_integrity'"

pins_fresh
json_edit "$lock" 'data["packages"]["node_modules/example-cli"]["version"] = "2.0.1"'
check_fails 2 \
  "${E}packages/example-bundle/package-lock.json example-cli.version: expected '2.0.0', found '2.0.1'" \
  "${E}agent_tools.example-cli.version (package-lock): expected '2.0.0', found '2.0.1'"

pins_fresh
json_edit "$skills" 'data["npm_tools"]["example-cli"] = "1.9.0"'
check_fails 1 "${E}skills:npm_tools: expected {'example-cli': '2.0.0'}, found {'example-cli': '1.9.0'}"

pins_fresh
json_edit "$skills" 'data["npm_overrides"] = {}'
check_fails 1 "${E}skills:npm_overrides: expected {'example-cli': {'example-dep': '1.0.1'}}, found {}"

# A scoped security override reads its lock_path, not the root copy.
pins_fresh
json_edit "$versions" 'data["agent_tools"]["npm_security_overrides"]["example-dep"]["version"] = "1.0.2"'
check_fails 2 \
  "${E}agent_tools.npm_security_overrides.example-dep.version: expected '1.0.1', found '1.0.2'" \
  "${E}agent_tools.npm_security_overrides.example-dep.official_tag: expected 'v1.0.2', found 'v1.0.1'"

pins_fresh
json_edit "$versions" 'data["agent_tools"]["npm_bundle_nix_sha256"] = "sha256-short"'
check_fails 1 "${E}agent_tools.npm_bundle_nix_sha256: invalid format 'sha256-short', expected sri"

# --- skills-lock-mirror ---------------------------------------------------------

pins_fresh
json_edit "$skills" 'data["nix_tools"]["example-term"] = "1.1.0"'
check_fails 1 "${E}skills:nix_tools.example-term: expected '1.2.0', found '1.1.0'"

pins_fresh
plugin_rev=$(jq -r '.agent_tools."example-plugin".observed_revision' "$versions")
json_edit "$skills" "data['plugins'][1]['observed_revision'] = '$a40'"
check_fails 1 "${E}skills:plugins[spec=example-plugin@example-market].observed_revision: expected '$plugin_rev', found '$a40'"

# A list selector without a match is a group failure, not a traceback.
pins_fresh
json_edit "$skills" 'data["plugins"][1]["spec"] = "example-plugin@other-market"'
check_fails 1 "${E}example-plugin/skills-lock-mirror: missing or invalid lock field (KeyError('skills:plugins[spec=example-plugin@example-market].observed_revision'))"

# --- minimum-version ------------------------------------------------------------

pins_fresh
json_edit "$versions" 'm = data["example_policy"]["minimum_versions"]; m["example-cli"] = "2.1"; m["example-missing"] = "1.0"'
check_fails 2 \
  "${E}example_policy.minimum_versions.example-cli: expected at least '2.1', found '2.0.0'" \
  "${E}example_policy.minimum_versions.example-missing: expected at least '1.0', found None"

pins_fresh
json_edit "$versions" 'data["example_policy"]["minimum_versions"]["example-term"] = "1.10"'
check_fails 1 "${E}example_policy.minimum_versions.example-term: expected at least '1.10', found '1.2.0'"

# --- asset-digest ---------------------------------------------------------------

pins_fresh
asset_sha=$(jq -r '.assets.example.sha256' "$versions")
printf 'changed\n' >>"$inst/assets/example.txt"
changed_sha=$(sha256sum "$inst/assets/example.txt" | awk '{print $1}')
check_fails 1 "${E}assets.example.sha256: expected '$asset_sha', found '$changed_sha'"

pins_fresh
rm "$inst/assets/example.txt"
check_fails 1 "${E}assets.example.path: no such file 'assets/example.txt'"

pins_fresh
json_edit "$versions" 'data["assets"]["example"]["path"] = "../outside.txt"'
check_fails 1 "${E}assets.example.path: no such file '../outside.txt'"

# --- skill-digests --------------------------------------------------------------

pins_fresh
skill_sha=$(jq -r '.skills[0].skill_sha256' "$skills")
printf '\nChanged.\n' >>"$inst/agent/skills/example-skill/SKILL.md"
new_skill_sha=$(sha256sum "$inst/agent/skills/example-skill/SKILL.md" | awk '{print $1}')
new_dir_sha=$(lib_directory_sha256 "$inst/agent/skills/example-skill")
check_fails 2 \
  "${E}skills:skills[name=example-skill].skill_sha256: expected '$new_skill_sha', found '$skill_sha'" \
  "${E}skills:skills[name=example-skill].directory_sha256: expected '$new_dir_sha', found '$DS_FIXTURE_SKILL_TREE_SHA256'"

# Python bytecode is not part of the directory digest.
pins_fresh
printf 'bytecode' >"$inst/agent/skills/example-skill/references/extra.pyc"
mkdir -p "$inst/agent/skills/example-skill/references/__pycache__"
printf 'bytecode' >"$inst/agent/skills/example-skill/references/__pycache__/guide.cpython-312.pyc"
assert_exit 0 pins check

# Vendored skills (a pinned revision) keep their recorded digests.
pins_fresh
printf '\nChanged.\n' >>"$inst/agent/skills/example-vendored/SKILL.md"
assert_exit 0 pins check

pins_fresh
json_edit "$skills" 'data["skills"][1]["skill_sha256"] = "XYZ"'
check_fails 1 "${E}skills:skills[name=example-vendored].skill_sha256: invalid format 'XYZ', expected hex64"

pins_fresh
json_edit "$skills" "data['skills'].append({'name': 'dotsteward-example', 'directory': 'dotsteward-example', 'revision': '$a40', 'skill_sha256': '$(printf 'c%.0s' {1..64})'})"
check_fails 1 "${E}skills:skills[name=dotsteward-example]: dotsteward-* names are reserved for framework skills"

# [compat] repo_owned_revision adds an accepted repo-owned sentinel.
pins_fresh
json_edit "$skills" 'data["skills"][0]["revision"] = "same-as-example-checkout"'
printf '\nChanged.\n' >>"$inst/agent/skills/example-skill/SKILL.md"
assert_exit 0 pins check
printf '\n[compat]\nrepo_owned_revision = "same-as-example-checkout"\n' >>"$inst/workstation.toml"
assert_exit 1 pins check
assert_contains "$DS_STDERR" "${E}skills:skills[name=example-skill].skill_sha256: expected '"
