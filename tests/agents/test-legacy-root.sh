# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The canonical layout with a legacy skill root (SPEC 8.1; understanding
# report I-L1, I-L2, test 2): skills already under ~/.codex/skills are never
# moved; ~/.agents/skills, once a link to the legacy root, is migrated to a
# physical directory by install only (check fails with the rebuild hint),
# and each skill gets the canonical entry ../../.codex/skills/<found dir>.
# A canonical root link to anything else, a broken one or a legacy root
# that is not a real directory is fatal in both modes, and nothing changes.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha
lock_add beta
mkdir -p "$HOME/.codex/skills" "$HOME/.agents"
cp -a "$(vendored alpha)" "$HOME/.codex/skills/alpha"
cp -a "$(vendored beta)" "$HOME/.codex/skills/beta"
ln -s "$HOME/.codex/skills" "$HOME/.agents/skills"

before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "canonical skill root is still a link to a legacy skill root: $HOME/.agents/skills; run 'dotsteward rebuild --profile workstation --switch' to migrate it"
assert_eq "$before" "$(home_state)"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "migrating the canonical skill root link to a directory: $HOME/.agents/skills"
[[ -d $HOME/.agents/skills && ! -L $HOME/.agents/skills ]] || ds_fail "the canonical root is a directory"
assert_symlink_to "$HOME/.agents/skills/alpha" ../../.codex/skills/alpha
assert_symlink_to "$HOME/.agents/skills/beta" ../../.codex/skills/beta
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_symlink_to "$HOME/.claude/skills/beta" ../../.agents/skills/beta
[[ -d $HOME/.codex/skills/alpha && ! -L $HOME/.codex/skills/alpha ]] || ds_fail "existing skills are not moved"
assert_exit 0 run_agents check

# A canonical root link elsewhere is never migrated.
rm -rf "$HOME/.agents/skills"
mkdir -p "$DS_TEST_ROOT/elsewhere"
ln -s "$DS_TEST_ROOT/elsewhere" "$HOME/.agents/skills"
before=$(home_state)
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "canonical skill root links to an unexpected target: $HOME/.agents/skills"
done
assert_eq "$before" "$(home_state)"

rm "$HOME/.agents/skills"
ln -s "$DS_TEST_ROOT/missing" "$HOME/.agents/skills"
before=$(home_state)
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "broken canonical skill root link: $HOME/.agents/skills"
done
assert_eq "$before" "$(home_state)"

# The canonical root as a regular file.
rm "$HOME/.agents/skills"
printf 'file\n' >"$HOME/.agents/skills"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "canonical skill root is not a directory: $HOME/.agents/skills"
rm "$HOME/.agents/skills"
mkdir "$HOME/.agents/skills"

# A legacy root that is a link is fatal in both modes.
mv "$HOME/.codex/skills" "$DS_TEST_ROOT/codex-skills"
ln -s "$DS_TEST_ROOT/codex-skills" "$HOME/.codex/skills"
before=$(home_state)
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "skill root is not a directory: $HOME/.codex/skills"
done
assert_eq "$before" "$(home_state)"
