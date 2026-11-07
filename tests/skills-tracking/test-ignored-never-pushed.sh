# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A file an ignore rule keeps here never reaches the repository, whichever path leads there.
# A file that stayed through a refresh stays only as long as a rule covers it; a rule that
# went away leaves it in the backup. And a rule on the remote holds for a copy that lost it.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)

# publish_from_b SKILL: what the standard input does to the copy of b is published.
edit_on_b() {
  local copy
  copy=$(home_of b)/.agents/skills/$1
  git -C "$(clone_of b)" pull -q --ff-only
  assert_exit 0 ds b "${install[@]}"
  (cd "$copy" && bash)
  assert_exit 0 ds b skills reconcile --full
  find "$copy" -exec touch -h -d '2001-01-01' {} +
  ds_code b skills capture --now
}

# remote_has SKILL PATH: whether the tip holds the file.
remote_has() {
  git -C "$remote" cat-file -e "refs/heads/main:agent/skills/$1/$2" 2>/dev/null
}

# --- the rule goes away on the other machine: the file stays out, in the backup ---------------

own_new a ig
a_skill=$(home_of a)/.claude/skills/ig
printf 'secrets/\n' >"$a_skill/.gitignore"
wrote a ig
settle a ig
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
a_copy=$(home_of a)/.agents/skills/ig
mkdir -p "$a_copy/secrets"
printf 'plain-local-value\n' >"$a_copy/secrets/token"
edit_on_b ig <<'EDIT'
: >.gitignore
printf 'an edit of b\n' >>SKILL.md
EDIT
tip=$(remote_tip)
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
assert_contains "$DS_STDOUT$DS_STDERR" "secrets/token"
assert_contains "$(cat "$a_copy/SKILL.md")" "an edit of b"
[[ ! -e $a_copy/secrets/token ]] || ds_fail "no rule covers the file any more"
assert_contains "$(cat "$(find "$(state_of a)/backups" -path '*secrets/token' | tail -1)")" plain-local-value
assert_exit 0 ds a skills status --json
assert_json - 'first(.own[] | select(.name == "ig")).state == "in-sync"' <<<"$DS_STDOUT"
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "nothing to publish"

# --- resolve --theirs drops a rule that only this machine had --------------------------------

own_new a th
a_skill=$(home_of a)/.claude/skills/th
settle a th
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
a_copy=$(home_of a)/.agents/skills/th
edit_on_b th <<'EDIT'
printf 'an edit of b\n' >>SKILL.md
EDIT
tip=$(remote_tip)
mkdir -p "$a_copy/secret"
printf '%s\n' 'secret/' >"$a_copy/.gitignore"
printf 'plain-local-value\n' >"$a_copy/secret/t"
printf 'an edit of a\n' >>"$a_copy/SKILL.md"
assert_exit 0 ds a skills reconcile --full
find "$a_copy" -exec touch -h -d '2001-01-01' {} +
EXPECT_STATUS=3 ds_code a skills capture --now
ds_code a skills resolve th --theirs
assert_contains "$DS_STDOUT$DS_STDERR" "secret/t"
[[ ! -e $a_copy/secret/t ]] || ds_fail "no rule covers the file any more"
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(item a th .)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "the answer was: not mine"
if remote_has th secret/t; then
  ds_fail "an ignored file reached the repository"
fi

# --- a copy that lost the rule of the repository: --ours does not get it there either ---------

own_new a kept
a_skill=$(home_of a)/.claude/skills/kept
printf 'private/\n' >"$a_skill/.gitignore"
wrote a kept
settle a kept
ds_code a skills capture --now
tip=$(remote_tip)
mkdir -p "$a_skill/private"
printf 'plain-local-value\n' >"$a_skill/private/data"
rm -f -- "$a_skill/.gitignore"
wrote a kept
settle a kept
EXPECT_STATUS=1 ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_eq blocked "$(item a kept .state)"
assert_eq ignored-file "$(item a kept .reason)"
ds_code a skills status
assert_contains "$DS_STDOUT" "private/data"
# Without the file it goes through, and the rule can go with it.
rm -rf -- "$a_skill/private"
wrote a kept
settle a kept
ds_code a skills capture --now
if remote_has kept .gitignore; then
  ds_fail "the rule goes with the copy"
fi
