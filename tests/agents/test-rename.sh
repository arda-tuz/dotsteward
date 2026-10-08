# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A renamed home-managed skill: after activation drops the old
# ~/.codex/skills/<old> link and adds the new one, install creates the new
# canonical entry and link-root link first and the sweep then removes
# ~/.agents/skills/<old> (now dangling) and ~/.claude/skills/<old> (dangling
# once the first is gone). check passes afterwards.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

set_hm_root .codex/skills
lock_add old-skill --deployment home-manager
mkdir -p "$HOME/.codex/skills"
cp -a "$(vendored old-skill)" "$agents_store/old-skill"
ln -s "$agents_store/old-skill" "$HOME/.codex/skills/old-skill"
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/old-skill" ../../.codex/skills/old-skill
assert_symlink_to "$HOME/.claude/skills/old-skill" ../../.agents/skills/old-skill

# The lock renames the skill; activation swaps the Home Manager links.
lock_edit '.skills = []'
lock_add new-skill --deployment home-manager
cp -a "$(vendored new-skill)" "$agents_store/new-skill"
rm "$HOME/.codex/skills/old-skill"
ln -s "$agents_store/new-skill" "$HOME/.codex/skills/new-skill"

assert_exit 1 run_agents check --keep-going --json
assert_json - '[.findings[].code] == ["entry-missing", "dangling-link", "dangling-link"]' <<<"$DS_STDOUT"

assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/new-skill" ../../.codex/skills/new-skill
assert_symlink_to "$HOME/.claude/skills/new-skill" ../../.agents/skills/new-skill
assert_contains "$DS_STDOUT" "removed dangling skill link: $HOME/.agents/skills/old-skill"
assert_contains "$DS_STDOUT" "removed dangling skill link: $HOME/.claude/skills/old-skill"
[[ ! -L $HOME/.agents/skills/old-skill && ! -L $HOME/.claude/skills/old-skill ]] || ds_fail "old links are swept"
assert_exit 0 run_agents check
