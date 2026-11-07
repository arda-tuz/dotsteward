# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A directory copied from a skill keeps its `name` until somebody changes it. The copy is
# another skill: it never lands on the skill whose name it carries, so the repository and
# the other machines keep what they have. It waits for a rename, and then lands by itself.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

own_new a foo
settle a foo
ds_code a skills capture --now
original=$(remote_file agent/skills/foo/SKILL.md)
digest=$(remote_entry foo | jq -r .directory_sha256)
tip=$(remote_tip)

# A file tool wrote into the copy, so it is an own skill and nobody is asked first.
cp -a "$root/foo" "$root/foo-copy"
printf 'the text of the copy\n' >>"$root/foo-copy/SKILL.md"
wrote a foo-copy
settle a foo-copy
EXPECT_STATUS=3 ds_code a skills capture --now --json
assert_json - '.captured == [] and .conflicts == ["foo-copy"]' <<<"$DS_STDOUT"
assert_eq "$tip" "$(remote_tip)" "no commit"
assert_eq "$original" "$(remote_file agent/skills/foo/SKILL.md)"
assert_eq "$digest" "$(remote_entry foo | jq -r .directory_sha256)"
assert_eq name-taken "$(item a foo-copy .state)"
assert_eq "$root/foo" "$(jq -r '.["skill:foo"].local_path' "$(state_of a)/skills/base.json")"

# It stays that way, whatever looks at it again.
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "no commit on a second look"
assert_eq name-taken "$(item a foo-copy .state)"
assert_eq "$digest" "$(remote_entry foo | jq -r .directory_sha256)"

# Somebody who attends the session hears of it once, and what to do.
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
assert_contains "$HOOK_OUT" "foo-copy"
assert_contains "$HOOK_OUT" "rename"
HOOK_ENV=()

# Renamed, through a shell or a tool, it is a skill of its own.
sed -i 's/^name: foo$/name: foo-copy/' "$root/foo-copy/SKILL.md"
settle a foo-copy
assert_exit 0 ds a skills reconcile --full
assert_eq capture "$(item a foo-copy .state)"
ds_code a skills capture --now
assert_eq foo-copy "$(remote_entry foo-copy | jq -r .directory)"
assert_contains "$(remote_file agent/skills/foo-copy/SKILL.md)" "the text of the copy"
assert_eq "$original" "$(remote_file agent/skills/foo/SKILL.md)"

# An answer does not change whose name it is.
cp -a "$root/foo" "$root/foo-second"
printf 'another copy\n' >>"$root/foo-second/SKILL.md"
settle a foo-second
assert_exit 0 ds a skills reconcile --full
assert_eq ask "$(item a foo-second .state)"
tip=$(remote_tip)
EXPECT_STATUS=3 ds_code a skills track foo-second --own
assert_eq "$tip" "$(remote_tip)" "no commit after an answer"
assert_eq name-taken "$(item a foo-second .state)"
