# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The fixtures of these tests describe the machine they run on. `macos-smoke` runs this
# suite natively on darwin, where a fixture that only knows x86_64-linux stops every test at
# `agents install` before it looks at anything. The platform of the CLI is forced here, so
# a Linux runner sees the same fixture: the machine, the mirror and the host file of a
# skill capture are all those of the darwin system.
export DOTSTEWARD_PLATFORM=darwin
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

[[ -f $seed/.dotsteward/manifest.aarch64-darwin.json ]] || ds_fail "the mirror of the instance is the one of the darwin system"
assert_contains "$(<"$seed/workstation.toml")" 'systems = ["aarch64-darwin"]'

new_machine named
ds_code named agents install --profile workstation --skip-validation

jq -n '{schema_version: 1, name: "named", machine_key: "00112233445566778899aabbccddeeff",
  named_at: "2026-01-01T00:00:00Z", host: {system: "aarch64-darwin", profile: "workstation", platform: "macos-26", tags: []}}' \
  >"$(state_of named)/machine.json"
own_new named hosted
settle named hosted
ds_code named skills capture --now
assert_eq hosted "$(remote_entry hosted | jq -r .name)"
assert_contains "$(remote_file hosts/named.toml)" 'system = "aarch64-darwin"'
