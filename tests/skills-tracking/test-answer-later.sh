# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The question of a session has an answer for "not now". An agent runs only what the
# question offers: a user who puts the question off must not end up with a decline in the
# host file. --later declines nothing, and no session asks about that skill again; status
# still lists it. A decline comes only from --never, and the item keeps that answer and
# when it was given. --all or --here later takes a decline back.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
agents_skills=$(home_of a)/.agents/skills
HOOK_ENV=(CLAUDE_CODE_ENTRYPOINT=cli)

downloaded() {
  mkdir -p "$agents_skills/$1"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n' "$1" >"$agents_skills/$1/SKILL.md"
  find "$agents_skills/$1" -exec touch -h -d '2001-01-01' {} +
}

# A session that ends: the Stop hook asks; the user says REPLY about SKILL, and the agent
# runs the command the question names for it. For "not now" that is the answer which puts
# it off; where the question offers none, the only answer that tracks nothing is --never,
# which is what an agent ran for "not now, I will see to it myself later".
session_ends() {
  local skill=$1 reply=$2 reason flag
  HOOK_SESSION=$3
  hook_on a Stop stop
  assert_json - '.decision == "block"' <<<"$HOOK_OUT"
  reason=$(jq -r .reason <<<"$HOOK_OUT")
  assert_contains "$reason" "$skill"
  case $reply in
    "not now")
      flag=--never
      [[ $reason != *--later* ]] || flag=--later
      ;;
    never) flag=--never ;;
  esac
  [[ $reason == *"$flag"* ]] || ds_fail "the question offers $flag"
  ds_code a skills track "$skill" "$flag"
}

# --- "not now": nothing is declined, and the sessions stop asking -------------------------------

downloaded put-off
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a put-off .state)"
tip=$(remote_tip)
session_ends put-off "not now" fe058fc9-0000-4000-8000-0000000000a1
assert_eq "$tip" "$(remote_tip)" "no commit for not now"
if git -C "$remote" cat-file -e refs/heads/main:hosts/a.toml 2>/dev/null; then
  assert_not_contains "$(remote_file hosts/a.toml)" put-off
fi
assert_eq ask "$(item a put-off .state)"
assert_json "$(state_of a)/skills/pending.json" '.items["skill:put-off"].answered
  | .answer == "later" and .state == "ask" and (.at | type) == "number"'
# A day later, a new session: no question about it.
age_field a skill:put-off last_asked 90000
HOOK_SESSION=fe058fc9-0000-4000-8000-0000000000a2
hook_on a SessionStart session-start
assert_not_contains "$HOOK_OUT" put-off
hook_on a Stop stop
assert_not_contains "$HOOK_OUT" put-off
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "skill:put-off: later"
assert_contains "$DS_STDOUT" "dotsteward skills track put-off"

# --- "never": declined, and the answer stays on the item -----------------------------------------

downloaded unwanted
assert_exit 0 ds a skills reconcile
before=$(date +%s)
session_ends unwanted never fe058fc9-0000-4000-8000-0000000000a3
assert_contains "$(remote_file hosts/a.toml)" unwanted
assert_eq "chore(skills): decline unwanted" "$(git -C "$remote" log -1 --format=%s refs/heads/main)"
assert_eq declined "$(item a unwanted .state)"
assert_eq never "$(item a unwanted .answered.answer)"
(($(item a unwanted '.answered.at | floor') >= before)) || ds_fail "the time of the answer is kept"
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "skill:unwanted: declined"
assert_contains "$DS_STDOUT" "--never"

# --- the way out: --here takes the decline back, and so does --all -------------------------------

ds_code a skills track unwanted --here --own
assert_not_contains "$(remote_file hosts/a.toml)" unwanted
assert_json - '.machines == ["a"]' <<<"$(remote_entry unwanted)"
assert_eq "{}" "$(item a unwanted .)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a unwanted .)"

downloaded unwanted-too
assert_exit 0 ds a skills reconcile
ds_code a skills track unwanted-too --never
assert_contains "$(remote_file hosts/a.toml)" unwanted-too
ds_code a skills track unwanted-too --all --own
assert_not_contains "$(remote_file hosts/a.toml)" unwanted-too
assert_eq null "$(remote_entry unwanted-too | jq -r '.machines // null')"

# The skill that was put off is answered like any other.
ds_code a skills track put-off --here --own
assert_json - '.machines == ["a"]' <<<"$(remote_entry put-off)"
assert_eq "{}" "$(item a put-off .)"
