# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward host show` and `host list`: this machine, and the machines this checkout
# registers. Both read only.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

# No name, no machine.
assert_exit 1 run_host show
assert_contains "$DS_STDERR" "no name yet"
assert_exit 1 run_host show --json
assert_json - '.name == null' <<<"$DS_STDOUT"
assert_exit 0 run_host list
assert_contains "$DS_STDOUT" "no machine is registered"
assert_exit 0 run_host list --json
assert_json - '.this == null and .producer == null and .machines == []' <<<"$DS_STDOUT"
[[ ! -e $(machine_file) && ! -e $agents_inst/hosts ]] || ds_fail "a report wrote machine state"

# A name that is not registered yet.
name_machine laptop '.host.tags = ["small"]'
assert_exit 0 run_host show
assert_contains "$DS_STDOUT" "machine: laptop"
assert_contains "$DS_STDOUT" "tags: small"
assert_contains "$DS_STDOUT" "not in this checkout"
assert_exit 0 run_host show --json
assert_json - '.name == "laptop" and .registered == false and .producer == false and .host.platform == "ubuntu-24.04"
  and .file == "hosts/laptop.toml" and (.machine_key | not)' <<<"$DS_STDOUT"

# Registered machines, the producer among them.
write_host laptop 'system = "x86_64-linux"
profile = "workstation"
platform = "ubuntu-24.04"
tags = ["small"]'
write_host desktop 'profile = "fresh"'
printf '\n[hosts]\nproducer = "desktop"\n' >>"$agents_inst/workstation.toml"
assert_exit 0 run_host show --json
assert_json - '.registered == true and .producer == false' <<<"$DS_STDOUT"
assert_exit 0 run_host list
assert_contains "$DS_STDOUT" "laptop: x86_64-linux workstation ubuntu-24.04 small (this machine)"
assert_contains "$DS_STDOUT" "desktop: fresh (producer)"
assert_exit 0 run_host list --json
assert_json - '.this == "laptop" and .producer == "desktop" and ([.machines[].name] == ["desktop", "laptop"])
  and (.machines[1] | .this and (.producer | not) and .tags == ["small"])' <<<"$DS_STDOUT"

# DOTSTEWARD_MACHINE counts here too.
assert_exit 0 env DOTSTEWARD_MACHINE=desktop "$agents_fw/cli/dotsteward" --instance "$agents_inst" host show --json </dev/null
assert_json - '.name == "desktop" and .producer == true and .host == null' <<<"$DS_STDOUT"

# Usage.
assert_exit 2 run_host
assert_exit 2 run_host bogus
assert_exit 2 run_host show --bogus
assert_exit 0 run_host --help
for subcommand in init publish show list rename producer check; do
  assert_contains "$DS_STDOUT" "$subcommand"
done
