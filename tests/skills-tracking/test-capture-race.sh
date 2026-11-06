# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # scripts and jq programs are single-quoted on purpose
# Two machines and one remote. Different skills arrive at the same moment, none is lost
# and nothing is forced; a push whose answer got lost makes no second commit. The same
# skill changed on both sides, or two new skills with one name, is a conflict: no commit,
# nothing changes here, and the user decides with --ours or --theirs; `skills diff` gives
# the trees to look at.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"
wrap_git

new_machine a
new_machine b

commits_since() {
  git -C "$remote" rev-list --count "$1..refs/heads/main"
}

# --- different skills at once: both land, no force ------------------------------------

start=$(remote_tip)
own_new a from-a
own_new b from-b
settle a from-a
settle b from-b
ds a skills capture --now >"$DS_TEST_ROOT/a.out" 2>&1 &
pid_a=$!
ds b skills capture --now >"$DS_TEST_ROOT/b.out" 2>&1 &
pid_b=$!
wait "$pid_a" || ds_fail "the capture of a failed: $(cat "$DS_TEST_ROOT/a.out")"
wait "$pid_b" || ds_fail "the capture of b failed: $(cat "$DS_TEST_ROOT/b.out")"
assert_eq 2 "$(commits_since "$start")"
assert_eq '["example-skill","from-a","from-b"]' "$(remote_lock '[.skills[].name]')"
assert_eq "$(remote_entry from-a | jq -r .directory_sha256)" "$(base a from-a)"
assert_eq "$(remote_entry from-b | jq -r .directory_sha256)" "$(base b from-b)"

# --- a moved remote between fetch and push: the replay lands on the new tip -----------

start=$(remote_tip)
own_new a first
settle a first
own_new b second
settle b second
cat >"$DS_TEST_ROOT/before-push" <<SCRIPT
export HOME=$(home_of a) DOTSTEWARD_STATE_ROOT=$(state_of a) DOTSTEWARD_MACHINE=a DOTSTEWARD_INSTANCE=$(clone_of a)
"$DS_REPO_ROOT/cli/dotsteward" skills capture --now
SCRIPT
GIT_WRAP_BEFORE_PUSH=$DS_TEST_ROOT/before-push ds_code b skills capture --now
[[ -f $DS_TEST_ROOT/before-push.run ]] || ds_fail "the other machine came first"
assert_eq 2 "$(commits_since "$start")"
assert_eq "chore(skills): capture second" "$(git -C "$remote" log -1 --format=%s)"
assert_eq "chore(skills): capture first" "$(git -C "$remote" log -1 --format=%s 'refs/heads/main^')"
assert_eq '["example-skill","first","from-a","from-b","second"]' "$(remote_lock '[.skills[].name]')"

# --- the answer of a push is lost: no second commit --------------------------------------

start=$(remote_tip)
own_new a lost-reply
settle a lost-reply
: >"$DS_TEST_ROOT/lose"
GIT_WRAP_LOSE_REPLY=$DS_TEST_ROOT/lose ds_code a skills capture --now --json
[[ ! -e $DS_TEST_ROOT/lose ]] || ds_fail "the push took the path that loses its answer"
assert_json - '.captured == ["lost-reply"]' <<<"$DS_STDOUT"
assert_eq 1 "$(commits_since "$start")"
assert_eq "$(remote_entry lost-reply | jq -r .directory_sha256)" "$(base a lost-reply)"
assert_eq "{}" "$(item a lost-reply .)"

# --- the same skill on both machines: a conflict, then --ours ------------------------------

git -C "$(clone_of a)" pull -q --ff-only
git -C "$(clone_of b)" pull -q --ff-only
own_new a shared
settle a shared
ds_code a skills capture --now
b_copy=$(home_of b)/.agents/skills/shared
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ -f $b_copy/SKILL.md ]] || ds_fail "the other machine got the skill"
a_copy=$(home_of a)/.claude/skills/shared
printf 'from machine a\n' >>"$a_copy/SKILL.md"
printf 'from machine b\n' >>"$b_copy/SKILL.md"
wrote a shared
settle a shared
ds_code a skills capture --now
tip=$(remote_tip)
# b finds the remote moved under its own change.
assert_exit 0 ds b skills reconcile --full
assert_eq capture "$(item b shared .state)"
find "$b_copy" -exec touch -h -d '2001-01-01' {} +
EXPECT_STATUS=3 ds_code b skills capture --now --json
assert_json - '.status == "pending" and .conflicts == ["shared"]' <<<"$DS_STDOUT"
assert_eq "$tip" "$(remote_tip)" "no commit in a conflict"
assert_eq conflict "$(item b shared .state)"
# It stays a conflict, and it is not asked anew, until the content changes.
jq '.items["skill:shared"].last_asked = 12345' "$(state_of b)/skills/pending.json" >"$DS_TEST_ROOT/pending.tmp"
cp "$DS_TEST_ROOT/pending.tmp" "$(state_of b)/skills/pending.json"
assert_exit 0 ds b skills reconcile --full
assert_eq conflict "$(item b shared .state)"
assert_eq 12345 "$(item b shared .last_asked)"
assert_contains "$(cat "$b_copy/SKILL.md")" "from machine b"
assert_not_contains "$(cat "$b_copy/SKILL.md")" "from machine a"
# Three trees to look at.
assert_exit 0 ds b skills diff shared --json
document=$DS_STDOUT
assert_contains "$(cat "$(jq -r .local <<<"$document")/SKILL.md")" "from machine b"
assert_contains "$(cat "$(jq -r .remote <<<"$document")/SKILL.md")" "from machine a"
assert_not_contains "$(cat "$(jq -r .base <<<"$document")/SKILL.md")" "from machine"
assert_eq "$tip" "$(jq -r .remote_commit <<<"$document")"
# Ours: the local copy wins.
ds_code b skills resolve shared --ours
assert_contains "$(remote_file agent/skills/shared/SKILL.md)" "from machine b"
assert_not_contains "$(remote_file agent/skills/shared/SKILL.md)" "from machine a"
assert_eq "{}" "$(item b shared .)"
assert_eq "$(remote_entry shared | jq -r .directory_sha256)" "$(base b shared)"

# --- again, and --theirs: the local copy goes to a backup -----------------------------------

printf 'second from a\n' >>"$a_copy/SKILL.md"
wrote a shared
settle a shared
# a takes what b published first.
EXPECT_STATUS=3 ds_code a skills capture --now
ds_code a skills resolve shared --theirs
assert_contains "$(cat "$a_copy/SKILL.md")" "from machine b"
assert_not_contains "$(cat "$a_copy/SKILL.md")" "second from a"
backup=$(find "$(state_of a)/backups" -mindepth 1 -maxdepth 1 -name '*-skills' | LC_ALL=C sort | tail -n 1)
assert_contains "$(cat "$backup/files$a_copy/SKILL.md")" "second from a"
assert_eq "$(remote_entry shared | jq -r .directory_sha256)" "$(base a shared)"
assert_eq "{}" "$(item a shared .)"
assert_exit 1 ds a skills resolve shared --ours
assert_contains "$DS_STDERR" "no conflict"
assert_exit 2 ds a skills resolve shared
assert_exit 2 ds a skills resolve shared --ours --theirs

# --- two new skills with one name ----------------------------------------------------------

own_new a twin
settle a twin
ds_code a skills capture --now
tip=$(remote_tip)
own_new b twin
printf 'other content\n' >>"$(home_of b)/.claude/skills/twin/SKILL.md"
wrote b twin
settle b twin
EXPECT_STATUS=3 ds_code b skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_eq conflict "$(item b twin .state)"
ds_code b skills resolve twin --ours
assert_contains "$(remote_file agent/skills/twin/SKILL.md)" "other content"
# The same name with the same content: nothing to commit, and in sync.
own_new a same-twin
settle a same-twin
ds_code a skills capture --now
tip=$(remote_tip)
own_new b same-twin
settle b same-twin
ds_code b skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_eq "{}" "$(item b same-twin .)"
assert_eq "$(remote_entry same-twin | jq -r .directory_sha256)" "$(base b same-twin)"
