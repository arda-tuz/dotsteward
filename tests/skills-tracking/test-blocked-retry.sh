# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A skill kept back for a reason that lies outside its content does not stay back for ever.
# A refusal of the remote is told, with what the remote said and the command that tries
# again; nothing tries by itself. A red check belongs to a tree: a new tip gets a new try,
# the same tip costs no second run of the checks.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

# --- the remote refuses -------------------------------------------------------------------

printf '#!/bin/sh\necho "policy says no to this branch" >&2\nexit 1\n' >"$remote/hooks/pre-receive"
chmod 0755 "$remote/hooks/pre-receive"
start=$(remote_tip)
own_new a r1
settle a r1
EXPECT_STATUS=1 ds_code a skills capture --now
assert_eq blocked "$(item a r1 .state)"
assert_eq remote-refused "$(item a r1 .reason)"
ds_code a skills status
assert_contains "$DS_STDOUT" "skill:r1: blocked"
assert_contains "$DS_STDOUT" "remote-refused"
assert_contains "$DS_STDOUT" "policy says no to this branch"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
assert_contains "$HOOK_OUT" "dotsteward skills retry"
HOOK_ENV=()
assert_contains "$(cat "$DS_REPO_ROOT/docs/skill-tracking.md")" "dotsteward skills retry"

# The remote is fine again. Nothing tries by itself: a person should hear of a refusal.
rm -f "$remote/hooks/pre-receive"
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$start" "$(remote_tip)"
assert_eq blocked "$(item a r1 .state)"
# The command does.
ds_code a skills retry r1
assert_eq r1 "$(remote_entry r1 | jq -r .name)"
assert_eq "{}" "$(item a r1 .)"
EXPECT_STATUS=1 ds_code a skills retry r1
assert_contains "$DS_STDERR" "r1 is not kept back"

# --- a red check belongs to a tree --------------------------------------------------------

# The launcher of the tree says no to static, as a broken script of the instance would.
checks=$DS_TEST_ROOT/checks
elsewhere=$DS_TEST_ROOT/elsewhere
git clone -q "$remote" "$elsewhere"
cat >"$elsewhere/.dotsteward/cli.sh" <<LAUNCHER
#!/bin/sh
printf '%s\n' "\$*" >>"$checks"
case "\$1 \$2" in
  "static --only") exit 0 ;;
  "static "*) echo "[dotsteward] ERROR: a script of the instance is broken" >&2; exit 1 ;;
esac
exit 0
LAUNCHER
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "chore: a broken tree"
git -C "$elsewhere" push -q origin main
start=$(remote_tip)
own_new a r2
settle a r2
EXPECT_STATUS=1 ds_code a skills capture --now
assert_eq blocked "$(item a r2 .state)"
assert_eq checks-red "$(item a r2 .reason)"
assert_eq "$start" "$(item a r2 .blocked_tip)"
ds_code a skills status
assert_contains "$DS_STDOUT" "checks-red"

# The same tip: another look costs a fetch and no run of the checks, and tells nothing.
: >"$checks"
notifications=$(notified | wc -l)
assert_exit 0 ds a skills reconcile --full
assert_eq capture "$(item a r2 .state)"
ds_code a skills capture --now
assert_eq blocked "$(item a r2 .state)"
assert_eq "" "$(cat "$checks")"
assert_eq "$notifications" "$(notified | wc -l)"

# A plain look does not try again within hours, and does after them.
assert_exit 0 ds a skills reconcile
assert_eq blocked "$(item a r2 .state)"
age_field a skill:r2 blocked_at 86400
assert_exit 0 ds a skills reconcile
assert_eq capture "$(item a r2 .state)"
ds_code a skills capture --now
assert_eq blocked "$(item a r2 .state)"

# The tree is repaired on the remote: the next look takes the skill out.
git -C "$elsewhere" rm -q .dotsteward/cli.sh
git -C "$elsewhere" commit -q -m "fix: the tree"
git -C "$elsewhere" push -q origin main
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq r2 "$(remote_entry r2 | jq -r .name)"
assert_eq "{}" "$(item a r2 .)"
