# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Framework skills sync check (SPEC 8.3 step 11, 9.4): every
# ~/<hm_root>/dotsteward-* entry, and every framework skill of the manifest,
# is a link that resolves to the generation's framework source
# (<generation>/home-files/<hm_root>/<name>), with the SKILL.md and
# directory digests of that source's skills/manifest.json. The generation
# is --generation, else the active one; without one, framework skill links
# cannot be verified. Unlike the agents check, which follows the manifest,
# a stale dotsteward-* link the generation does not carry is a finding.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

sync_findings() {
  jq -c '[.findings[] | select(.step == "core:framework-skills") | [.code, .path]]' <<<"$DS_STDOUT"
}

framework_skill dotsteward-maintain
framework_skill dotsteward-update
make_generation
publish_instance
skills=$HOME/.agents/skills

# Linked like Home Manager activation, but no active generation yet.
activate_framework_skills
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg root "$skills" '[["framework-skill-unverifiable", $root]]')" "$(sync_findings)"
assert_contains "$DS_STDOUT" "no Home Manager generation to verify the framework skills against; pass --generation"

# An explicit generation, then the active one.
assert_exit 0 run_agents install --generation "$agents_gen"
assert_exit 0 run_e2e --generation "$agents_gen"
activate_generation
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"

# A stale link left by an older framework the generation does not carry.
old=$DS_TEST_ROOT/old-framework/skills/dotsteward-legacy
make_skill "$old" dotsteward-legacy
ln -s "$old" "$skills/dotsteward-legacy"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-legacy" '[["framework-skill-not-in-generation", $path]]')" \
  "$(sync_findings)"
assert_contains "$DS_STDOUT" "the generation has no framework skill dotsteward-legacy: $skills/dotsteward-legacy"
rm "$skills/dotsteward-legacy"

# A plain directory with a framework name.
mkdir "$skills/dotsteward-local"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-local" '[["framework-skill-not-link", $path]]')" "$(sync_findings)"
rmdir "$skills/dotsteward-local"

# A link to another copy of the same skill.
copy=$DS_TEST_ROOT/copy/dotsteward-update
mkdir -p "$(dirname "$copy")"
cp -R "$agents_fw_source/skills/dotsteward-update" "$copy"
rm "$skills/dotsteward-update"
ln -s "$copy" "$skills/dotsteward-update"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-update" '[["framework-skill-foreign", $path]]')" "$(sync_findings)"
assert_contains "$DS_STDOUT" "framework skill does not resolve to the generation's framework source: $skills/dotsteward-update"
rm "$skills/dotsteward-update"

# A missing framework skill, then a broken link.
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-update" '[["framework-skill-missing", $path]]')" "$(sync_findings)"
ln -s "$DS_TEST_ROOT/gone" "$skills/dotsteward-update"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-update" '[["framework-skill-broken", $path]]')" "$(sync_findings)"
rm "$skills/dotsteward-update"
ln -s "$agents_gen/home-files/.agents/skills/dotsteward-update" "$skills/dotsteward-update"
assert_exit 0 run_e2e

# The source's bytes no longer match its skills/manifest.json.
printf 'changed\n' >>"$agents_fw_source/skills/dotsteward-maintain/references/guide.md"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg path "$skills/dotsteward-maintain" '[["framework-skill-digest-mismatch", $path]]')" \
  "$(sync_findings)"
assert_contains "$DS_STDOUT" "framework skill digest differs from $agents_fw_source/skills/manifest.json: dotsteward-maintain ($skills/dotsteward-maintain)"
assert_eq "" "$(temp_dirs)"
