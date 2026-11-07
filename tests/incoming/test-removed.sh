# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own skill that left the repository or left this machine's scope: remove, keep and ask
# later, or never ask again. A copy is never removed without an answer.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2
for skill in gone kept never; do
  captured laptop1 "$skill"
  up_to_date laptop1
done
up_to_date laptop2
for skill in gone kept never; do
  assert_exit 0 ds laptop2 incoming answer "skill:$skill" --install
done
up_to_date laptop1

for skill in gone kept never; do
  assert_exit 0 ds laptop1 skills forget "$skill"
  up_to_date laptop1
done
# The machine that forgot them keeps its copies, and a later install leaves them alone.
assert_exit 0 agents laptop1 install --skip-validation
for skill in gone kept never; do
  [[ -f $(copy_of laptop1 "$skill")/SKILL.md ]] || ds_fail "forget took the copy of $skill away"
done
assert_eq '' "$(waiting laptop1)"
up_to_date laptop2
root=$(home_of laptop2)/.agents/skills

assert_eq 'skill:gone skill:kept skill:never' "$(waiting laptop2)"
assert_exit 0 ds laptop2 incoming list --json
assert_json - '[.items[] | .change] | unique == ["removed"]' <<<"$DS_STDOUT"
assert_json - '.items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_exit 0 agents laptop2 install --skip-validation
for skill in gone kept never; do
  [[ -f $root/$skill/SKILL.md ]] || ds_fail "$skill went without an answer"
done

out=$(ask_on_tty laptop2 $'r\nl\nn' incoming)
assert_contains "$out" 'skill gone (removed) - machine laptop1'
assert_contains "$out" '[R]emove, keep and ask [L]ater, [N]ever ask again on this machine'
[[ ! -e $root/gone ]] || ds_fail "gone is still here"
[[ ! -e $(home_of laptop2)/.claude/skills/gone ]] || ds_fail "the link of gone is still here"
assert_eq 1 "$(find "$(state_of laptop2)/backups" -name SKILL.md -path '*gone*' | wc -l)" "the backup of gone"
assert_eq none "$(base laptop2 gone)"
[[ -f $root/kept/SKILL.md ]] || ds_fail "kept went"
[[ -f $root/never/SKILL.md ]] || ds_fail "never went"
assert_eq none "$(base laptop2 never)"
assert_contains "$(remote_file hosts/laptop2.toml)" '"never"'
assert_eq 'skill:kept' "$(waiting laptop2)"

# It does not come back as a new skill of this machine, and the answer holds.
assert_exit 0 ds laptop2 skills reconcile --full
assert_eq none "$(item laptop2 never '.state // "none"')"
assert_exit 0 ds laptop2 incoming answer skill:kept --install
assert_eq '' "$(waiting laptop2)"

# Never without a network, on a skill the lock no longer holds: the copy stays out of a capture
# while the answer waits for the remote.
up_to_date laptop1
captured laptop1 offline
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:offline --install
assert_exit 0 ds laptop1 skills forget offline
up_to_date laptop2
url=$(git -C "$(clone_of laptop2)" remote get-url origin)
git -C "$(clone_of laptop2)" remote set-url origin "$world/gone.git"
assert_exit 0 ds laptop2 incoming answer skill:offline --never
assert_exit 0 ds laptop2 skills reconcile --full
assert_eq none "$(item laptop2 offline '.state // "none"')"
git -C "$(clone_of laptop2)" remote set-url origin "$url"
assert_exit 0 ds laptop2 incoming
assert_contains "$(remote_file hosts/laptop2.toml)" '"offline"'
assert_eq none "$(item laptop2 offline '.state // "none"')"
up_to_date laptop1

# This machine leaves the machines of a skill: the same question, and the source is named.
captured laptop1 scoped
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:scoped --install
up_to_date laptop1
clone=$(clone_of laptop1)
mkdir -p "$clone/hosts"
printf 'schema_version = 1\n' >"$clone/hosts/laptop1.toml"
jq '(.skills[] | select(.name == "scoped")).machines = ["laptop1"]' "$clone/agent/skills.lock.json" >"$clone/agent/skills.lock.tmp"
mv -- "$clone/agent/skills.lock.tmp" "$clone/agent/skills.lock.json"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: only on laptop1\n\nDotsteward-Machine: laptop1'
git -C "$clone" push -q origin main
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "skill:scoped" and .items[0].change == "removed" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_exit 0 agents laptop2 check
assert_exit 0 ds laptop2 incoming answer skill:scoped --install
[[ ! -e $root/scoped ]] || ds_fail "scoped is still here"
assert_eq '' "$(waiting laptop2)"

# A lock that cannot be read says nothing about any skill: no question, and no copy goes.
captured laptop1 steady
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:steady --install
lock=$(clone_of laptop2)/agent/skills.lock.json
cp -- "$lock" "$DS_TEST_ROOT/lock.good"
printf '{ not json\n' >"$lock"
assert_eq '' "$(waiting laptop2)"
agents laptop2 install --skip-validation >/dev/null 2>&1 || true
[[ -f $root/steady/SKILL.md ]] || ds_fail "a broken lock took a copy away"
assert_exit 0 ds laptop2 incoming list
cp -- "$DS_TEST_ROOT/lock.good" "$lock"
assert_eq "$(remote_entry steady | jq -r .directory_sha256)" "$(base laptop2 steady)"

# This machine scoped a skill away from itself in a commit of its own: no question, and the
# copy stays until somebody removes it: only a skill the lock no longer holds goes by itself.
clone=$(clone_of laptop2)
jq '(.skills[] | select(.name == "steady")).machines = ["laptop1"]' "$clone/agent/skills.lock.json" >"$clone/agent/skills.lock.tmp"
mv -- "$clone/agent/skills.lock.tmp" "$clone/agent/skills.lock.json"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: not here\n\nDotsteward-Machine: laptop2'
assert_eq '' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
[[ -f $root/steady/SKILL.md ]] || ds_fail "a change of scope took the copy away"
git -C "$clone" reset -q --hard HEAD~1

# A skill of this machine that cannot be read when another machine changed it is no reason for a
# command to fail.
up_to_date laptop1
edited laptop1 steady 'a new version'
up_to_date laptop2
chmod 000 "$root/steady/SKILL.md"
assert_exit 0 ds laptop2 incoming list
chmod 644 "$root/steady/SKILL.md"
assert_eq 'skill:steady' "$(waiting laptop2)"

# M6: a copy that is a link out of the skill roots: the link goes, what it points at is the user's.
up_to_date laptop1
assert_exit 0 ds laptop2 incoming answer skill:steady --install
captured laptop1 linked
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:linked --install
tree=$DS_TEST_ROOT/dev-tree/linked
mkdir -p "${tree%/*}"
mv -- "$root/linked" "$tree"
printf 'a note not in the repository\n' >"$tree/notes.txt"
ln -s "$tree" "$root/linked"
assert_exit 0 ds laptop2 skills status
assert_exit 0 ds laptop1 skills forget linked
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:linked --install
[[ ! -L $root/linked && ! -e $root/linked ]] || ds_fail "the link is still here"
[[ -f $tree/notes.txt && -f $tree/SKILL.md ]] || ds_fail "the removal followed the link"

# m3: a copy without SKILL.md is still a copy: a question, nothing goes without an answer.
captured laptop1 hollow
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:hollow --install
assert_exit 0 ds laptop1 skills forget hollow
up_to_date laptop1
up_to_date laptop2
rm -- "$root/hollow/SKILL.md"
printf 'kept\n' >"$root/hollow/notes.txt"
assert_eq 'skill:hollow' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
[[ -f $root/hollow/notes.txt ]] || ds_fail "an install took a copy away without an answer"
assert_exit 0 ds laptop2 incoming answer skill:hollow --install
