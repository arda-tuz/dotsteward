# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Nothing is ever overwritten or repaired (SPEC 8.1; understanding report
# I-L5, I-S1, I-S2, tests 8 and 9): an excluded subtree (.system) in the
# canonical root, a real directory where a canonical entry or a link-root
# link belongs, a link-root link to another skill and a broken canonical
# entry are each fatal in both modes, name the path, and leave the home
# byte-identical.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha
lock_add beta
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills" "$HOME/.claude/skills"
cp -a "$(vendored alpha)" "$HOME/.codex/skills/alpha"
cp -a "$(vendored beta)" "$HOME/.agents/skills/beta"

# expect_refusal MESSAGE: both modes fail with MESSAGE and change nothing.
expect_refusal() {
  local before mode
  before=$(home_state)
  for mode in check install; do
    assert_exit 1 run_agents "$mode"
    assert_contains "$DS_STDERR" "$1"
    assert_eq "$before" "$(home_state)" "$mode leaves the home unchanged"
  done
}

# Codex system skills leaked into the canonical root, as a directory or a link.
mkdir "$HOME/.agents/skills/.system"
expect_refusal "excluded skill subtree present in the canonical skill root: $HOME/.agents/skills/.system"
rmdir "$HOME/.agents/skills/.system"
ln -s ../../.codex/skills/.system "$HOME/.agents/skills/.system"
expect_refusal "excluded skill subtree present in the canonical skill root: $HOME/.agents/skills/.system"
rm "$HOME/.agents/skills/.system"

# A real directory where the canonical entry of alpha belongs shadows the
# copy under the legacy root; it has no SKILL.md, so the legacy copy is the
# one found.
mkdir "$HOME/.agents/skills/alpha"
printf 'user data\n' >"$HOME/.agents/skills/alpha/notes.md"
expect_refusal "canonical skill path shadows an existing skill: $HOME/.agents/skills/alpha"
rm -rf "$HOME/.agents/skills/alpha"

# A broken canonical entry (the found skill is the legacy copy).
ln -s ../../.codex/skills/missing "$HOME/.agents/skills/alpha"
mv "$HOME/.codex/skills/alpha" "$HOME/.codex/skills/alpha-moved"
lock_edit '.skills |= map(if .name == "alpha" then .legacy_directory = "alpha-moved" else . end)'
ln -s ../../.codex/skills/missing "$HOME/.agents/skills/alpha-moved"
expect_refusal "broken canonical skill entry: $HOME/.agents/skills/alpha-moved"
rm "$HOME/.agents/skills/alpha-moved" "$HOME/.agents/skills/alpha"
mv "$HOME/.codex/skills/alpha-moved" "$HOME/.codex/skills/alpha"
lock_edit '.skills |= map(if .name == "alpha" then del(.legacy_directory) else . end)'

# A canonical entry that points to a directory without a skill: the legacy
# copy is found and its entry is never repaired.
mkdir -p "$DS_TEST_ROOT/empty"
ln -s "$DS_TEST_ROOT/empty" "$HOME/.agents/skills/alpha"
expect_refusal "canonical skill entry points to an unexpected target: $HOME/.agents/skills/alpha"
rm "$HOME/.agents/skills/alpha"

# The link-root cases need every earlier entry in place.
assert_exit 0 run_agents install
rm "$HOME/.claude/skills/beta"

# A real directory at the link-root path.
mkdir "$HOME/.claude/skills/beta"
expect_refusal "skill link path is not a symlink: $HOME/.claude/skills/beta"
rmdir "$HOME/.claude/skills/beta"

# A link-root link to another skill is never repaired.
ln -s ../../.agents/skills/alpha "$HOME/.claude/skills/beta"
expect_refusal "skill link points to an unexpected target: $HOME/.claude/skills/beta"
rm "$HOME/.claude/skills/beta"

# A broken link-root link: the sweep would remove it later, but the skill
# step comes first and refuses.
ln -s ../../.agents/skills/beta-old "$HOME/.claude/skills/beta"
expect_refusal "broken skill link: $HOME/.claude/skills/beta"
rm "$HOME/.claude/skills/beta"

# Without conflicts both modes pass.
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.claude/skills/beta" ../../.agents/skills/beta
assert_symlink_to "$HOME/.agents/skills/alpha" ../../.codex/skills/alpha
assert_exit 0 run_agents check
