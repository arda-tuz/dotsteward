# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `contribute start` on a machine that is not the producer of the instance is refused before any
# write: contribute upgrade moves flake.lock, which only the producer writes, so the refusal would
# otherwise come only after the publish. It names the producer and `dotsteward host producer`. The
# producer starts, and so does a machine without a name or an instance without a producer.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

# name_machine NAME: <state>/machine.json as `host init` writes it.
name_machine() {
  mkdir -p "$DOTSTEWARD_STATE_ROOT"
  jq -n --arg name "$1" '{
    schema_version: 1, name: $name, machine_key: "00112233445566778899aabbccddeeff",
    named_at: "2026-01-01T00:00:00Z",
    host: {system: "x86_64-linux", profile: "main", platform: "ubuntu-24.04", tags: []}
  }' >"$DOTSTEWARD_STATE_ROOT/machine.json"
}

write_denylist
setup_owner
mkdir -p "$ct_inst/hosts"
printf 'schema_version = 1\n' >"$ct_inst/hosts/example-host.toml"
printf 'schema_version = 1\n' >"$ct_inst/hosts/other-host.toml"
write_instance owner '[hosts]' 'producer = "other-host"'
name_machine example-host

assert_exit 1 run_contribute start --slug add-feature
assert_contains "$DS_STDERR" "other-host is the producer"
assert_contains "$DS_STDERR" "dotsteward host producer example-host"
[[ ! -e $ct_runs ]] || ds_fail "start wrote state on a machine that is not the producer"
if git -C "$ct_clone" show-ref --verify --quiet refs/heads/fix/add-feature; then
  ds_fail "start made a branch on a machine that is not the producer"
fi

# The producer starts.
write_instance owner '[hosts]' 'producer = "example-host"'
assert_exit 0 run_contribute start --slug add-feature
assert_contains "$DS_STDOUT" "[dotsteward] started run"
