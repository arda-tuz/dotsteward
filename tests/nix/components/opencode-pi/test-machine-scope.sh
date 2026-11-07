# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# What OpenCode and Pi must discover follows this machine: the agents checks read
# the skills lock themselves, and a skill for another machine, or one this machine
# declined, is not installed here, so they must not miss it.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

# Every script of the catalog that reads the skills lock itself follows this machine.
while IFS= read -r reader; do
  grep -q 'DS_SKIP_SKILLS_JSON' "$reader" || ds_fail "${reader#"$DS_REPO_ROOT"/} reads the skills lock and misses DS_SKIP_SKILLS_JSON"
done < <(grep -rlE 'DS_SKILLS_LOCK|skills\.lock\.json' "$DS_REPO_ROOT/modules" --include='*.sh' --include='*.py')

op_hermetic_path
ds_use_stubs opencode pi
ds_stub_set pi version "$(jq -r '.versions_lock.agent_tools.pi.version' "$op_seed")"
ds_stub_set opencode version 1.18.34

inst=$(op_instance scoped)

agents() {
  op_cli "$inst" agents "$1" --profile workstation
}

jq '(.skills[] | select(.name == "alpha-skill")).machines = ["laptop"]' "$inst/agent/skills.lock.json" \
  >"$DS_TEST_ROOT/lock.json"
cp -- "$DS_TEST_ROOT/lock.json" "$inst/agent/skills.lock.json"
mkdir -p "$inst/hosts"
printf 'schema_version = 1\n' >"$inst/hosts/laptop.toml"
printf 'schema_version = 1\ndeclined = { skills = ["beta-skill"] }\n' >"$inst/hosts/desktop.toml"

# Without a name: the skill for the laptop is not here, and nobody misses it.
assert_exit 0 agents install
[[ ! -e $HOME/.agents/skills/alpha-skill ]] || ds_fail "agents install took a skill of another machine"
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (1)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (1)"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (1)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (1)"

# The machine it is for must see it.
export DOTSTEWARD_MACHINE=laptop
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine/known.json" # a new start under this name
assert_exit 1 agents check
assert_contains "$DS_STDERR" "skill"
assert_exit 0 agents install
[[ -f $HOME/.agents/skills/alpha-skill/SKILL.md ]] || ds_fail "agents install left out a skill of this machine"
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (2)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"
assert_exit 0 agents check

# A machine that declined a skill: neither is expected.
export DOTSTEWARD_MACHINE=desktop
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine/known.json" # a new start under this name
rm -rf -- "$HOME/.agents/skills/alpha-skill" "$HOME/.agents/skills/beta-skill"
assert_exit 0 agents install
[[ ! -e $HOME/.agents/skills/beta-skill ]] || ds_fail "agents install took a declined skill"
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (0)"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (0)"
