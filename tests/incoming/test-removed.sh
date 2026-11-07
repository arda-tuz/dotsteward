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

# This machine leaves the machines of a skill: the same question, and the source is named.
captured laptop1 scoped
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:scoped --install
up_to_date laptop1
clone=$(clone_of laptop1)
printf 'schema_version = 1\n' >"$clone/hosts/laptop1.toml"
jq '(.skills[] | select(.name == "scoped")).machines = ["laptop1"]' "$clone/agent/skills.lock.json" >"$clone/agent/skills.lock.tmp"
mv -- "$clone/agent/skills.lock.tmp" "$clone/agent/skills.lock.json"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: only on laptop1\n\nDotsteward-Machine: laptop1'
git -C "$clone" push -q origin main
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "skill:scoped" and .items[0].change == "removed" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_exit 0 agents laptop2 check --skip-validation
assert_exit 0 ds laptop2 incoming answer skill:scoped --install
[[ ! -e $root/scoped ]] || ds_fail "scoped is still here"
assert_eq '' "$(waiting laptop2)"
