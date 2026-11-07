# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A lock that cannot be read for a moment (a merge in progress, a clone being replaced)
# says nothing: no skill turns into a question because of it. A name that entered the lock
# is no question either, whoever put it there.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

install_hooks claude
lock_add third
cp -a "$(vendored third)" "$HOME/.agents/skills/third"
assert_exit 0 run_agents install
agent_event claude Stop stop
assert_eq none "$(pending_state third)"

good=$DS_TEST_ROOT/lock.good
cp -- "$agents_lock" "$good"
for broken in '<<<<<<< HEAD' '{"skills": "none"}' ''; do
  printf '%s\n' "$broken" >"$agents_lock"
  agent_event claude Stop stop
  assert_eq none "$(pending_state third)"
  agent_event claude SessionStart session-start
  assert_eq none "$(pending_state third)"
  agent_event claude PostToolUse post-tool-use-write "$HOME/.agents/skills/third/SKILL.md"
  assert_eq none "$(pending_state third)"
done
rm -f -- "$agents_lock"
agent_event claude Stop stop
assert_eq none "$(pending_state third)"
cp -- "$good" "$agents_lock"
agent_event claude Stop stop
assert_eq none "$(pending_state third)"

# A question that waits ends when the name is in the lock.
make_skill "$HOME/.agents/skills/shared" shared
agent_event claude Stop stop
assert_eq ask "$(pending_state shared)"
lock_add shared --revision "$own_revision"
agent_event claude Stop stop
assert_eq none "$(pending_state shared)"
# With the lock broken again it would stay, so it is not taken for new either.
make_skill "$HOME/.agents/skills/later" later
agent_event claude Stop stop
assert_eq ask "$(pending_state later)"
cp -- "$agents_lock" "$good"
printf 'broken\n' >"$agents_lock"
agent_event claude Stop stop
assert_eq ask "$(pending_state later)"
cp -- "$good" "$agents_lock"
