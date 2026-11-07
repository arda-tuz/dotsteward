# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The end of a session publishes what that session wrote. Another session goes on writing,
# and its half done skill waits for the delay. A skill that waits for a retry does not take
# a fresh one along either.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

# --- two sessions -------------------------------------------------------------------------

start=$(remote_tip)
HOOK_SESSION=writing
new_skill a half
wrote a half
settle a half
HOOK_SESSION=unrelated
hook_on a SessionEnd session-end
assert_eq "" "$HOOK_OUT"
# What a wrong start would do takes a moment, and a settled skill lands at once.
sleep 4
assert_eq "$start" "$(remote_tip)" "another session leaves the skill alone"
assert_eq capture "$(item a half .state)"

# Two sessions wrote it: the first that ends leaves it to the other.
HOOK_SESSION=second
wrote a half
settle a half
HOOK_SESSION=writing
hook_on a SessionEnd session-end
sleep 4
assert_eq "$start" "$(remote_tip)" "the other session still writes"

# The last one that wrote ends: at once.
HOOK_SESSION=second
hook_on a SessionEnd session-end
for _ in $(seq 1 1500); do
  [[ $(remote_tip) != "$start" ]] && break
  sleep 0.1
done
assert_eq half "$(remote_entry half | jq -r .name)"

# --- a retry does not take a fresh skill along --------------------------------------------

mv "$remote" "$remote.away"
own_new a retried
settle a retried
EXPECT_STATUS=6 ds_code a skills capture --now
assert_eq offline "$(item a retried .reason)"
mv "$remote.away" "$remote"
HOOK_SESSION=third
new_skill a fresh
wrote a fresh
settle a fresh
rm -f "$(state_of a)/skills/deadline"
hook_on a Stop stop
for _ in $(seq 1 1500); do
  [[ $(remote_entry retried) != "{}" ]] && break
  sleep 0.1
done
assert_eq retried "$(remote_entry retried | jq -r .name)"
assert_eq "{}" "$(remote_entry fresh)"
assert_eq capture "$(item a fresh .state)"
# It has a deadline of its own, and something waits for it.
for _ in $(seq 1 300); do
  deadline=$(cut -d. -f1 "$(state_of a)/skills/deadline" 2>/dev/null || true)
  [[ -n $deadline && $deadline -gt $(($(date +%s) + 600)) ]] && break
  sleep 0.1
done
[[ -n $deadline && $deadline -gt $(($(date +%s) + 600)) ]] || ds_fail "the fresh skill keeps its delay: [$deadline]"
