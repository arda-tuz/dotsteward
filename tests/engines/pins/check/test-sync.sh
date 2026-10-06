# shellcheck shell=bash
# `dotsteward pins sync`: derived values are rewritten from their sources
# (flake.lock, derive rules, official tags, the npm bundle, skills-lock
# mirrors, repo-owned skill digests) with the exact serializer, in place and
# in key order; a second run is a no-op; generated_at changes only with the
# content, in each file's own format; versions first, then skills; nothing
# is created; --skill validation happens before any write; primary files are
# never touched; writes are atomic and keep the file mode.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
E='[pins] ERROR: '
b40=$(printf 'b%.0s' {1..40})
z64=$(printf '0%.0s' {1..64})

primary_digests() {
  (cd "$inst" && sha256sum flake.lock flake.nix packages/example-bundle/package.json \
    packages/example-bundle/package-lock.json home.nix)
}

# A green instance is already in sync: nothing is written.
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
cmp -s "$versions" "$pins_fixture/versions.lock.json" || ds_fail "versions lock rewritten"
cmp -s "$skills" "$pins_fixture/agent/skills.lock.json" || ds_fail "skills lock rewritten"

# Drift every derived value, then sync restores the fixture bytes.
primary_before=$(primary_digests)
json_edit "$versions" "
fi = data['flake_inputs']
fi['nixpkgs']['revision'] = '$b40'
fi['nixpkgs']['nar_hash'] = 'sha256-' + 'B' * 43 + '='
fi['example-term']['reference'] = 'github:example/example-term/v1.1.0'
fi['example-term']['version'] = '1.1.0'
np = data['nix_packages']
np['example-term']['expected'] = '0'
np['example-term']['official_tag'] = 'v0'
np['example-lint']['expected'] = '0'
at = data['agent_tools']
at['example-app']['official_tag'] = 'v0'
at['example-app']['model_data_url'] = 'https://example.invalid/stale.tgz'
at['example-cli']['version'] = '0'
at['example-cli']['integrity'] = 'sha512-stale'
at['example-cli']['node_engine'] = '>=0'
dep = at['npm_security_overrides']['example-dep']
dep['version'] = '0'
dep['integrity'] = 'sha512-stale'
dep['official_tag'] = 'v0'
"
json_edit "$skills" "
data['npm_tools'] = {}
data['npm_overrides'] = {}
rt = data['release_tools']['example-release']
for key in ('version', 'source_revision', 'url', 'sha256'):
    rt[key] = 'stale'
rt['size'] = 0
data['nix_tools']['example-term'] = '0'
data['plugins'][1]['observed_revision'] = '$b40'
data['skills'][0]['skill_sha256'] = '$z64'
data['skills'][0]['directory_sha256'] = '$z64'
"
chmod 0640 "$versions"
instance_files() {
  (cd "$inst" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
}
files_before=$(instance_files)
skills_mode=$(stat -c %a "$skills")
assert_exit 0 pins sync
assert_eq "[pins] Synced files: versions.lock.json, agent/skills.lock.json" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
diff <(without_generated "$pins_fixture/versions.lock.json") <(without_generated "$versions") >&2 ||
  ds_fail "versions lock differs from the fixture after sync"
diff <(without_generated "$pins_fixture/agent/skills.lock.json") <(without_generated "$skills") >&2 ||
  ds_fail "skills lock differs from the fixture after sync"
assert_eq "$primary_before" "$(primary_digests)" "sync touched a primary file"
assert_file_mode "$versions" 0640
assert_file_mode "$skills" "$skills_mode"
assert_eq "$files_before" "$(instance_files)" "sync created or removed files"

# generated_at: versions +00:00, skills Z, the same instant, only on change.
v_at=$(jq -r .generated_at "$versions")
s_at=$(jq -r .generated_at "$skills")
[[ $v_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]] || ds_fail "versions generated_at: $v_at"
[[ $s_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || ds_fail "skills generated_at: $s_at"
assert_eq "${v_at%+00:00}" "${s_at%Z}" "both files carry the same instant"
assert_eq '  "generated_at": "'"$v_at"'",' "$(sed -n 3p "$versions")" "generated_at stays in place"

# A second run is a no-op.
cp "$versions" "$DS_TEST_ROOT/versions.after"
cp "$skills" "$DS_TEST_ROOT/skills.after"
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
cmp -s "$versions" "$DS_TEST_ROOT/versions.after" || ds_fail "second sync changed the versions lock"
cmp -s "$skills" "$DS_TEST_ROOT/skills.after" || ds_fail "second sync changed the skills lock"
assert_exit 0 pins check

# Only the changed file is written.
pins_fresh
json_edit "$skills" 'data["nix_tools"]["example-term"] = "0"'
assert_exit 0 pins sync
assert_eq "[pins] Synced files: agent/skills.lock.json" "$DS_STDOUT"
cmp -s "$versions" "$pins_fixture/versions.lock.json" || ds_fail "versions lock rewritten"
assert_eq '"1.2.0"' "$(json_get "$skills" '.nix_tools."example-term"')"

pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-term"]["official_tag"] = "v0"'
assert_exit 0 pins sync
assert_eq "[pins] Synced files: versions.lock.json" "$DS_STDOUT"
cmp -s "$skills" "$pins_fixture/agent/skills.lock.json" || ds_fail "skills lock rewritten"

# Non-ASCII text survives the serializer unescaped.
pins_fresh
json_edit "$versions" 'data["nix_packages"]["example-shell"]["notes"] = "caf" + chr(0xe9)'
cp "$versions" "$DS_TEST_ROOT/versions.unicode"
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
json_edit "$versions" 'data["nix_packages"]["example-term"]["official_tag"] = "v0"'
assert_exit 0 pins sync
diff <(without_generated "$DS_TEST_ROOT/versions.unicode") <(without_generated "$versions") >&2 ||
  ds_fail "unicode text changed"
assert_eq 1 "$(grep -c $'caf\xc3\xa9' "$versions")"

# --skill: names are validated before any write.
pins_fresh
json_edit "$skills" 'data["nix_tools"]["example-term"] = "0"'
cp "$skills" "$DS_TEST_ROOT/skills.drift"
assert_exit 1 pins sync --skill example-missing --skill example-other
assert_eq "${E}skill not in lock: example-missing, example-other" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
cmp -s "$skills" "$DS_TEST_ROOT/skills.drift" || ds_fail "skills lock written despite an unknown skill"
cmp -s "$versions" "$pins_fixture/versions.lock.json" || ds_fail "versions lock written despite an unknown skill"

# --skill refreshes a vendored skill's digests; without it they stay.
pins_fresh
vendored=$inst/agent/skills/example-vendored
printf '\nLocal change.\n' >>"$vendored/SKILL.md"
printf 'extra\n' >"$vendored/references/extra.md"
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_exit 0 pins sync --skill example-vendored
assert_eq "[pins] Synced files: agent/skills.lock.json" "$DS_STDOUT"
assert_eq "\"$(sha256sum "$vendored/SKILL.md" | awk '{print $1}')\"" "$(json_get "$skills" '.skills[1].skill_sha256')"
assert_eq "\"$(lib_directory_sha256 "$vendored")\"" "$(json_get "$skills" '.skills[1].directory_sha256')"

# directory_sha256 is written only where the entry has it.
pins_fresh
json_edit "$skills" 'del data["skills"][0]["directory_sha256"]'
printf '\nLocal change.\n' >>"$inst/agent/skills/example-skill/SKILL.md"
assert_exit 0 pins sync
assert_eq "\"$(sha256sum "$inst/agent/skills/example-skill/SKILL.md" | awk '{print $1}')\"" \
  "$(json_get "$skills" '.skills[0].skill_sha256')"
assert_eq 'false' "$(json_get "$skills" '.skills[0] | has("directory_sha256")')"

# Sync never creates entries: a derived target whose parent is missing is
# an error, and nothing is written.
pins_fresh
json_edit "$versions" 'data["example_policy"]["exact_versions"]["example-absent"] = "1.0"; data["nix_packages"]["example-term"]["official_tag"] = "v0"'
cp "$versions" "$DS_TEST_ROOT/versions.absent"
assert_exit 1 pins sync
assert_contains "$DS_STDERR" "${E}example-policy/derive: missing or invalid lock field (KeyError('nix_packages.example-absent.expected'))"
assert_not_contains "$DS_STDERR" "Traceback"
assert_eq "" "$DS_STDOUT"
cmp -s "$versions" "$DS_TEST_ROOT/versions.absent" || ds_fail "versions lock written despite an error"

# flake inputs: version and nar_hash are written only where they exist.
pins_fresh
json_edit "$versions" 'del data["flake_inputs"]["nixpkgs"]["nar_hash"]; data["flake_inputs"]["nixpkgs"]["revision"] = "0"'
assert_exit 0 pins sync
assert_eq 'false' "$(json_get "$versions" '.flake_inputs.nixpkgs | has("version")')"
assert_eq 'false' "$(json_get "$versions" '.flake_inputs.nixpkgs | has("nar_hash")')"
assert_eq "$(json_get "$pins_fixture/versions.lock.json" '.flake_inputs.nixpkgs.revision')" \
  "$(json_get "$versions" '.flake_inputs.nixpkgs.revision')"

# Sync does not fix check-only rules (download pins, text guards, minimum
# versions, asset digests): check still reports them.
pins_fresh
json_edit "$versions" 'data["desktop_packages"]["example-desktop"]["size"] = 0'
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_exit 1 pins check
