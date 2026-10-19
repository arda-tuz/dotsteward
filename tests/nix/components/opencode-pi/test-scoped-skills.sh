# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Skills scoped to OpenCode and Pi end to end: the component declares the
# agent roots opencode (~/.config/opencode/skills) and pi
# (~/.pi/agent/skills) in the manifest; `dotsteward agents install` copies a
# skills lock entry with agents into the scoped skill store and links it
# from those roots only, and the agents checks expect from each agent
# exactly the shared skills plus the skills scoped to it. The Pi RPC check
# sees Pi's own skill root through its temporary configuration directory.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

op_hermetic_path
ds_use_stubs opencode pi

pi_version=$(jq -r '.versions_lock.agent_tools.pi.version' "$op_seed")
ds_stub_set pi version "$pi_version"
ds_stub_set opencode version 1.18.34

inst=$(op_instance scoped)

# Two more vendored skills: one for OpenCode and Pi, one for Pi only.
for skill in both-skill pi-skill; do
  mkdir -p "$inst/agent/skills/$skill"
  printf -- '---\nname: %s\ndescription: Synthetic skill %s.\n---\n\nSynthetic.\n' "$skill" "$skill" \
    >"$inst/agent/skills/$skill/SKILL.md"
done
sha() { sha256sum "$inst/agent/skills/$1/SKILL.md" | cut -d ' ' -f 1; }
jq --indent 2 --arg both "$(sha both-skill)" --arg pi "$(sha pi-skill)" \
  '.skills += [{ name: "both-skill", directory: "both-skill", skill_sha256: $both, agents: ["opencode", "pi"] },
               { name: "pi-skill", directory: "pi-skill", skill_sha256: $pi, agents: ["pi"] }]
   | .expected_skill_count = (.skills | length)' \
  "$inst/agent/skills.lock.json" >"$inst/agent/skills.lock.json.new"
mv -- "$inst/agent/skills.lock.json.new" "$inst/agent/skills.lock.json"

assert_json "$inst/.dotsteward/manifest.x86_64-linux.json" \
  '.skill_layout.agent_roots == { "opencode": "~/.config/opencode/skills", "pi": "~/.pi/agent/skills" }'

agents() {
  op_cli "$inst" agents "$1" --profile workstation
}

store=$HOME/.local/share/dotsteward/scoped-skills
assert_exit 0 agents install
assert_symlink_to "$HOME/.config/opencode/skills/both-skill" "$store/both-skill"
assert_symlink_to "$HOME/.pi/agent/skills/both-skill" "$store/both-skill"
assert_symlink_to "$HOME/.pi/agent/skills/pi-skill" "$store/pi-skill"
for absent in "$HOME/.config/opencode/skills/pi-skill" "$HOME/.agents/skills/both-skill" "$HOME/.agents/skills/pi-skill"; do
  [[ ! -e $absent && ! -L $absent ]] || ds_fail "$absent must not exist"
done
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (3)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (4)"

assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (3)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (4)"
# The temporary Pi configuration directory linked only the skill root and is gone.
config_dir=$(ds_env_of pi | sed -n 4p)
config_dir=${config_dir#*PI_CODING_AGENT_DIR=}
[[ ! -e $config_dir ]] || ds_fail "the Pi RPC configuration directory was left behind: $config_dir"
[[ -d $HOME/.pi/agent/skills/pi-skill ]] || ds_fail "the cleanup left Pi's own skill root alone"

# A scoped skill the agent does not see fails the check with its name.
rm -- "$HOME/.pi/agent/skills/pi-skill"
assert_exit 1 op_cli "$inst" agents check --profile workstation --keep-going
assert_contains "$DS_STDERR" "skill link missing: $HOME/.pi/agent/skills/pi-skill"
assert_contains "$DS_STDERR" "Pi does not see the skills: pi-skill"
assert_exit 0 agents install
assert_exit 0 agents check
