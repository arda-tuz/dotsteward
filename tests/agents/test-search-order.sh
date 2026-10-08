# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Where an installed skill is found: roots in order canonical
# (~/.agents/skills), then the legacy roots; inside a root the lock's directory
# before its legacy_directory. The canonical entry is named after the directory
# that was found, the link-root link after the lock name: a skill found as
# ~/.codex/skills/alpha-skill gets ~/.agents/skills/alpha-skill ->
# ../../.codex/skills/alpha-skill and ~/.claude/skills/alpha ->
# ../../.agents/skills/alpha-skill.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha --legacy alpha-skill
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
cp -a "$(vendored alpha)" "$HOME/.codex/skills/alpha-skill"

assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/alpha-skill" ../../.codex/skills/alpha-skill
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha-skill
[[ ! -e $HOME/.agents/skills/alpha ]] || ds_fail "no second copy is installed"
assert_exit 0 run_agents check

# The lock directory wins over the legacy directory, and the canonical root
# over the legacy root: a copy at ~/.agents/skills/alpha is found first.
rm -rf "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
cp -a "$(vendored alpha)" "$HOME/.codex/skills/alpha"
cp -a "$(vendored alpha)" "$HOME/.codex/skills/alpha-skill"
cp -a "$(vendored alpha)" "$HOME/.agents/skills/alpha-skill"
assert_exit 0 run_agents install
# The canonical root holds alpha-skill, found before ~/.codex/skills/alpha.
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha-skill
[[ ! -e $HOME/.agents/skills/alpha ]] || ds_fail "the canonical root wins over the legacy root"

# Inside one root the directory wins.
rm -rf "$HOME/.agents/skills" "$HOME/.claude/skills"
mkdir -p "$HOME/.agents/skills"
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.agents/skills/alpha" ../../.codex/skills/alpha
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
[[ ! -e $HOME/.agents/skills/alpha-skill ]] || ds_fail "the directory wins over the legacy directory"
assert_exit 0 run_agents check
