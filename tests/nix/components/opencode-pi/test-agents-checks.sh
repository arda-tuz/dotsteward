# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The agents checks of opencode-pi end to end (SPEC 3.5, 8.1, 8.2, 8.4): an
# instance enables the component, lib.mkInstance puts its probes and
# checks.agents hooks into the manifest, and `dotsteward agents
# install|check` runs them against the opencode and pi stubs:
#   - the Pi probes: PI_OFFLINE=1 pi --version equals skills:nix_tools.pi,
#     pi --help and pi auth check --help carry their flags;
#   - opencode-version: opencode --version prints a version;
#   - opencode-skill-api: a temporary `opencode serve --pure` on a free
#     loopback port, whose GET /skill must list every expected skill below
#     ~/.agents/skills (outside .system), then the server is stopped;
#   - pi-rpc: `pi --mode rpc --no-session --no-extensions
#     --no-prompt-templates` with PI_OFFLINE=1 and a fresh temporary
#     PI_CODING_AGENT_DIR (removed afterwards) answers get_commands with
#     every expected skill.
# The expected skills are the instance skills lock entries and the framework
# skills of the manifest; a skill either agent does not see fails the check
# with its name.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

op_hermetic_path
ds_use_stubs opencode pi

pi_version=$(jq -r '.versions_lock.agent_tools.pi.version' "$op_seed")
ds_stub_set pi version "$pi_version"
ds_stub_set opencode version 1.18.34

inst=$(op_instance agents)

agents() {
  op_cli "$inst" agents "$1" --profile workstation
}

# --- install, then check: everything visible ----------------------------------------

assert_exit 0 agents install
[[ -f $HOME/.agents/skills/alpha-skill/SKILL.md && -f $HOME/.agents/skills/beta-skill/SKILL.md ]] ||
  ds_fail "agents install did not lay out the skills"
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode 1.18.34 runs"
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (2)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"

: >"$DS_CALL_LOG"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (2)"
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"

# The probes ran with PI_OFFLINE=1.
assert_call_count 1 pi '--version'
assert_call_count 1 pi '--help'
assert_call_count 1 pi 'auth check --help'
# OpenCode: one pure server on a loopback port.
assert_call_count 1 opencode 'serve --pure --hostname 127.0.0.1 --port [0-9]*'
# Pi: one isolated, offline RPC session.
assert_call_count 1 pi '--mode rpc --no-session --no-extensions --no-prompt-templates'
rpc_env=$(ds_env_of pi | sed -n 4p)
[[ $rpc_env == "pi:env PI_OFFLINE=1 PI_CODING_AGENT_DIR="* ]] || ds_fail "unexpected Pi RPC environment: [$rpc_env]"
for line in $(ds_env_of pi | sed -n 1,3p | tr ' ' '_'); do
  [[ $line == pi:env_PI_OFFLINE=1_* ]] || ds_fail "a Pi probe ran without PI_OFFLINE=1: [$line]"
done
config_dir=${rpc_env#*PI_CODING_AGENT_DIR=}
[[ $config_dir == "$TMPDIR"/* ]] || ds_fail "the Pi RPC configuration directory is not temporary: $config_dir"
[[ ! -e $config_dir ]] || ds_fail "the Pi RPC configuration directory was left behind: $config_dir"
# The OpenCode server is gone: nothing listens on its port any more.
port=$(ds_calls_of opencode | grep -Eo -- '--port [0-9]+' | tail -n 1 | cut -d ' ' -f 2)
[[ -n $port ]] || ds_fail "no OpenCode server port in the call log"
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  ds_fail "the OpenCode server still listens on port $port"
fi

# --- A skill OpenCode does not see -------------------------------------------------------

skill=$HOME/.agents/skills/beta-skill/SKILL.md
original=$(<"$skill")
printf -- '---\nname: renamed-skill\ndescription: Renamed.\n---\n' >"$skill"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "OpenCode does not see the skills: beta-skill"
assert_contains "$DS_STDERR" "component opencode-pi hook opencode-skill-api failed (exit 1)"
printf '%s\n' "$original" >"$skill"

# A skill only below a .system subtree does not count. The skill step
# reports it missing; with --keep-going the agents checks still run and
# name it too.
mkdir -p "$HOME/.agents/skills/.system"
mv -- "$HOME/.agents/skills/alpha-skill" "$HOME/.agents/skills/.system/alpha-skill"
assert_exit 1 op_cli "$inst" agents check --profile workstation --keep-going
assert_contains "$DS_STDERR" "skill missing: alpha-skill"
assert_contains "$DS_STDERR" "OpenCode does not see the skills: alpha-skill"
assert_contains "$DS_STDERR" "Pi does not see the skills: alpha-skill"
mv -- "$HOME/.agents/skills/.system/alpha-skill" "$HOME/.agents/skills/alpha-skill"
rmdir -- "$HOME/.agents/skills/.system"
assert_exit 0 agents check

# OpenCode also reads ~/.claude/skills and lists a name found in both roots
# once, from whichever root it loaded last. A link root entry that resolves
# to the canonical skill counts; a separate copy there does not.
mkdir -p "$HOME/.claude/skills"
ln -s ../../.agents/skills/alpha-skill "$HOME/.claude/skills/alpha-skill"
ln -s ../../.agents/skills/beta-skill "$HOME/.claude/skills/beta-skill"
ds_stub_set opencode skill-precedence last
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: OpenCode sees every expected skill (2)"
rm -f -- "$HOME/.claude/skills/beta-skill"
cp -R -- "$HOME/.agents/skills/beta-skill" "$HOME/.claude/skills/beta-skill"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "OpenCode does not see the skills: beta-skill"
rm -rf -- "$HOME/.claude/skills"
ds_stub_set opencode skill-precedence first
assert_exit 0 agents check

# The server fails to start, or answers something else than a list.
ds_stub_set opencode serve-mode exit
assert_exit 1 agents check
assert_contains "$DS_STDERR" "OpenCode skill catalog could not be verified: the OpenCode server exited early (exit 1)"
assert_contains "$DS_STDERR" "opencode: failed to start the server"
ds_stub_set opencode serve-mode not-list
assert_exit 1 agents check
assert_contains "$DS_STDERR" "OpenCode skill catalog could not be verified: GET /skill did not answer a list"
ds_stub_set opencode serve-mode normal

# --- A skill Pi does not see ---------------------------------------------------------------

ds_stub_set pi commands '[{"name": "skill:alpha-skill", "source": "skill"}, {"name": "beta-skill", "source": "prompt"}]'
assert_exit 1 agents check
assert_contains "$DS_STDERR" "Pi does not see the skills: beta-skill"
assert_contains "$DS_STDERR" "component opencode-pi hook pi-rpc failed (exit 1)"
ds_stub_set pi commands '[{"name": "skill:alpha-skill", "source": "skill"}, {"name": "skill:beta-skill", "source": "skill"}, {"name": "skill:gamma-skill", "source": "skill"}]'
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"
rm -f -- "$DS_STUB_STATE/pi/commands"

ds_stub_set pi rpc-mode invalid-json
assert_exit 1 agents check
assert_contains "$DS_STDERR" "Pi RPC answered no valid get_commands response"
ds_stub_set pi rpc-mode exit
assert_exit 1 agents check
assert_contains "$DS_STDERR" "Pi RPC failed (exit 1)"
ds_stub_set pi rpc-mode normal
assert_exit 0 agents check

# --- OpenCode does not run -----------------------------------------------------------------

ds_stub_set opencode version 'not a version'
assert_exit 1 agents check
assert_contains "$DS_STDERR" "OpenCode does not run: opencode --version printed no version"
assert_contains "$DS_STDERR" "component opencode-pi hook opencode-version failed (exit 1)"
ds_stub_set opencode version 1.18.34

# --- Pi probes ---------------------------------------------------------------------------------

ds_stub_set pi version 0.0.1
assert_exit 1 agents check
assert_contains "$DS_STDERR" "pi version mismatch: expected $pi_version, found 0.0.1"
ds_stub_set pi version "$pi_version"
ds_stub_set pi help 'Usage: pi [options]
  --offline   never use the network'
assert_exit 1 agents check
assert_contains "$DS_STDERR" "pi lacks --no-skills"
rm -f -- "$DS_STUB_STATE/pi/help"

# --- Missing commands --------------------------------------------------------------------------

no_stubs() {
  PATH=${PATH#"$DS_TEST_ROOT/bin:"} agents check
}
assert_exit 1 no_stubs
assert_contains "$DS_STDERR" "required command not found: opencode"
