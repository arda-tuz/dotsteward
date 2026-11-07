# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A question reaches the agent only in a session somebody attends, at most once
# per item in 24 hours and at most one Stop block per session, naming at most 10
# skills and never any of their content. Claude Code sets the signal; without it
# nothing is printed and the item waits. Codex gets no block; for its SessionStart
# the signal is the command line of the codex process above the hook, on Linux and on
# macOS alike: `codex exec` is nobody's session, and where the command line cannot be
# read nothing is said.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

install_hooks claude codex
attended=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)

# downloaded NAME: a skill a tool of no agent wrote: a question.
downloaded() {
  mkdir -p "$HOME/.agents/skills/$1"
  printf -- '---\nname: %s\n---\n\nSECRET-CONTENT-MARKER\n' "$1" >"$HOME/.agents/skills/$1/SKILL.md"
}

# age_items: makes every question 25 hours old.
age_items() {
  jq '.items |= map_values(if .last_asked then .last_asked -= 90000 else . end)' "$ss/pending.json" >"$ss/pending.tmp"
  mv -- "$ss/pending.tmp" "$ss/pending.json"
}

no_output() {
  assert_eq "" "$EVENT_OUT" "$1: no output"
}

downloaded foreign

# --- not attended: the item waits, nothing is said -------------------------------

for env_values in CLAUDE_CODE_SESSION_ATTENDED=0 "CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=cli" \
  CLAUDE_CODE_ENTRYPOINT=sdk-cli "CLAUDE_CODE_SESSION_ATTENDED=2" ""; do
  read -r -a AGENT_ENV <<<"$env_values"
  agent_event claude SessionStart session-start
  no_output "SessionStart with [$env_values]"
  agent_event claude Stop stop
  no_output "Stop with [$env_values]"
  assert_eq ask "$(pending_state foreign)"
done
assert_json "$ss/pending.json" '.items["skill:foreign"].origin == "unknown" and .items["skill:foreign"].last_asked == null'
[[ ! -d $ss/sessions ]] || [[ -z $(find "$ss/sessions" -mindepth 1) ]] || ds_fail "no block, no session mark"

# --- attended: SessionStart says it once in 24 hours --------------------------------

AGENT_ENV=("${attended[@]}")
agent_event claude SessionStart session-start
assert_json - '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$EVENT_OUT"
context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$EVENT_OUT")
assert_contains "$context" foreign
assert_contains "$context" "dotsteward skills track"
assert_contains "$context" "--all"
assert_contains "$context" "--here"
assert_contains "$context" "--never"
assert_contains "$context" "language"
assert_not_contains "$context" SECRET-CONTENT-MARKER
agent_event claude SessionStart session-start
no_output "the same item within 24 hours"
agent_event claude Stop stop
no_output "Stop within 24 hours of the question"
age_items
agent_event claude SessionStart session-start
assert_contains "$EVENT_OUT" foreign
age_items

# An entrypoint of cli without the attendance variable counts as attended, an
# explicit 0 never does (above).
AGENT_ENV=(CLAUDE_CODE_ENTRYPOINT=cli)
agent_event claude SessionStart session-start
assert_contains "$EVENT_OUT" foreign
age_items
AGENT_ENV=("${attended[@]}")

# --- Stop: one block per session, written after its mark ----------------------------

agent_event claude Stop stop
assert_json - '.decision == "block" and (.reason | contains("foreign"))' <<<"$EVENT_OUT"
assert_not_contains "$EVENT_OUT" SECRET-CONTENT-MARKER
[[ -e $ss/sessions/$session_id ]] || ds_fail "the session is marked"
agent_event claude Stop stop-active
no_output "stop_hook_active"
age_items
agent_event claude Stop stop
no_output "a second block in one session, even with an old question"
agent_event claude Stop stop-active
no_output "stop_hook_active stays quiet"
# A new session may ask again once the question is old.
EVENT_SESSION=fe058fc9-0000-4000-8000-000000000002
agent_event claude Stop stop
assert_contains "$EVENT_OUT" '"decision"'
unset EVENT_SESSION
age_items
# A session id that is no plain name is never used as a path.
EVENT_SESSION=../../evil
agent_event claude Stop stop
no_output "an odd session id"
[[ ! -e $state/evil ]] || ds_fail "the session id stays out of the path"
unset EVENT_SESSION

# --- Codex: no block, no text ---------------------------------------------------------

AGENT_ENV=()
age_items
agent_event codex Stop stop
no_output "Codex Stop"
# No codex process above the hook: nothing is said.
agent_event codex SessionStart session-start
no_output "Codex SessionStart without a codex process"

# fake_codex ARGUMENT NAME: runs the configured hook for NAME under a process with
# the command line `<dir>/codex ARGUMENT`, as Codex starts a hook through the shell
# of the user, and sets EVENT_OUT.
fake_codex() {
  local dir=$DS_TEST_ROOT/fake-codex text
  mkdir -p "$dir"
  text=$(hook_text codex SessionStart)
  printf 'sh -c %q\n' "$text" >"$dir/$1"
  EVENT_OUT=$(cd "$dir" && payload codex "$2" | (exec -a "$dir/codex" "$BASH" "$1"))
}
fake_codex exec session-start
no_output "codex exec is nobody's session"
fake_codex tui session-start-internal
no_output "an internal session of Codex without a transcript"
fake_codex tui session-start
assert_json - '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$EVENT_OUT"
assert_contains "$EVENT_OUT" foreign

# --- at most 10 names, odd names only in skills status -------------------------------

AGENT_ENV=("${attended[@]}")
rm -rf "$HOME/.agents/skills/foreign" "$ss/sessions" "$ss/pending.json"
for number in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
  downloaded "many-$number"
done
downloaded 'odd name'
agent_event claude SessionStart session-start
context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$EVENT_OUT")
assert_eq 10 "$(grep -o 'many-[0-9]*' <<<"$context" | sort -u | wc -l)" "ten names"
assert_contains "$context" "+4 more: dotsteward skills status"
assert_not_contains "$context" "odd name"
assert_exit 0 ds_cli skills status
assert_contains "$DS_STDOUT" "odd name"
assert_contains "$DS_STDOUT" "many-13"

# --- every state that waits for a person is said --------------------------------------

rm -rf "$HOME/.agents/skills"/* "$ss/sessions" "$ss/pending.json"
own_skill mine
jq -n --arg path "$HOME/.agents/skills/mine" '{
  schema_version: 1, reconciled_at: 4102444800,
  items: {
    "skill:one": {kind: "skill", name: "one", state: "conflict", origin: "own"},
    "skill:two": {kind: "skill", name: "two", state: "blocked", origin: "own", reason: "privacy"},
    "skill:three": {kind: "skill", name: "three", state: "name-taken", origin: "unknown"},
    "skill:four": {kind: "skill", name: "four", state: "deleted", origin: "own"},
    "skill:five": {kind: "skill", name: "five", state: "capture", origin: "own", reason: "offline", offline_since: 1000},
    "skill:six": {kind: "skill", name: "six", state: "capture", origin: "own", reason: "offline", offline_since: 4102444700},
    "plugin:seven": {kind: "plugin", name: "seven", state: "capture", origin: "own"}
  }}' >"$ss/pending.json"
agent_event claude SessionStart session-start
context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$EVENT_OUT")
for name in one two three four five; do
  assert_contains "$context" "$name"
done
assert_contains "$context" "dotsteward skills resolve"
assert_contains "$context" "dotsteward skills forget"
assert_contains "$context" "dotsteward skills restore"
assert_not_contains "$context" "six"
assert_not_contains "$context" "seven"
