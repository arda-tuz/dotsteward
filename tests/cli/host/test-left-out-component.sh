# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A component that is not active on this machine is expected nowhere: not its managed links, not
# its settings targets, not its hooks. One predicate, whatever left it out: machines, tags, a
# declined entry, a question without an answer, or a profile. An active component is still held
# to all of it, so the E2E stays able to fail.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example external "$none"
add_component witness external "$none"
manifest_edit '
  .managed_links = ["~/.example/AGENTS.md"]
  | (.components[] | select(.name == "example")).managed_links = ["~/.example/AGENTS.md"]
  | .settings_targets = {
      "example-config": {component: "example", path: "~/.example/config.json", format: "json",
        backup: true, create_if_missing: false, create_mode: "0644", reload: null}}'
write_buffer <<'TOML'
schema_version = 1

[[entries]]
id = "example-theme"
target = "example-config"
key = ["theme"]
value = "dark"
TOML
publish_instance
assert_exit 0 run_agents install

# Active: held to its link and its target.
assert_exit 1 run_e2e --json --keep-going
assert_contains "$(findings)" '"managed-link-missing"'
assert_contains "$DS_STDOUT" 'example-theme'

# For another machine.
sed -i 's/^\[components.example\]$/[components.example]\nmachines = ["laptop"]/' "$agents_inst/workstation.toml"
grep -q '^machines = \["laptop"\]$' "$agents_inst/workstation.toml" || ds_fail "no table of the component"
write_host laptop
write_host desktop
publish_instance
name_machine desktop
assert_eq '["example"]' "$(effective .skip.components)"
assert_exit 0 run_e2e
assert_exit 0 run_agents check

# The machine it is for: held to it again.
name_machine laptop
assert_eq '[]' "$(effective .skip.components)"
assert_exit 1 run_e2e --json --keep-going
assert_contains "$(findings)" '"managed-link-missing"'

# Declined here.
sed -i '/^machines = \["laptop"\]$/d' "$agents_inst/workstation.toml"
write_host desktop 'declined = { components = ["example"] }'
publish_instance
name_machine desktop
assert_eq '{"component:example":"declined"}' "$(effective .reasons)"
assert_exit 0 run_e2e

# Scoped by a tag this machine does not carry.
sed -i 's/^\[components.example\]$/[components.example]\ntags = ["nvidia"]/' "$agents_inst/workstation.toml"
write_host desktop
publish_instance
assert_eq '{"component:example":"tags"}' "$(effective .reasons)"
assert_exit 0 run_e2e

# Another profile: the same root, older than machines.
sed -i '/^tags = \["nvidia"\]$/d' "$agents_inst/workstation.toml"
sed -i 's/^\[components.example\]$/[components.example]\nprofiles = ["fresh"]/' "$agents_inst/workstation.toml"
manifest_edit '(.components[] | select(.name == "example")) |= (.profiles = ["fresh"] | .modes = {fresh: "fresh"})'
publish_instance
assert_exit 0 run_e2e
assert_exit 1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile fresh --json --keep-going </dev/null
assert_contains "$(findings)" '"managed-link-missing"'
