# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The read only analysis of the apt channel: what else could be upgraded, outside the
# tracked set; what phasing defers; the kernels and the free space of /boot. It changes
# nothing, and it does not see the gated classes as upgradable.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

world_analysis tracked "{\"tracked\": [\"example-tracked\"], \"boot_path\": \"$DS_TEST_ROOT\"}"
assert_json "$ANALYSIS" '.schema_version == 1 and .available == true'
assert_json "$ANALYSIS" '.count == 3 and ([.packages[].name] == ["example-lib", "example-other", "linux-libc-dev"])'
assert_json "$ANALYSIS" '.packages[] | select(.name == "example-lib") | .phased == true and .current == "1.0-1" and .candidate == "2.0-1"'
assert_json "$ANALYSIS" '.packages[] | select(.name == "example-other") | .phased == false and .origin == "Ubuntu/noble-updates"'
assert_json "$ANALYSIS" '.kernels == 2'
assert_json "$ANALYSIS" '(.boot_free_mib | type) == "number" and .boot_low == false'
assert_json "$ANALYSIS" '(.last_update | test("^[0-9-]+T[0-9:]+Z$"))'

# Below the threshold it warns and deletes nothing.
world_analysis tracked "{\"boot_path\": \"$DS_TEST_ROOT\", \"boot_low_mib\": 999999999}"
assert_json "$ANALYSIS" '.boot_low == true'
world_analysis tracked '{"boot_path": "/nonexistent/boot"}'
assert_json "$ANALYSIS" '.boot_free_mib == null and .boot_low == false'

# New kernels and drivers wait for the shared target: the analysis is not the way around it.
world_analysis same-string '{}'
assert_json "$ANALYSIS" '.count == 0'
world_analysis driver-ahead '{}'
assert_json "$ANALYSIS" '.count == 0'

# Read only: the status file and the lists of the world are what they were.
world_up tracked
before=$(sha256sum "$WORLD/var/lib/dpkg/status")
world_analysis tracked '{}'
world_plan tracked
assert_eq "$before" "$(sha256sum "$WORLD/var/lib/dpkg/status")"
[[ ! -e $WORLD/etc/apt/preferences.d/60dotsteward ]] || ds_fail "a plan wrote the pin file"

# What apt autoremove would take is counted, never removed.
world_analysis tracked
assert_json "$ANALYSIS" '.autoremovable | type == "number"'
