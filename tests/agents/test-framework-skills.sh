# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Framework skills: the manifest's skills.framework entries,
# with digests from skills.framework_manifest, are verified before the
# instance lock entries: ~/<hm_root>/<name> must be a Home Manager link that
# resolves to the generation's framework source (the generation's
# home-files/<hm_root>/<name>), and the SKILL.md and directory digests must
# equal the framework skills manifest. They are never installed or
# refreshed; they get the canonical entry and the link-root links like any
# skill. Without --generation the active Home Manager generation
# (<XDG state>/home-manager/gcroots/current-home) is used; with no
# generation at all the check fails. An instance lock entry named like a
# framework skill is refused.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

framework_skill dotsteward-maintain
framework_skill dotsteward-update
lock_add alpha
make_generation

# --- hm_root = .agents/skills (default) ------------------------------------
assert_exit 1 run_agents install --generation "$agents_gen"
assert_contains "$DS_STDERR" "framework skill missing: dotsteward-maintain ($HOME/.agents/skills/dotsteward-maintain); Home Manager activation links it"
[[ ! -e $HOME/.agents/skills/alpha ]] || ds_fail "framework skills are verified before the instance skills"

activate_framework_skills
assert_exit 0 run_agents install --generation "$agents_gen"
assert_symlink_to "$HOME/.claude/skills/dotsteward-maintain" ../../.agents/skills/dotsteward-maintain
assert_symlink_to "$HOME/.claude/skills/dotsteward-update" ../../.agents/skills/dotsteward-update
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_exit 0 run_agents check --generation "$agents_gen"

# No generation: the framework skills cannot be verified.
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "no Home Manager generation to verify framework skill dotsteward-maintain against; pass --generation"
# The active generation is found through the Home Manager gcroot.
mkdir -p "$HOME/.local/state/home-manager/gcroots"
ln -s "$agents_gen" "$HOME/.local/state/home-manager/gcroots/current-home"
assert_exit 0 run_agents check
rm "$HOME/.local/state/home-manager/gcroots/current-home"

# A link to another copy with the same bytes is not the generation's source.
other=$agents_store/other-source/dotsteward-update
mkdir -p "${other%/*}"
cp -a "$agents_fw_source/skills/dotsteward-update" "$other"
rm "$HOME/.agents/skills/dotsteward-update"
ln -s "$other" "$HOME/.agents/skills/dotsteward-update"
before=$(home_state)
for mode in check install; do
  assert_exit 1 run_agents "$mode" --generation "$agents_gen"
  assert_contains "$DS_STDERR" "framework skill does not resolve to the generation's framework source: $HOME/.agents/skills/dotsteward-update"
done
assert_eq "$before" "$(home_state)"
rm "$HOME/.agents/skills/dotsteward-update"
ln -s "$agents_gen/home-files/.agents/skills/dotsteward-update" "$HOME/.agents/skills/dotsteward-update"

# Digests come from the framework skills manifest; never refreshed.
printf 'changed\n' >>"$agents_fw_source/skills/dotsteward-update/references/guide.md"
for mode in check install; do
  assert_exit 1 run_agents "$mode" --generation "$agents_gen"
  assert_contains "$DS_STDERR" "framework skill digest differs from the framework skills manifest: dotsteward-update ($HOME/.agents/skills/dotsteward-update)"
done
assert_contains "$(cat "$agents_fw_source/skills/dotsteward-update/references/guide.md")" changed
bash "$DS_REPO_ROOT/tools/gen-skills-manifest.sh" --root "$agents_fw_source" >/dev/null
manifest_edit '.skills.framework_manifest = $m' --argjson m "$(<"$agents_fw_source/skills/manifest.json")"
make_generation
assert_exit 0 run_agents check --generation "$agents_gen"

# A physical directory or a broken link instead of the Home Manager link.
rm "$HOME/.agents/skills/dotsteward-update"
cp -a "$agents_fw_source/skills/dotsteward-update" "$HOME/.agents/skills/dotsteward-update"
assert_exit 1 run_agents check --generation "$agents_gen"
assert_contains "$DS_STDERR" "framework skill is not a Home Manager link: $HOME/.agents/skills/dotsteward-update"
rm -rf "$HOME/.agents/skills/dotsteward-update"
ln -s "$DS_TEST_ROOT/missing" "$HOME/.agents/skills/dotsteward-update"
assert_exit 1 run_agents check --generation "$agents_gen"
assert_contains "$DS_STDERR" "broken framework skill link: $HOME/.agents/skills/dotsteward-update"
rm "$HOME/.agents/skills/dotsteward-update"
ln -s "$agents_gen/home-files/.agents/skills/dotsteward-update" "$HOME/.agents/skills/dotsteward-update"

# A framework skill missing from the framework skills manifest.
manifest_edit '.skills.framework += ["dotsteward-contribute"]'
make_generation
assert_exit 1 run_agents check --generation "$agents_gen"
assert_contains "$DS_STDERR" "framework skill dotsteward-contribute is not in the framework skills manifest"
manifest_edit '.skills.framework -= ["dotsteward-contribute"]'
make_generation

# An instance lock entry named like a framework skill.
lock_add dotsteward-extra
assert_exit 1 run_agents check --generation "$agents_gen"
assert_contains "$DS_STDERR" "the instance skills lock lists dotsteward-extra; dotsteward-* names belong to the framework"
lock_edit '.skills |= map(select(.name != "dotsteward-extra"))'

# --- hm_root = .codex/skills (a legacy root) --------------------------------
rm -rf "$HOME/.agents" "$HOME/.claude" "$HOME/.codex"
set_hm_root .codex/skills
make_generation
activate_framework_skills
assert_exit 0 run_agents install --generation "$agents_gen"
assert_symlink_to "$HOME/.agents/skills/dotsteward-maintain" ../../.codex/skills/dotsteward-maintain
assert_symlink_to "$HOME/.claude/skills/dotsteward-maintain" ../../.agents/skills/dotsteward-maintain
assert_exit 0 run_agents check --generation "$agents_gen"
