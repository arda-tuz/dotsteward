# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Refresh of a drifted copy-deployed skill (SPEC 8.1; understanding report
# I-S4, I-S5, tests 5 and 6): check fails with the rebuild hint; install
# backs the whole directory up to <state>/backups/<UTC>-skills/files/<abs
# real path> (backup root 0700), stages the vendored copy in
# <state>/staging, keeps the directory mode, replaces the content and
# re-verifies the digest. Unlocked skills are never touched; a drifted
# skill outside the managed roots only gets a warning.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

state=$DS_TEST_ROOT/state
export DOTSTEWARD_STATE_ROOT=$state
lock_add alpha --tree
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
installed=$HOME/.codex/skills/alpha
cp -a "$(vendored alpha)" "$installed"
chmod 0750 "$installed"
printf 'local change\n' >>"$installed/references/guide.md"
printf 'stray\n' >"$installed/stray.md"
# An unlocked sibling skill stays as it is.
make_skill "$HOME/.codex/skills/unlocked" unlocked
printf 'edited\n' >>"$HOME/.codex/skills/unlocked/SKILL.md"
unlocked_before=$(cd "$HOME/.codex/skills/unlocked" && find . -printf '%p %m\n' | LC_ALL=C sort && cat SKILL.md)

mkdir -p "$HOME/.claude/skills"
ln -s ../../.codex/skills/alpha "$HOME/.agents/skills/alpha"
ln -s ../../.agents/skills/alpha "$HOME/.claude/skills/alpha"
before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "installed skill differs from the lock: alpha ($installed); run 'dotsteward rebuild --profile workstation --switch' to back it up and refresh it"
assert_eq "$before" "$(home_state)"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "skill differed from the lock; backed up and refreshed: alpha (backup: $state/backups/"
backup_root=$(find "$state/backups" -mindepth 1 -maxdepth 1 -name '*-skills' | LC_ALL=C sort | tail -n 1)
[[ ${backup_root##*/} =~ ^[0-9]{8}T[0-9]{6}Z-skills$ ]] || ds_fail "backup root name: $backup_root"
assert_file_mode "$backup_root" 0700
assert_contains "$(cat "$backup_root/files$installed/references/guide.md")" "local change"
[[ -f $backup_root/files$installed/stray.md ]] || ds_fail "the whole directory is backed up"
assert_file_mode "$installed" 0750
[[ ! -e $installed/stray.md ]] || ds_fail "the content is replaced"
assert_eq "$(cat "$installed/references/guide.md")" "$(cat "$(vendored alpha)/references/guide.md")"
assert_file_mode "$state/staging" 0700
[[ -z $(find "$state/staging" -mindepth 1) ]] || ds_fail "nothing is left in the staging directory"
assert_eq "$unlocked_before" "$(cd "$HOME/.codex/skills/unlocked" && find . -printf '%p %m\n' | LC_ALL=C sort && cat SKILL.md)"
assert_exit 0 run_agents check

# A drifted skill outside the managed roots: warning, untouched, success.
outside=$DS_TEST_ROOT/outside/alpha
mkdir -p "${outside%/*}"
cp -a "$installed" "$outside"
printf 'outside change\n' >>"$outside/SKILL.md"
rm -rf "$installed"
ln -s "$outside" "$installed"
outside_before=$(cd "$outside" && find . -printf '%p %m\n' | LC_ALL=C sort && cat SKILL.md)
assert_exit 0 run_agents install
assert_contains "$DS_STDERR" "[dotsteward] WARNING: skill outside the managed skill roots not refreshed: alpha ($outside)"
assert_eq "$outside_before" "$(cd "$outside" && find . -printf '%p %m\n' | LC_ALL=C sort && cat SKILL.md)"
# check still reports the drift.
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "installed skill differs from the lock: alpha ($outside)"
