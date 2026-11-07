# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A machine set up before this release has no known.json: what it holds is what it
# knows, nothing is asked, and only an install writes the file. A machine without a name
# has no other machines to hear from.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

new_machine laptop1
new_machine laptop2
known=$(state_of laptop2)/machine/known.json

# A third party skill, an own skill, both already in the tree when the file is written.
hand_skill laptop1 vendored 0123456789012345678901234567890123456789
hand_skill laptop1 ours
by_hand laptop1 "feat: skills from before"
up_to_date laptop2

# Nothing asked before the file exists, and a check does not write it.
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 incoming list
agents laptop2 check --keep-going >/dev/null 2>&1 || true
[[ ! -e $known ]] || ds_fail "a check wrote known.json"
assert_exit 0 ds laptop2 skills effective --json
assert_json - '.skip.skills == []' <<<"$DS_STDOUT"

# The first install: it installs all of it as ever and writes the file, mode 0600.
assert_exit 0 agents laptop2 install --skip-validation
[[ -f $(home_of laptop2)/.agents/skills/vendored/SKILL.md ]] || ds_fail "vendored was not installed"
[[ -f $(home_of laptop2)/.agents/skills/ours/SKILL.md ]] || ds_fail "ours was not installed"
assert_eq 600 "$(stat -c %a "$known")"
assert_json "$known" '.skills | has("vendored") and has("ours")'
assert_eq '' "$(waiting laptop2)"

# From then on a new third party skill is a question, like an own skill.
hand_skill laptop1 vendored2 0123456789012345678901234567890123456789
by_hand laptop1 "feat: another skill"
up_to_date laptop2
assert_eq 'skill:vendored2' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/vendored2 ]] || ds_fail "vendored2 was installed without an answer"
assert_exit 0 ds laptop2 incoming answer skill:vendored2 --install
[[ -f $(home_of laptop2)/.agents/skills/vendored2/SKILL.md ]] || ds_fail "vendored2 was not installed"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 agents laptop2 check

# A copy that is already here is no question, whatever the state says.
rm -f -- "$known"
assert_exit 0 agents laptop2 install --skip-validation
hand_skill laptop1 preexisting
by_hand laptop1 "feat: a skill this machine has a copy of"
mkdir -p "$(home_of laptop2)/.agents/skills/preexisting"
cp "$(clone_of laptop1)/agent/skills/preexisting/SKILL.md" "$(home_of laptop2)/.agents/skills/preexisting/"
up_to_date laptop2
assert_eq '' "$(waiting laptop2)"

# No name: no question, no file, and every command acts as it always did.
unnamed=$world/unnamed
mkdir -p "$unnamed/home/.agents/skills" "$unnamed/home/.claude/skills" "$unnamed/home/.codex/skills" "$unnamed/state"
git clone -q "$remote" "$unnamed/clone"
anonymous() {
  (
    # shellcheck disable=SC2031 # each call has its own environment
    export HOME=$unnamed/home DOTSTEWARD_STATE_ROOT=$unnamed/state DOTSTEWARD_INSTANCE=$unnamed/clone
    unset DOTSTEWARD_MACHINE
    cd "$unnamed/clone" || exit
    "$DS_REPO_ROOT/cli/dotsteward" "$@" </dev/null
  )
}
assert_exit 0 anonymous incoming list --json
assert_json - '.machine == null and .items == []' <<<"$DS_STDOUT"
assert_exit 0 anonymous incoming
assert_exit 0 anonymous agents install --profile workstation --skip-validation
[[ -f $unnamed/home/.agents/skills/ours/SKILL.md ]] || ds_fail "without a name every skill is installed"
[[ ! -e $unnamed/state/machine/known.json ]] || ds_fail "a machine without a name wrote known.json"
assert_exit 1 anonymous incoming answer skill:ours --install
assert_contains "$DS_STDERR" "host init"
