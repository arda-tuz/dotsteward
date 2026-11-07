# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# A tree newer than the running CLI: flake.lock pins a framework that knows a key this
# CLI does not. Every command stops at the key, and the message names the way out, the
# CLI the tree pins. It says so only when the two revisions differ: with the same
# revision the key is a plain mistake in the file.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" "$@" </dev/null
}

running=1111111111111111111111111111111111111111
pinned=2222222222222222222222222222222222222222
way_out="$agents_inst/.dotsteward/cli.sh"

pin_framework() {
  jq -n --arg rev "$1" '{
    nodes: {
      root: { inputs: { dotsteward: "dotsteward_2" } },
      dotsteward_2: { locked: { type: "github", rev: $rev } }
    },
    root: "root", version: 7
  }' >"$agents_inst/flake.lock"
}

printf 'rev=%s\nnarHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' "$running" >"$agents_fw/source-info"
pin_framework "$pinned"
printf '\n[a_later_table]\nkey = 1\n' >>"$agents_inst/workstation.toml"

# stops_with_way_out COMMAND...: the command fails on the key and names the way out.
stops_with_way_out() {
  assert_exit "${expected_status:-1}" ds "$@"
  assert_contains "$DS_STDERR" "workstation.toml: unknown key a_later_table"
  assert_contains "$DS_STDERR" "$way_out"
  assert_contains "$DS_STDERR" "${running:0:12}"
  assert_contains "$DS_STDERR" "${pinned:0:12}"
}

stops_with_way_out agents check --profile workstation
stops_with_way_out e2e --profile workstation
stops_with_way_out generate
stops_with_way_out txn status
stops_with_way_out context --json
stops_with_way_out skills effective --json
expected_status=2 stops_with_way_out pins check
assert_exit 2 ds settings status
assert_contains "$DS_STDERR" "$way_out"

# The same revision: the key is a mistake, and the pinned CLI would say the same.
pin_framework "$running"
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "unknown key a_later_table"
assert_not_contains "$DS_STDERR" "cli.sh"

# A CLI without a revision, as in a development checkout: nothing to compare.
pin_framework "$pinned"
rm -- "$agents_fw/source-info"
assert_exit 1 ds agents check --profile workstation
assert_not_contains "$DS_STDERR" "cli.sh"
printf 'rev=%s\n' "$running" >"$agents_fw/source-info"

# The launcher would run the same CLI again.
assert_exit 1 env DOTSTEWARD_CLI="$agents_fw/cli/dotsteward" "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  agents check --profile workstation
assert_not_contains "$DS_STDERR" "cli.sh"
assert_exit 1 env DOTSTEWARD_FRAMEWORK_OVERRIDE=path:/somewhere "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  agents check --profile workstation
assert_not_contains "$DS_STDERR" "cli.sh"

# No flake.lock, or none that names the framework: nothing to compare.
rm -- "$agents_inst/flake.lock"
assert_exit 1 ds agents check --profile workstation
assert_not_contains "$DS_STDERR" "cli.sh"
printf '{"nodes":{"root":{"inputs":{}}},"root":"root","version":7}\n' >"$agents_inst/flake.lock"
assert_exit 1 ds agents check --profile workstation
assert_not_contains "$DS_STDERR" "cli.sh"
printf 'not json\n' >"$agents_inst/flake.lock"
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "unknown key a_later_table"
assert_not_contains "$DS_STDERR" "cli.sh"
pin_framework "$pinned"

# Any other mistake in the file is not the tree's age.
sed -i '/a_later_table/,$d' "$agents_inst/workstation.toml"
cp -- "$agents_inst/workstation.toml" "$DS_TEST_ROOT/good.toml"
sed -i 's/state_version = "26.05"/state_version = 26/' "$agents_inst/workstation.toml"
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "nix.state_version"
assert_not_contains "$DS_STDERR" "cli.sh"
cp -- "$DS_TEST_ROOT/good.toml" "$agents_inst/workstation.toml"

# A host file of a later release says the same.
name_machine laptop
write_host laptop 'a_later_key = 1'
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "hosts/laptop.toml: unknown key a_later_key"
assert_contains "$DS_STDERR" "$way_out"
assert_not_contains "$DS_STDERR" "Traceback"
pin_framework "$running"
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "hosts/laptop.toml: unknown key a_later_key"
assert_not_contains "$DS_STDERR" "cli.sh"
pin_framework "$pinned"
rm -- "$agents_inst/hosts/laptop.toml"

# The keys of this release are known, and a component may not use the two that only a
# later release acts on: the readers refuse them, and that is the tree's age too.
for key in machines tags; do
  cp -- "$DS_TEST_ROOT/good.toml" "$agents_inst/workstation.toml"
  printf '\n[components.example]\nenable = true\n%s = ["laptop"]\n' "$key" >>"$agents_inst/workstation.toml"
  assert_exit 1 ds agents check --profile workstation
  assert_contains "$DS_STDERR" "components.example.$key: expected null"
  assert_contains "$DS_STDERR" "$way_out"
done
# A value of a list a later release has grown.
cp -- "$DS_TEST_ROOT/good.toml" "$agents_inst/workstation.toml"
printf '\n[components.example]\nenable = true\nupdater = "a-later-updater"\n' >>"$agents_inst/workstation.toml"
assert_exit 1 ds agents check --profile workstation
assert_contains "$DS_STDERR" "components.example.updater: expected one of"
assert_contains "$DS_STDERR" "$way_out"
cp -- "$DS_TEST_ROOT/good.toml" "$agents_inst/workstation.toml"
sed -i 's/^\[skills\]$/[skills]\ntracking = true\ncapture_delay_seconds = 30\ncapture_max_mib = 10/' "$agents_inst/workstation.toml"
printf '\n[hosts]\nproducer = "laptop"\n' >>"$agents_inst/workstation.toml"
assert_exit 0 ds skills effective --json
