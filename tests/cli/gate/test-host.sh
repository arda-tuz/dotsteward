# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# E19: the gate builds and probes the configuration of this machine when the tree knows it,
# and records which machine and which tags that generation is for.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

record=$gate_state/generation.json
empty_tags=$(printf '' | sha256sum | cut -d' ' -f1)

host_configurations() {
  ds_stub_clear_routes nix
  ds_stub_route nix 'eval *#hostConfigurations*' --stdout "$1" --exit "$2"
}
host_configurations '["laptop"]' 0

ds_use_stubs nix curl
serve_cache

# No name: the check profile, as ever.
assert_exit 0 run_gate
assert_contains "$(<"$DS_CALL_LOG")" '#checks.x86_64-linux.home'
assert_eq null "$(jq -r .host "$record")"
assert_eq "$empty_tags" "$(jq -r .tags_sha256 "$record")"

# A name whose file is in the tree: its configuration, its profile, its tags.
mkdir -p "$gate_inst/hosts"
cat >"$gate_inst/hosts/laptop.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
tags = ["nvidia"]
TOML
commit_all "chore: a host"
publish_base
jq -n '{schema_version: 1, name: "laptop", machine_key: "00", named_at: "2026-01-01T00:00:00Z",
  host: {system: "x86_64-linux", profile: "workstation", platform: "ubuntu-24.04", tags: []}}' \
  >"$DOTSTEWARD_STATE_ROOT/machine.json"
: >"$DS_CALL_LOG"
assert_exit 0 run_gate
assert_contains "$(<"$DS_CALL_LOG")" '#hostConfigurations.laptop.activationPackage'
assert_eq laptop "$(jq -r .host "$record")"
assert_eq "$(printf '%s\n%s' 'machine:laptop' nvidia | sha256sum | cut -d' ' -f1)" "$(jq -r .tags_sha256 "$record")"

# An older pin has no such output: the check profile again, and nothing fails.
host_configurations '' 1
printf 'more\n' >>"$gate_inst/docs/guide.md"
commit_all "docs: a new tree"
publish_base
: >"$DS_CALL_LOG"
assert_exit 0 run_gate
assert_contains "$(<"$DS_CALL_LOG")" '#checks.x86_64-linux.home'
assert_eq null "$(jq -r .host "$record")"
assert_eq "$empty_tags" "$(jq -r .tags_sha256 "$record")"
host_configurations '["laptop"]' 0

# A machine of another system, or one the tree does not know, has no configuration to build.
sed -i 's/^system = .*/system = "aarch64-darwin"/' "$gate_inst/hosts/laptop.toml"
sed -i 's/^systems = .*/systems = ["x86_64-linux", "aarch64-darwin"]/' "$gate_inst/workstation.toml"
commit_all "chore: another system"
publish_base
: >"$DS_CALL_LOG"
assert_exit 0 run_gate
assert_contains "$(<"$DS_CALL_LOG")" '#checks.x86_64-linux.home'
