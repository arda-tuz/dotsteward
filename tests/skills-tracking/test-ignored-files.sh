# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What the normal form leaves out never left this machine, so a new copy from the repository
# has no such files. They stay in the live skill: `agents install` and `resolve --theirs`
# replace what the repository holds, and leave credentials, state and a clone's .git alone.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)

own_new a keeper
a_skill=$(home_of a)/.claude/skills/keeper
printf 'secrets/\nstate/\n' >"$a_skill/.gitignore"
wrote a keeper
settle a keeper
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
a_copy=$(home_of a)/.agents/skills/keeper
mkdir -p "$a_copy/secrets" "$a_copy/state/deep"
printf 'token\n' >"$a_copy/secrets/token"
chmod 0600 "$a_copy/secrets/token"
printf 'data\n' >"$a_copy/state/deep/db"
git -C "$a_copy" init -q
assert_exit 0 ds a skills status --json
assert_json - 'first(.own[] | select(.name == "keeper")).state == "in-sync"' <<<"$DS_STDOUT"

# publish_from_b TEXT: machine b changes the skill and publishes it.
publish_from_b() {
  git -C "$(clone_of b)" pull -q --ff-only
  assert_exit 0 ds b "${install[@]}"
  local copy
  copy=$(home_of b)/.agents/skills/keeper
  printf '%s\n' "$1" >>"$copy/SKILL.md"
  assert_exit 0 ds b skills reconcile --full
  find "$copy" -exec touch -h -d '2001-01-01' {} +
  ds_code b skills capture --now
}

assert_kept() {
  assert_eq "token" "$(cat "$a_copy/secrets/token")"
  assert_eq 600 "$(stat -c %a "$a_copy/secrets/token")"
  assert_eq "data" "$(cat "$a_copy/state/deep/db")"
  [[ -d $a_copy/.git ]] || ds_fail "the .git of the copy stays"
}

# incoming
publish_from_b "first edit of machine b"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a incoming answer skill:keeper --install
assert_contains "$(cat "$a_copy/SKILL.md")" "first edit of machine b"
assert_kept
assert_exit 0 ds a skills status --json
assert_json - 'first(.own[] | select(.name == "keeper")).state == "in-sync"' <<<"$DS_STDOUT"
assert_exit 0 ds a agents check --profile workstation

# resolve --theirs
publish_from_b "second edit of machine b"
printf 'an edit of machine a\n' >>"$a_copy/SKILL.md"
assert_exit 0 ds a skills reconcile --full
find "$a_copy" -exec touch -h -d '2001-01-01' {} +
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq conflict "$(item a keeper .state)"
ds_code a skills resolve keeper --theirs
assert_contains "$(cat "$a_copy/SKILL.md")" "second edit of machine b"
assert_not_contains "$(cat "$a_copy/SKILL.md")" "an edit of machine a"
assert_kept
