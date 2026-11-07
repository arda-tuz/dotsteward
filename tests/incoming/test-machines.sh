# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A skill for one machine: the other machines never install it and are never asked. A
# reinstall under its name brings it back, without a question.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2

clone=$(clone_of laptop1)
hand_skill laptop1 only-one
mkdir -p "$clone/hosts"
printf 'schema_version = 1\n' >"$clone/hosts/laptop1.toml"
jq '(.skills[] | select(.name == "only-one")).machines = ["laptop1"]' "$clone/agent/skills.lock.json" >"$clone/agent/skills.lock.tmp"
mv -- "$clone/agent/skills.lock.tmp" "$clone/agent/skills.lock.json"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: a skill of laptop1\n\nDotsteward-Machine: laptop1'
git -C "$clone" push -q origin main
assert_exit 0 agents laptop1 install --skip-validation
[[ -f $(home_of laptop1)/.agents/skills/only-one/SKILL.md ]] || ds_fail "the machine of the skill did not get it"

# The other machine: nothing to answer, nothing installed, no line in the review.
up_to_date laptop2
assert_exit 0 ds laptop2 incoming
assert_eq '' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/only-one ]] || ds_fail "another machine installed it"
assert_exit 0 ds laptop2 skills effective --json
assert_eq machines "$(jq -r '.reasons["skill:only-one"]' <<<"$DS_STDOUT")"
[[ ! -f $(state_of laptop2)/review.json ]] || assert_json "$(state_of laptop2)/review.json" \
  '[.items[] | select(.code == "incoming")] | length == 0'

# A reinstall under the same name.
rm -rf -- "$(state_of laptop1)" "$(home_of laptop1)"
mkdir -p "$(state_of laptop1)" "$(home_of laptop1)/.agents/skills" "$(home_of laptop1)/.claude/skills" "$(home_of laptop1)/.codex/skills"
assert_eq '' "$(waiting laptop1)"
assert_exit 0 agents laptop1 install --skip-validation
[[ -f $(home_of laptop1)/.agents/skills/only-one/SKILL.md ]] || ds_fail "the reinstall did not bring it back"
assert_eq '' "$(waiting laptop1)"
