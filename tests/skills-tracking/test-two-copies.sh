# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Two different local copies of one skill: nothing says which one is the skill, so neither
# goes out, and the person hears of it. A copy with the same content is no problem. Without
# this, each write would replace what the other copy published.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

own_new a foo
settle a foo
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
copy=$(home_of a)/.agents/skills/foo
[[ -d $copy && ! -L $copy ]] || ds_fail "the copy is in the canonical root"
original=$(remote_file agent/skills/foo/SKILL.md)
tip=$(remote_tip)

# write_to PATH: what the hook sees when a file tool wrote SKILL.md below PATH.
write_to() {
  on a bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|fe058fc9|g" -e "s|@FILE@|$2|g" "$1" |
    "$3" skills hook PostToolUse --agent claude' _ "$fixtures/claude/post-tool-use-write.json" "$1/SKILL.md" \
    "$DS_REPO_ROOT/cli/dotsteward"
  find "$1" -exec touch -h -d '2001-01-01' {} +
}

# An identical leftover in another root: no problem, an edit of the real copy goes out.
legacy=$(home_of a)/.codex/skills/foo
cp -a "$copy" "$legacy"
printf 'first edit\n' >>"$copy/SKILL.md"
cp -a "$copy/SKILL.md" "$legacy/SKILL.md"
write_to "$copy"
touch -d '2001-01-01' "$legacy/SKILL.md"
ds_code a skills capture --now
assert_contains "$(remote_file agent/skills/foo/SKILL.md)" "first edit"
tip=$(remote_tip)

# The leftover gets a text of its own: neither goes out, in any order, on any look.
printf 'a variant\n' >>"$legacy/SKILL.md"
write_to "$legacy"
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "no write decides between two copies"
assert_eq name-taken "$(item a foo .state)"
assert_eq two-copies "$(item a foo .reason)"
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "nor does a look"
printf 'an edit of the other\n' >>"$copy/SKILL.md"
write_to "$copy"
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "nor the other copy"
ds_code a skills status
assert_contains "$DS_STDOUT" "two-copies"
assert_contains "$DS_STDOUT" "$legacy"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
assert_contains "$HOOK_OUT" foo
assert_contains "$HOOK_OUT" "dotsteward skills retry"
HOOK_ENV=()

# One goes away: the other is the skill.
rm -rf -- "$legacy"
ds_code a skills retry foo
assert_contains "$(remote_file agent/skills/foo/SKILL.md)" "an edit of the other"
assert_not_contains "$(remote_file agent/skills/foo/SKILL.md)" "a variant"
assert_eq "{}" "$(item a foo .)"

# --- a directory named after the entry beside the directory of the entry ---------------------

git -C "$(clone_of a)" pull -q --ff-only
elsewhere=$DS_TEST_ROOT/elsewhere
git clone -q "$remote" "$elsewhere"
mkdir -p "$elsewhere/agent/skills/xdir"
printf -- '---\nname: xn\ndescription: Synthetic skill.\n---\n' >"$elsewhere/agent/skills/xdir/SKILL.md"
printf 'MIT\n' >"$elsewhere/agent/skills/xdir/LICENSE"
dir_digest=$(local_digest "$elsewhere/agent/skills/xdir")
skill_digest=$(sha256sum -- "$elsewhere/agent/skills/xdir/SKILL.md" | cut -d' ' -f1)
jq --arg dir "$dir_digest" --arg skill "$skill_digest" \
  '.skills += [{name: "xn", directory: "xdir", revision: "same-as-instance-checkout", skill_sha256: $skill, directory_sha256: $dir}]' \
  "$elsewhere/agent/skills.lock.json" >"$elsewhere/lock.tmp"
mv -- "$elsewhere/lock.tmp" "$elsewhere/agent/skills.lock.json"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "chore: a skill whose directory has another name"
git -C "$elsewhere" push -q origin main
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
tip=$(remote_tip)
cp -a "$(home_of a)/.agents/skills/xdir" "$root/xn"
printf 'a copy under the name\n' >>"$root/xn/SKILL.md"
wrote a xn
settle a xn
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_not_contains "$(remote_file agent/skills/xdir/SKILL.md)" "a copy under the name"
