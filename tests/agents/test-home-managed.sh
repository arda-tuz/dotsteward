# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Home-managed instance skills (lock deployment "home-manager"; SPEC 8.1;
# understanding report I-L6, test 7): Home Manager links
# ~/<hm_root>/<directory> before the installer runs; the installer never
# installs or refreshes them, it requires the link and the lock digest and
# then lays out the canonical entry and the link-root link like any skill.
# Both hm_root shapes: the framework default .agents/skills (the link is the
# canonical entry itself) and .codex/skills, a legacy root (entry
# ../../.codex/skills/<directory>).
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha --deployment home-manager
store_alpha=$agents_store/hm-alpha
cp -a "$(vendored alpha)" "$store_alpha"

# --- hm_root = .agents/skills (default) ------------------------------------
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "home-managed skill missing: alpha ($HOME/.agents/skills/alpha); Home Manager activation links it"
[[ ! -e $HOME/.claude/skills ]] || ds_fail "nothing is linked for a missing home-managed skill"

ln -s "$store_alpha" "$HOME/.agents/skills/alpha"
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/alpha" "$store_alpha"
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_exit 0 run_agents check

# A digest mismatch is fatal and never refreshed.
printf 'drift\n' >>"$store_alpha/references/guide.md"
store_before=$(cat "$store_alpha/references/guide.md")
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "home-managed skill digest differs from the lock: alpha ($HOME/.agents/skills/alpha)"
done
assert_eq "$store_before" "$(cat "$store_alpha/references/guide.md")"
[[ -z $(find "$DOTSTEWARD_STATE_ROOT" -path '*backups*' -name '*-skills' 2>/dev/null) ]] ||
  ds_fail "a home-managed skill is never backed up or refreshed"
rm -rf "$store_alpha"
cp -a "$(vendored alpha)" "$store_alpha"

# A physical directory is not a Home Manager link.
rm "$HOME/.agents/skills/alpha"
cp -a "$(vendored alpha)" "$HOME/.agents/skills/alpha"
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "home-managed skill is not a Home Manager link: alpha ($HOME/.agents/skills/alpha)"
done

# --- hm_root = .codex/skills (a legacy root) --------------------------------
rm -rf "$HOME/.agents" "$HOME/.claude" "$HOME/.codex"
set_hm_root .codex/skills
mkdir -p "$HOME/.codex/skills"
ln -s "$store_alpha" "$HOME/.codex/skills/alpha"
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/alpha" ../../.codex/skills/alpha
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_exit 0 run_agents check

rm "$HOME/.codex/skills/alpha"
cp -a "$store_alpha" "$HOME/.codex/skills/alpha"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "home-managed skill is not a Home Manager link: alpha ($HOME/.codex/skills/alpha)"
