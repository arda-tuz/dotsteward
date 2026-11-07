# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# What applies to this machine: `skills effective` and the commands that act on it.
# An entry with machines is for the machines it names, so a machine without a name
# or with another name never gets it and is never asked; hosts/<name>.toml declines
# entries for one machine. `agents install` leaves those skills out and `agents
# check` and `e2e` do not miss them. A reinstall under the same name brings all of
# it back, and the profile never falls back to a default of the instance.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

# --- an instance that names no machine ------------------------------------------------

assert_eq '{"name":null,"profile":null,"tags":[],"skip":{"components":[],"skills":[],"plugins":[]},"reasons":{},"name_taken":[]}' \
  "$(effective .)"
assert_exit 0 run_skills effective
assert_contains "$DS_STDOUT" "machine: (no name yet)"
assert_exit 0 run_e2e
[[ ! -e $(machine_file) && ! -e $agents_inst/hosts ]] || ds_fail "a check wrote machine state"

# --- entries for named machines ----------------------------------------------------------

lock_add alpha
lock_add beta
lock_add gamma
set_machines alpha '["laptop"]'
write_host laptop 'tags = ["nvidia", "small"]'
write_host desktop 'declined = { skills = ["gamma"], plugins = ["declined-tool@market"] }'
{
  printf '\n[components.example]\nenable = true\n'
  printf '[[components.example.options.plugins]]\nspec = "scoped-tool@market"\nmachines = ["laptop"]\n'
  printf '[[components.example.options.plugins]]\nspec = "declined-tool@market"\n'
  printf '[[components.example.options.plugins]]\nspec = "shared-tool@market"\n'
} >>"$agents_inst/workstation.toml"
mkdir -p "$agents_inst/components/example"

# Without a name: what names a machine is not for this one.
assert_eq '["alpha"]' "$(effective .skip.skills)"
assert_eq '["scoped-tool@market"]' "$(effective .skip.plugins)"
assert_eq '{"plugin:scoped-tool@market":"machines","skill:alpha":"machines"}' "$(effective .reasons)"
assert_exit 0 run_agents install
[[ ! -e $HOME/.agents/skills/alpha ]] || ds_fail "agents install took a skill of another machine"
[[ -f $HOME/.agents/skills/beta/SKILL.md && -f $HOME/.agents/skills/gamma/SKILL.md ]] ||
  ds_fail "agents install left out a skill of every machine"
publish_instance
assert_exit 0 run_agents check
assert_exit 0 run_e2e

# Another machine: never gets it, and what it declines stays away too.
name_machine desktop
assert_eq '"desktop"' "$(effective .name)"
assert_eq '"workstation"' "$(effective .profile)"
assert_eq '["alpha","gamma"]' "$(effective .skip.skills)"
assert_eq '["declined-tool@market","scoped-tool@market"]' "$(effective .skip.plugins)"
assert_eq '{"plugin:declined-tool@market":"declined","plugin:scoped-tool@market":"machines","skill:alpha":"machines","skill:gamma":"declined"}' \
  "$(effective .reasons)"
rm -rf -- "$HOME/.agents/skills/gamma" "$HOME/.claude/skills/gamma"
assert_exit 0 run_agents install
[[ ! -e $HOME/.agents/skills/gamma ]] || ds_fail "agents install took a declined skill"
assert_exit 0 run_e2e
assert_exit 0 run_skills effective
assert_contains "$DS_STDOUT" "skills left out: alpha (machines), gamma (declined)"

# The machine it is for gets it: no question, and the tags and profile of its file.
name_machine laptop
assert_eq '[]' "$(effective .skip.skills)"
assert_eq '[]' "$(effective .skip.plugins)"
assert_eq '["nvidia","small"]' "$(effective .tags)"
assert_exit 0 run_agents install
[[ -f $HOME/.agents/skills/alpha/SKILL.md && -f $HOME/.agents/skills/gamma/SKILL.md ]] ||
  ds_fail "agents install left out a skill of this machine"
assert_exit 0 run_e2e

# DOTSTEWARD_MACHINE replaces the file, and is checked.
assert_eq '"desktop"' "$(DOTSTEWARD_MACHINE=desktop effective .name)"
assert_exit 1 env DOTSTEWARD_MACHINE=Not_A_Name "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills effective --json
assert_contains "$DS_STDERR" "DOTSTEWARD_MACHINE: invalid machine name"
assert_exit 1 env DOTSTEWARD_MACHINE=Not_A_Name "$agents_fw/cli/dotsteward" --instance "$agents_inst" agents check --profile workstation
assert_contains "$DS_STDERR" "DOTSTEWARD_MACHINE: invalid machine name"

# --- a reinstall under the same name -------------------------------------------------------

rm -- "$(machine_file)"
assert_eq '["alpha"]' "$(effective .skip.skills)"
name_machine desktop
assert_eq '["alpha","gamma"]' "$(effective .skip.skills)"

# --- the name is taken ------------------------------------------------------------------------

# This machine has a skill of its own under a name the lock keeps for another one.
assert_eq '["alpha"]' "$(effective .name_taken)"
rm -rf -- "$HOME/.agents/skills/alpha" "$HOME/.claude/skills/alpha"
assert_eq '[]' "$(effective .name_taken)"
make_skill "$HOME/.codex/skills/alpha" alpha
assert_eq '["alpha"]' "$(effective .name_taken)"
assert_exit 0 run_skills effective
assert_contains "$DS_STDOUT" "name taken: alpha"
rm -rf -- "$HOME/.codex/skills/alpha"

# The roots are those of this system, whatever other mirrors the instance holds.
jq '.skill_layout.legacy_roots = ["~/.elsewhere/skills"]' "$agents_manifest" >"$agents_inst/.dotsteward/manifest.aarch64-darwin.json"
make_skill "$HOME/.codex/skills/alpha" alpha
assert_eq '["alpha"]' "$(effective .name_taken)"
rm -rf -- "$HOME/.codex/skills/alpha"
make_skill "$HOME/.elsewhere/skills/alpha" alpha
assert_eq '[]' "$(effective .name_taken)"
rm -rf -- "$HOME/.elsewhere" "$agents_inst/.dotsteward/manifest.aarch64-darwin.json"

# --- the profile -----------------------------------------------------------------------------

# Never profiles.default: the host file, then the record, then the last rebuild.
rm -- "$(machine_file)"
assert_eq 'null' "$(effective .profile)"
mkdir -p "$DOTSTEWARD_STATE_ROOT/current"
printf 'gone\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
assert_eq 'null' "$(effective .profile)"
printf 'fresh\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
assert_eq '"fresh"' "$(effective .profile)"
name_machine desktop '.host.profile = "workstation"'
assert_eq '"workstation"' "$(effective .profile)"
write_host desktop 'profile = "fresh"'
assert_eq '"fresh"' "$(effective .profile)"
rm -- "$DOTSTEWARD_STATE_ROOT/current/profile"

# --- broken state stops the commands with a message --------------------------------------------

printf 'not json\n' >"$(machine_file)"
assert_exit 1 run_skills effective --json
assert_contains "$DS_STDERR" "machine.json"
assert_contains "$DS_STDERR" "dotsteward host init"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "machine.json"
name_machine desktop

# A host file with an unknown key: only this machine's file is read here.
write_host laptop 'nonsense = 1'
assert_exit 0 run_skills effective --json
write_host desktop 'nonsense = 1'
assert_exit 1 run_skills effective --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: hosts/desktop.toml: unknown key nonsense"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "hosts/desktop.toml: unknown key nonsense"
write_host desktop 'tags = ["Bad Tag"]'
assert_exit 1 run_skills effective --json
assert_contains "$DS_STDERR" "hosts/desktop.toml: tags[0]:"
write_host desktop 'this is not toml'
assert_exit 1 run_skills effective --json
assert_contains "$DS_STDERR" "hosts/desktop.toml: invalid TOML"
write_host desktop

# All of these are messages for every command, never a Python traceback.
no_traceback() {
  assert_exit 1 run_agents check
  assert_contains "$DS_STDERR" "$1"
  assert_not_contains "$DS_STDERR" "Traceback"
  assert_exit 1 run_e2e
  assert_not_contains "$DS_STDERR" "Traceback"
  assert_exit 1 run_skills effective
  assert_not_contains "$DS_STDERR" "Traceback"
}
printf 'not json\n' >"$(machine_file)"
no_traceback "[dotsteward] ERROR: cannot read $(machine_file)"
name_machine desktop
write_host desktop 'nonsense = 1'
no_traceback "[dotsteward] ERROR: hosts/desktop.toml: unknown key nonsense"
write_host desktop
assert_exit 1 env DOTSTEWARD_MACHINE=Not_A_Name "$agents_fw/cli/dotsteward" --instance "$agents_inst" agents check --profile workstation </dev/null
assert_contains "$DS_STDERR" "[dotsteward] ERROR: DOTSTEWARD_MACHINE: invalid machine name"
assert_not_contains "$DS_STDERR" "Traceback"

# A lock that cannot be read is the business of the commands that need it.
cp -- "$agents_lock" "$DS_TEST_ROOT/lock.json"
printf 'not json\n' >"$agents_lock"
assert_eq '[]' "$(effective .skip.skills)"
assert_exit 1 run_agents check --json
assert_json - '.findings[0].code == "lock-invalid"' <<<"$DS_STDOUT"
cp -- "$DS_TEST_ROOT/lock.json" "$agents_lock"

# --- usage ---------------------------------------------------------------------------------

assert_exit 2 run_skills
assert_exit 2 run_skills bogus
assert_exit 0 run_skills effective --help
assert_contains "$DS_STDOUT" "--json"
