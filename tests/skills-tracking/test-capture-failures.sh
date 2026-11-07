# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What keeps a skill from the remote keeps it working here and is told once. A privacy
# finding, a link out of the tree, a skill too large or without a name: no commit, no push,
# and the same content is not tried or told again. Without a network the skill waits in
# a list, no commit piles up, and the next run pushes it. A remote that says no is told,
# not mistaken for the network. A capture killed at any point leaves nothing that stops
# the next one, and a capture that holds the lock takes what arrives meanwhile.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"
wrap_git

new_machine a
checkout=$(clone_of a)

# nothing_new NAME: the remote and the refs of the checkout show no commit of it.
nothing_new() {
  assert_eq "$1" "$(remote_tip)" "no push"
  assert_eq "$(git -C "$checkout" rev-parse HEAD)" "$head" "the checkout stays"
}
head=$(git -C "$checkout" rev-parse HEAD)

# --- a privacy finding: no commit, no push, told once --------------------------------------

term=confidentialterm
printf '%s\n' "$term" >"$DS_TEST_ROOT/denylist.txt"
git -C "$checkout" pull -q --ff-only
printf '\n[privacy]\ndenylist = "%s"\n' "$DS_TEST_ROOT/denylist.txt" >>"$checkout/workstation.toml"
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "chore: a denylist"
git -C "$checkout" push -q origin main
head=$(git -C "$checkout" rev-parse HEAD)
start=$(remote_tip)
own_new a leaky
leaky=$(home_of a)/.claude/skills/leaky
printf 'first line\nsecond line\nabout %s here\n' "$term" >"$leaky/references/notes.md"
wrote a leaky
settle a leaky
EXPECT_STATUS=4 ds_code a skills capture --now --json
assert_json - '.status == "privacy-stop" and .blocked == ["leaky"]' <<<"$DS_STDOUT"
assert_not_contains "$DS_STDOUT$DS_STDERR" "$term"
nothing_new "$start"
assert_eq blocked "$(item a leaky .state)"
assert_eq privacy "$(item a leaky .reason)"
last=$(cat "$(state_of a)/skills/last-capture.json")
assert_contains "$last" "agent/skills/leaky/references/notes.md:3"
assert_not_contains "$last" "$term"
assert_not_contains "$(cat "$(state_of a)/skills/pending.json")" "$term"
assert_contains "$(notified)" leaky
assert_not_contains "$(notified)" "$term"
notifications=$(notified | wc -l)
# The skill works here, and the same content is neither tried nor told again.
[[ -f $leaky/SKILL.md ]] || ds_fail "the skill stays"
ds_code a skills capture --now --json
assert_json - '.captured == [] and .blocked == []' <<<"$DS_STDOUT"
assert_exit 0 ds a skills reconcile --full
assert_eq blocked "$(item a leaky .state)"
assert_eq "$notifications" "$(notified | wc -l)"
assert_eq "{}" "$(jq -c '.items["skill:leaky"] // {} | if .state == "blocked" then {} else . end' "$(state_of a)/skills/pending.json")"
# Another content is tried again, and lands.
printf 'first line\nsecond line\n' >"$leaky/references/notes.md"
wrote a leaky
settle a leaky
ds_code a skills capture --now
assert_eq "{}" "$(item a leaky .)"
assert_eq "$(remote_entry leaky | jq -r .directory_sha256)" "$(base a leaky)"

# --- a skill that cannot be copied ------------------------------------------------------------

start=$(remote_tip)
own_new a linked
ln -s /nonexistent/target "$(home_of a)/.claude/skills/linked/broken"
wrote a linked
settle a linked
EXPECT_STATUS=1 ds_code a skills capture --now
assert_contains "$DS_STDERR" "linked"
assert_eq blocked "$(item a linked .state)"
assert_eq unsafe-link "$(item a linked .reason)"
rm -rf "$(home_of a)/.claude/skills/linked"

git -C "$checkout" pull -q --ff-only
printf 'capture_max_mib = 1\n' >"$DS_TEST_ROOT/max-line"
sed -i '/^tracking = true$/r '"$DS_TEST_ROOT/max-line" "$checkout/workstation.toml"
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "chore: a small limit"
git -C "$checkout" push -q origin main
head=$(git -C "$checkout" rev-parse HEAD)
start=$(remote_tip)
own_new a huge
dd if=/dev/zero of="$(home_of a)/.claude/skills/huge/blob.bin" bs=1M count=2 status=none
wrote a huge
settle a huge
EXPECT_STATUS=1 ds_code a skills capture --now
assert_eq too-large "$(item a huge .reason)"
nothing_new "$start"
rm -rf "$(home_of a)/.claude/skills/huge"

own_new a nameless
printf 'no frontmatter here\n' >"$(home_of a)/.claude/skills/nameless/SKILL.md"
wrote a nameless
settle a nameless
EXPECT_STATUS=1 ds_code a skills capture --now
assert_eq skill-invalid "$(item a nameless .reason)"
nothing_new "$start"
rm -rf "$(home_of a)/.claude/skills/nameless"
assert_exit 0 ds a skills reconcile

# --- no network: a list, no commit, and the next run pushes --------------------------------

ssh_url=git@github.com:example-org/workstation.git
ds_fakessh_enable
ds_fakessh_map "$ssh_url" "$remote"
git -C "$checkout" remote set-url origin "$ssh_url"
own_new a waiting
settle a waiting
start=$(remote_tip)
commits_before=$(git -C "$checkout" rev-list --all --count)
EXPECT_STATUS=6 DS_FAKESSH_FAIL=1 ds_code a skills capture --now --json
assert_json - '.status == "partial" and .waiting == ["waiting"]' <<<"$DS_STDOUT"
assert_eq "$start" "$(remote_tip)"
assert_eq capture "$(item a waiting .state)"
assert_eq offline "$(item a waiting .reason)"
[[ $(item a waiting .offline_since) != null ]] || ds_fail "it says since when"
assert_eq "$commits_before" "$(git -C "$checkout" rev-list --all --count)" "no local commit"
[[ ! -e $(state_of a)/skills/worktree ]] || ds_fail "no worktree stays"
# A dropped connection after the fetch: the same.
ds_code a skills capture --now
assert_eq "{}" "$(item a waiting .)"
assert_eq "$(remote_entry waiting | jq -r .directory_sha256)" "$(base a waiting)"

# --- a remote that says no is told, not mistaken for the network ---------------------------

git -C "$checkout" remote set-url origin "$remote"
start=$(remote_tip)
cat >"$remote/hooks/pre-receive" <<HOOK
#!$BASH
printf 'protected branch\n' >&2
exit 1
HOOK
chmod 0755 "$remote/hooks/pre-receive"
own_new a refused
settle a refused
notifications=$(notified | wc -l)
EXPECT_STATUS=1 ds_code a skills capture --now --json
assert_json - '.status == "failed" and .blocked == ["refused"]' <<<"$DS_STDOUT"
assert_eq blocked "$(item a refused .state)"
assert_eq remote-refused "$(item a refused .reason)"
assert_eq "$start" "$(remote_tip)"
(($(notified | wc -l) > notifications)) || ds_fail "a refusal is told"
rm -f "$remote/hooks/pre-receive"
# Another content is tried again.
printf 'changed\n' >>"$(home_of a)/.claude/skills/refused/SKILL.md"
wrote a refused
settle a refused
ds_code a skills capture --now
assert_eq "{}" "$(item a refused .)"
# Access denied at the fetch is the same refusal.
denied=$DS_TEST_ROOT/denied-ssh
cat >"$denied" <<SSH
#!$BASH
printf 'git@github.com: Permission denied (publickey).\n' >&2
exit 255
SSH
chmod 0755 "$denied"
git -C "$checkout" remote set-url origin "$ssh_url"
own_new a credentials
settle a credentials
EXPECT_STATUS=1 GIT_SSH_COMMAND=$denied ds_code a skills capture --now
assert_eq blocked "$(item a credentials .state)"
assert_eq remote-refused "$(item a credentials .reason)"
git -C "$checkout" remote set-url origin "$remote"
rm -rf "$(home_of a)/.claude/skills/credentials"
assert_exit 0 ds a skills reconcile

# --- a capture killed half way, and what a dead one leaves behind ---------------------------

own_new a killed
settle a killed
start=$(remote_tip)
stall=$DS_TEST_ROOT/stall
(
  GIT_WRAP_STALL_COMMIT=$stall ds a skills capture --now >/dev/null 2>&1
) &
killer=$!
for _ in $(seq 1 1500); do
  [[ -s $stall ]] && break
  sleep 0.1
done
[[ -s $stall ]] || ds_fail "the capture did not reach its commit"
read -r stalled capturing <"$stall"
ds_defer kill -9 "$capturing" "$stalled"
kill -9 "$capturing" "$stalled"
wait "$killer" 2>/dev/null || true
assert_eq "$start" "$(remote_tip)"
worktree=$(state_of a)/skills/worktree
[[ -d $worktree ]] || ds_fail "the killed capture left its worktree"
assert_eq capture "$(item a killed .state)"
# A registered worktree with changes, then a stray directory: both recover.
ds_code a skills capture --now
assert_eq "{}" "$(item a killed .)"
[[ ! -e $worktree ]] || ds_fail "the worktree is gone again"
own_new a stray
settle a stray
mkdir -p "$worktree/half/way"
printf 'partial\n' >"$worktree/half/way/file"
ds_code a skills capture --now
assert_eq "{}" "$(item a stray .)"
assert_eq 1 "$(git -C "$checkout" worktree list --porcelain | grep -c '^worktree ')"

# --- a held lock: exit 0, and the holder takes what arrives meanwhile -------------------------

own_new a held
settle a held
python3 -c '
import fcntl, sys, time
handle = open(sys.argv[1], "a")
fcntl.flock(handle, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(600)
' "$(state_of a)/skills/capture.lock" "$DS_TEST_ROOT/held" &
holder=$!
ds_defer kill -9 "$holder"
for _ in $(seq 1 300); do
  [[ -e $DS_TEST_ROOT/held ]] && break
  sleep 0.1
done
ds_code a skills capture --now --json
assert_json - '.captured == []' <<<"$DS_STDOUT"
assert_eq capture "$(item a held .state)"
kill -9 "$holder"
wait "$holder" 2>/dev/null || true
# Something arrives while a capture runs: it does not leave it behind.
own_new a arrives
settle a arrives
cat >"$DS_TEST_ROOT/before-push" <<SCRIPT
export HOME=$(home_of a) DOTSTEWARD_STATE_ROOT=$(state_of a) DOTSTEWARD_MACHINE=a DOTSTEWARD_INSTANCE=$(clone_of a)
mkdir -p "\$HOME/.claude/skills/late/references"
printf -- '---\nname: late\n---\n' >"\$HOME/.claude/skills/late/SKILL.md"
"$DS_REPO_ROOT/cli/dotsteward" skills track late --all --own --no-capture
find "\$HOME/.claude/skills/late" -exec touch -h -d '2001-01-01' {} +
SCRIPT
GIT_WRAP_BEFORE_PUSH=$DS_TEST_ROOT/before-push ds_code a skills capture --now
assert_eq "{}" "$(item a late .)"
assert_eq "$(remote_entry late | jq -r .directory_sha256)" "$(base a late)"
