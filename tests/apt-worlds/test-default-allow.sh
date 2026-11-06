# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# New packages that an upgrade pulls in are allowed: the real plans of a machine
# hold split firmware, soname transitions and the versioned firmware of each driver.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

# linux-firmware split into new packages.
world_report firmware-split '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install linux-firmware-intel-graphics linux-firmware-misc
plan_changes upgrade linux-firmware
assert_json "$PLAN" '[.changes.install[] | select(.name == "linux-firmware-misc") | .class] == ["firmware"]'
assert_json "$PLAN" '[.changes.install[] | select(.name == "linux-firmware-misc") | .auto] == [true]'

# A soname transition in a vendor repository: new libraries, the old one stays.
world_report soname '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install libgeos3.15.0 libgdal39
plan_changes upgrade postgis-tool
assert_json "$PLAN" '[.changes.install[] | select(.name == "libgeos3.15.0") | .origin] == ["Example Vendor/noble-vendor"]'
assert_json "$PLAN" '.changes.remove == []'

# A library transition: the old name goes for a new name of the same Source.
world_report same-source-removal '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install libexample-new1t64
assert_json "$PLAN" '[.changes.remove[] | select(.name == "example-lib") | .reason] == ["same-source"]'

# The versioned firmware of a driver move is a new package of a gated Source, and passes.
world_report driver-respin '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install nvidia-firmware-595-595.106.01

# Kernels bring their own new packages at every ABI; none of them is refused.
world_report same-string '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install linux-headers-7.0.0-44-generic linux-hwe-7.0-headers-7.0.0-44 linux-main-modules-zfs-7.0.0-44-generic
