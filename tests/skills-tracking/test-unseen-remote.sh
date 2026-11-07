# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What this machine has not seen on the remote is overwritten only by `resolve --ours`. An
# answer to "track it?" says that the skill is yours; it says nothing about the copy another
# machine published under that name, so it ends in a conflict, whichever answer it was.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)

# --- the same new skill on two machines, and the answer to the question ---------------------

new_skill a shared
printf 'from a\n' >>"$(home_of a)/.claude/skills/shared/SKILL.md"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a shared .state)"
own_new b shared
printf 'from b\n' >>"$(home_of b)/.claude/skills/shared/SKILL.md"
wrote b shared
settle b shared
ds_code b skills capture --now
tip=$(remote_tip)
settle a shared
EXPECT_STATUS=3 ds_code a skills track shared --own
assert_eq "$tip" "$(remote_tip)" "an answer does not overwrite the other machine"
assert_eq conflict "$(item a shared .state)"
assert_contains "$(remote_file agent/skills/shared/SKILL.md)" "from b"

# Only the answer that says so does.
ds_code a skills resolve shared --ours
assert_contains "$(remote_file agent/skills/shared/SKILL.md)" "from a"
assert_not_contains "$(remote_file agent/skills/shared/SKILL.md)" "from b"

# --- the same with a checkout that has the entry: no question was left to answer -------------

own_new b pulled
printf 'from b\n' >>"$(home_of b)/.claude/skills/pulled/SKILL.md"
wrote b pulled
settle b pulled
ds_code b skills capture --now
tip=$(remote_tip)
new_skill a pulled
printf 'from a\n' >>"$(home_of a)/.claude/skills/pulled/SKILL.md"
settle a pulled
git -C "$(clone_of a)" pull -q --ff-only
EXPECT_STATUS=3 ds_code a skills track pulled --own
assert_eq "$tip" "$(remote_tip)"
assert_eq conflict "$(item a pulled .state)"

# --- a conflict that waits: --all and --own do not settle it ----------------------------------

own_new a both
settle a both
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b "${install[@]}"
b_copy=$(home_of b)/.agents/skills/both
printf 'from b\n' >>"$b_copy/SKILL.md"
assert_exit 0 ds b skills reconcile --full
find "$b_copy" -exec touch -h -d '2001-01-01' {} +
ds_code b skills capture --now
tip=$(remote_tip)
printf 'from a\n' >>"$(home_of a)/.claude/skills/both/SKILL.md"
wrote a both
settle a both
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq conflict "$(item a both .state)"
for answer in --all --own; do
  EXPECT_STATUS=3 ds_code a skills track both "$answer"
  assert_eq "$tip" "$(remote_tip)" "track $answer is no resolve"
  assert_eq conflict "$(item a both .state)"
  assert_eq null "$(item a both .answer)"
done
assert_contains "$(remote_file agent/skills/both/SKILL.md)" "from b"
