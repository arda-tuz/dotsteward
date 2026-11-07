# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# One sleeper and a deadline file: three writes in a row mean one sleeper and one
# capture run, after the last write plus the delay. SessionEnd runs at once. A
# killed sleeper leaves pending.json, and the next hook sets it going again.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

own_skill alpha
install_hooks claude
AGENT_ENV=(DOTSTEWARD_CAPTURE_DELAY=15)
skill=$HOME/.agents/skills/alpha/SKILL.md

# --- three writes, one sleeper, one run --------------------------------------------

for round in 1 2 3; do
  printf 'change %s\n' "$round" >>"$skill"
  agent_event claude PostToolUse post-tool-use-write "$skill"
  assert_eq "" "$EVENT_OUT"
  assert_eq capture "$(pending_state alpha)"
done
last_write=$(date +%s)
deadline=$(cut -d. -f1 "$ss/deadline")
((deadline >= last_write)) || ds_fail "the deadline moves with every write"
wait_for "$ss/capture.log" ' run$'
ran_at=$(date +%s)
((ran_at >= deadline)) || ds_fail "the run waits for the deadline ($ran_at, $deadline)"
wait_for "$ss/capture.log" ' sleeper end$'
assert_eq 1 "$(capture_runs)" "one run"
assert_eq 1 "$(grep -c ' sleeper start$' "$ss/capture.log")" "one sleeper"
[[ ! -e $ss/deadline ]] || ds_fail "the sleeper clears a deadline it served"

# --- SessionEnd: at once, whatever the delay ------------------------------------------

AGENT_ENV=(DOTSTEWARD_CAPTURE_DELAY=600)
printf 'change 4\n' >>"$skill"
agent_event claude PostToolUse post-tool-use-edit "$skill"
assert_eq capture "$(pending_state alpha)"
agent_event claude SessionEnd session-end
assert_eq "" "$EVENT_OUT"
wait_captures 1
(($(capture_runs) >= 2)) || ds_fail "SessionEnd runs the capture at once"
# A sleeper that was waiting finds nothing left to wait for, or ends on its own.
_kill_sleepers
rm -f "$ss/capture.log" "$ss/deadline"

# --- a killed sleeper: the next hook goes on where it stopped ----------------------------

AGENT_ENV=(DOTSTEWARD_CAPTURE_DELAY=600)
printf 'change 5\n' >>"$skill"
agent_event claude PostToolUse post-tool-use-write "$skill"
wait_for "$ss/capture.log" ' sleeper start$'
_kill_sleepers
sleep 0.2
assert_eq capture "$(pending_state alpha)"
[[ -f $ss/deadline ]] || ds_fail "the deadline stays"
assert_eq 0 "$(capture_runs)"
printf '1000\n' >"$ss/deadline"
agent_event claude Stop stop
wait_for "$ss/capture.log" ' run$'
assert_eq 1 "$(capture_runs)"
wait_for "$ss/capture.log" ' sleeper end$'

# --- a change through Bash at Stop moves the deadline of a sleeper too --------------------

_kill_sleepers
rm -f "$ss/capture.log" "$ss/deadline"
AGENT_ENV=(DOTSTEWARD_CAPTURE_DELAY=600)
printf 'change 6\n' >>"$skill"
agent_event claude PostToolUse post-tool-use-write "$skill"
wait_for "$ss/capture.log" ' sleeper start$'
printf '%s\n' "$(($(date +%s) + 100))" >"$ss/deadline"
early=$(cut -d. -f1 "$ss/deadline")
printf 'change 7, through a shell\n' >>"$skill"
touch -d '+2 seconds' "$skill"
agent_event claude Stop stop
later=$(cut -d. -f1 "$ss/deadline")
((later > early)) || ds_fail "the deadline stays where it was: $later, $early"
_kill_sleepers

# --- SessionEnd with nothing to do starts nothing ---------------------------------------

cp -a "$(vendored alpha)/SKILL.md" "$skill"
rm -f "$ss/capture.log" "$ss/deadline" "$ss/pending.json"
agent_event claude SessionStart session-start
agent_event claude SessionEnd session-end
sleep 0.5
[[ ! -e $ss/capture.log ]] || ds_fail "nothing to do, nothing started"
