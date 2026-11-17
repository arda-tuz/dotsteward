# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# options.opencode = false of opencode-pi: an instance keeps Pi without
# OpenCode. The component then installs only the Nix package pi (method
# nix, which it chooses by itself) and declares nothing of OpenCode: no
# opencode command, no OpenCode agents checks, no settings target opencode,
# no skill root opencode, no OpenCode release pins and no latest rows. The
# agents checks pass on a machine without any opencode on PATH, and a lock
# without the OpenCode release pins passes the pins check. The option is
# refused unless it is a boolean, and with a method that installs OpenCode.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

op_hermetic_path
ds_use_stubs pi
ds_stub_set pi version "$(jq -r '.versions_lock.agent_tools.pi.version' "$op_seed")"
command -v opencode >/dev/null && ds_fail "an opencode is still on PATH: $(command -v opencode)"

inst=$(OP_METHOD='' op_instance without-opencode 'options = { opencode = false }')
manifest=$inst/.dotsteward/manifest.x86_64-linux.json
[[ -f $manifest ]] || ds_fail "no manifest mirror in $inst/.dotsteward"

# --- The manifest: Pi only ----------------------------------------------------------

of_component='map(select(.component == "opencode-pi"))'
assert_eq '"nix"' "$(jq '.components[] | select(.name == "opencode-pi") | .method' "$manifest")" "method"
assert_eq '{"packages":["pi"]}' "$(jq -c '.components[] | select(.name == "opencode-pi") | .install' "$manifest")" \
  "install block"
assert_eq '["pi"]' "$(jq -c ".checks.commands | $of_component | map(.command)" "$manifest")" "commands"
assert_eq '["pi-rpc"]' "$(jq -c ".checks.agents | $of_component | map(.name)" "$manifest")" "agents checks"
assert_eq '["pi"]' "$(jq -c ".probes | $of_component | map(.command) | unique" "$manifest")" "probes"
assert_eq '["pi-mcp"]' "$(jq -c '.settings_targets | keys' "$manifest")" "settings targets"
assert_eq '["pi"]' "$(jq -c '.skill_layout.agent_roots | keys' "$manifest")" "skill agent roots"
assert_eq '[]' "$(jq -c ".pins.rules | $of_component | map(.name) | map(select(test(\"opencode\")))" "$manifest")" \
  "no OpenCode pin rules"
assert_eq '["agent_tools.pi"]' "$(jq -c ".pins.latest | $of_component | map(.id)" "$manifest")" "latest rows"
if grep -q 'opencode' <(jq -c '[.components, .checks, .probes, .settings_targets, .skill_layout, .pins]' "$manifest"); then
  ds_fail "the manifest still names OpenCode: $(jq -c '[.. | strings | select(test("opencode"))] | unique' "$manifest")"
fi

# --- The agents checks, with no opencode anywhere -------------------------------------

agents() {
  op_cli "$inst" agents "$1" --profile workstation
}
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"
assert_not_contains "$DS_STDOUT" "OpenCode"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "opencode-pi: Pi sees every expected skill (2)"
assert_not_contains "$DS_STDOUT$DS_STDERR" "OpenCode"

# --- The lock needs no OpenCode release pin ---------------------------------------------

jq 'del(.agent_tools.opencode, .agent_tools["opencode-darwin"])' "$inst/versions.lock.json" >"$DS_TEST_ROOT/lock.json"
cp -- "$DS_TEST_ROOT/lock.json" "$inst/versions.lock.json"
assert_exit 0 op_cli "$inst" pins check

# --- Refused configurations -----------------------------------------------------------

refused() {
  local dir
  dir=$(instance_copy "$inst")
  sed -i "s/^options = .*/$2/" "$dir/workstation.toml"
  [[ -z $3 ]] || printf '%s\n' "$3" >>"$dir/workstation.toml"
  assert_inst_fails "(instance { root = /. + \"$dir\"; }).dotstewardMirrors" "dotsteward: component opencode-pi: $1"
}
refused 'options.opencode must be true or false, got "no"' 'options = { opencode = "no" }'
refused 'unknown option opencod (known: opencode)' 'options = { opencod = false }'
refused 'options.opencode = false installs no OpenCode, so the method must be nix (leave method and method_by_platform unset), got external' \
  'options = { opencode = false }' 'method = "external"'
