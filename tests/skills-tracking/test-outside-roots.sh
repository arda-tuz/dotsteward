# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own skill linked to a place outside the skill roots is not refreshed by `agents
# install`. It then has not taken what another machine published, so b stays, this machine
# hears of it, and no later capture pushes the old copy over the change of the other one.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
new_machine b
install=(agents install --profile workstation --skip-validation)

own_new a s2
settle a s2
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"

# Machine a keeps its copy somewhere else and links it.
a_dev=$(home_of a)/dev/s2
mkdir -p "$(dirname "$a_dev")"
mv "$(home_of a)/.agents/skills/s2" "$a_dev"
ln -s "$a_dev" "$(home_of a)/.agents/skills/s2"
assert_exit 0 ds a "${install[@]}"
before=$(base a s2)

# Machine b changes the skill and publishes.
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b "${install[@]}"
b_copy=$(home_of b)/.agents/skills/s2
printf 'the edit of machine b\n' >>"$b_copy/SKILL.md"
assert_exit 0 ds b skills reconcile --full
find "$b_copy" -exec touch -h -d '2001-01-01' {} +
ds_code b skills capture --now
assert_contains "$(remote_file agent/skills/s2/SKILL.md)" "the edit of machine b"
tip=$(remote_tip)

# Machine a pulls: it cannot refresh, and b does not move.
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a incoming answer skill:s2 --install
assert_contains "$DS_STDOUT$DS_STDERR" "skill outside the managed skill roots not refreshed"
assert_contains "$DS_STDOUT$DS_STDERR" "skill s2: conflict"
assert_not_contains "$(cat "$a_dev/SKILL.md")" "the edit of machine b"
assert_eq "$before" "$(base a s2)"
assert_eq conflict "$(item a s2 .state)"

# Nothing that looks later turns it into a change of machine a.
assert_exit 0 ds a skills reconcile --full
assert_eq conflict "$(item a s2 .state)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "no push over the other machine"

# An answer to the question of tracking is not the answer to this one.
EXPECT_STATUS=3 ds_code a skills track s2 --own
assert_eq "$tip" "$(remote_tip)" "track --own is no resolve"
assert_eq conflict "$(item a s2 .state)"

# An edit on machine a is what it always was: a conflict, not a push.
printf 'the edit of machine a\n' >>"$a_dev/SKILL.md"
assert_exit 0 ds a skills reconcile --full
find "$a_dev" -exec touch -h -d '2001-01-01' {} +
EXPECT_STATUS=3 ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "no push of the edit"
assert_contains "$(remote_file agent/skills/s2/SKILL.md)" "the edit of machine b"
assert_eq conflict "$(item a s2 .state)"

# The answer works through the link.
ds_code a skills resolve s2 --theirs
assert_contains "$(cat "$a_dev/SKILL.md")" "the edit of machine b"
assert_not_contains "$(cat "$a_dev/SKILL.md")" "the edit of machine a"
[[ -L $(home_of a)/.agents/skills/s2 ]] || ds_fail "the link stays"
assert_eq "$(remote_entry s2 | jq -r .directory_sha256)" "$(base a s2)"
assert_eq "{}" "$(item a s2 .)"
