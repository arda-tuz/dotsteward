# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What a machine stores about what it knows: components and plugins, nothing about skills. A skill
# is answered by its copy and base.json, so a skill that left and came back asks again, a new name
# on the machine loses nothing, and a component only counts as known once it was for this machine.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2
known=$(state_of laptop2)/machine/known.json
assert_json "$known" 'keys == ["components", "plugins", "schema_version"]'

# M4: installed, removed, removed here, back under the same name with other content: a question.
captured laptop1 readd
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:readd --install
assert_exit 0 ds laptop1 skills forget readd
up_to_date laptop1
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:readd --install
[[ ! -e $(home_of laptop2)/.agents/skills/readd ]] || ds_fail "the removal did not remove"
hand_skill laptop1 readd
printf 'totally different skill\n' >>"$(clone_of laptop1)/agent/skills/readd/SKILL.md"
hand_digest=$(local_digest "$(clone_of laptop1)/agent/skills/readd")
jq --arg digest "$hand_digest" --arg skill "$(sha256sum "$(clone_of laptop1)/agent/skills/readd/SKILL.md" | cut -d' ' -f1)" \
  '(.skills[] | select(.name == "readd")) |= (.directory_sha256 = $digest | .skill_sha256 = $skill)' \
  "$(clone_of laptop1)/agent/skills.lock.json" >"$DS_TEST_ROOT/lock.new"
mv -- "$DS_TEST_ROOT/lock.new" "$(clone_of laptop1)/agent/skills.lock.json"
by_hand laptop1 "feat: another skill under the old name"
up_to_date laptop2
assert_eq 'skill:readd' "$(waiting laptop2)"
assert_eq '["readd"]' "$(skipped laptop2 skills)"
assert_exit 0 agents laptop2 install --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/readd ]] || ds_fail "it came back without an answer"
assert_exit 0 ds laptop2 incoming answer skill:readd --never
up_to_date laptop1

# Install lands it through one `agents install` and stores no answer: a failure stays a question.
hand_skill laptop1 failing
by_hand laptop1 "feat: a skill that cannot land"
up_to_date laptop2
mkdir -p "$(home_of laptop2)/.agents/skills"
chmod 0555 "$(home_of laptop2)/.agents/skills"
assert_exit 1 ds laptop2 incoming answer skill:failing --install
chmod 0755 "$(home_of laptop2)/.agents/skills"
assert_eq 'skill:failing' "$(waiting laptop2)"
assert_json "$known" 'has("skills") | not'
assert_exit 0 ds laptop2 incoming answer skill:failing --install
assert_eq '' "$(waiting laptop2)"

# M8: a new name on the same machine keeps what waits and what was declined.
captured laptop1 pend1
up_to_date laptop1
captured laptop1 pend2
up_to_date laptop1
up_to_date laptop2
url=$(git -C "$(clone_of laptop2)" remote get-url origin)
git -C "$(clone_of laptop2)" remote set-url origin "$world/gone.git"
assert_exit 0 ds laptop2 incoming answer skill:pend2 --never
git -C "$(clone_of laptop2)" remote set-url origin "$url"
renamed() {
  on laptop2 env DOTSTEWARD_MACHINE=laptop2b "$DS_REPO_ROOT/cli/dotsteward" "$@" </dev/null
}
assert_exit 0 renamed incoming list --json
assert_json - '[.items[].id] | (index("skill:pend1") != null and index("skill:pend2") == null)' <<<"$DS_STDOUT"
assert_exit 0 renamed agents install --profile workstation --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/pend1 ]] || ds_fail "pend1 landed without an answer"
[[ ! -e $(home_of laptop2)/.agents/skills/pend2 ]] || ds_fail "a declined skill landed"
EXPECT_STATUS=3 ds_code laptop2 incoming
assert_contains "$(remote_file hosts/laptop2.toml)" '"pend2"'
assert_exit 0 ds laptop2 incoming answer skill:pend1 --install
up_to_date laptop1

# M7: a third party skill under a name this machine already uses for something of its own: the copy
# stays, and it is a question. A copy from an older pin of the lock is no such thing.
up_to_date laptop1
third=0123456789012345678901234567890123456789
mkdir -p "$(home_of laptop2)/.agents/skills/clash"
printf -- '---\nname: clash\ndescription: mine.\n---\n\nmy own words\n' >"$(home_of laptop2)/.agents/skills/clash/SKILL.md"
hand_skill laptop1 clash "$third"
by_hand laptop1 "feat: a third party skill"
up_to_date laptop2
assert_exit 0 agents laptop2 install --skip-validation
assert_contains "$(<"$(home_of laptop2)/.agents/skills/clash/SKILL.md")" 'my own words'
assert_eq 'skill:clash' "$(waiting laptop2)"
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].change == "clash"' <<<"$DS_STDOUT"
assert_exit 0 agents laptop2 check
assert_exit 0 ds laptop2 incoming answer skill:clash --install
assert_not_contains "$(<"$(home_of laptop2)/.agents/skills/clash/SKILL.md")" 'my own words'
assert_eq 1 "$(find "$(state_of laptop2)/backups" -path '*clash/SKILL.md' | wc -l)" "the backup of the copy"
assert_eq '' "$(waiting laptop2)"

# The producer moved the pin: the old copy of the lock is refreshed without a word.
clone=$(clone_of laptop1)
up_to_date laptop1
printf 'a new upstream version\n' >>"$clone/agent/skills/clash/SKILL.md"
jq --arg digest "$(local_digest "$clone/agent/skills/clash")" --arg skill "$(sha256sum "$clone/agent/skills/clash/SKILL.md" | cut -d' ' -f1)" \
  '(.skills[] | select(.name == "clash")) |= (.directory_sha256 = $digest | .skill_sha256 = $skill)' \
  "$clone/agent/skills.lock.json" >"$DS_TEST_ROOT/lock.new"
mv -- "$DS_TEST_ROOT/lock.new" "$clone/agent/skills.lock.json"
by_hand laptop1 "chore: a new pin"
up_to_date laptop2
assert_eq '' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
assert_contains "$(<"$(home_of laptop2)/.agents/skills/clash/SKILL.md")" 'a new upstream version'

# M10: known only when it was for this machine: a wider scope is a question, tags and profile alike.
clone=$(clone_of laptop1)
mkdir -p "$clone/components/wide" "$clone/components/profiled"
printf '{ ... }: { }\n' >"$clone/components/wide/default.nix"
printf '{ ... }: { }\n' >"$clone/components/profiled/default.nix"
printf '\n[components.wide]\nenable = true\ntags = ["nvidia"]\n\n[components.profiled]\nenable = true\nprofiles = ["workstation"]\n' >>"$clone/workstation.toml"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: scoped\n\nDotsteward-Machine: laptop1'
git -C "$clone" push -q origin main
up_to_date laptop2
assert_exit 0 agents laptop2 install --skip-validation
assert_json "$known" '.components | (index("wide") == null and index("profiled") == null)'
sed -i '/^tags = \["nvidia"\]$/d' "$clone/workstation.toml"
git -C "$clone" add -A
git -C "$clone" commit -q -m $'feat: for everybody\n\nDotsteward-Machine: laptop1'
git -C "$clone" push -q origin main
up_to_date laptop2
assert_contains "$(waiting laptop2)" 'component:wide'
