# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A new series is found and named, no question and no wait, and moves only on the
# owner's word: `--accept series:kernel=<x.y>` or `--accept series:nvidia=<n>`.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

MODULE=linux-modules-nvidia

# A new kernel series on the same binary name: named, and nothing moves.
world_report new-series '{}'
assert_eq 0 "$WORLD_STATUS" "a new series is no decision the run waits for"
plan_applicable
plan_unchanged
plan_item series-available 'and .class == "kernel" and .series == "7.4" and .suite == "noble-updates" and .nvidia_ready == true and .pending == false'
plan_item series-available 'and .accept == "dotsteward upgrade --accept series:kernel=7.4"'
assert_json "$REVIEW" '.items[] | select(.code == "series-available") | .series == "7.4"'

# The word moves it: the new Source of the meta package, the module of the installed series.
world_plan new-series '{"accept": ["series:kernel=7.4"]}'
plan_applicable
assert_json "$PLAN" '.gated.decision == "move"'
plan_target "$K74" "$K74" "$D99"
plan_changes install linux-image-7.4.0-5-generic "$MODULE-595-open-7.4.0-5-generic"
plan_changes upgrade linux-generic-hwe-24.04
assert_json "$PLAN" '[.changes.upgrade[] | select(.name == "linux-generic-hwe-24.04") | .source] == ["linux-meta-hwe-7.4"]'
plan_no_item series-available

# Without a module of the installed NVIDIA series: refused, NVIDIA comes first.
world_report new-series-kernel-only '{"accept": ["series:kernel=7.4"]}'
assert_eq 3 "$WORLD_STATUS"
plan_refused
plan_item apt-denied 'and .class == "series-needs-nvidia" and (.message | test("NVIDIA series first"))'
plan_unchanged

world_plan new-series-kernel-only
plan_applicable
plan_item series-available 'and .class == "kernel" and .nvidia_ready == false'

# A series that does not exist is said, not guessed.
world_plan new-series '{"accept": ["series:kernel=9.9"]}'
plan_refused
plan_item apt-denied 'and .class == "series-unknown"'
world_plan new-series-nvidia '{"accept": ["series:nvidia=700-open"]}'
plan_refused
plan_item apt-denied 'and .class == "series-unknown"'

# A new NVIDIA series: named with its suite and module, from the records (multiverse here,
# as on a real archive), and nothing moves.
world_plan new-series-nvidia
plan_applicable
plan_unchanged
plan_item series-available "and .class == \"nvidia\" and .series == \"615-open\" and .version == \"$D615\" and .suite == \"noble-updates\" and .module == \"$MODULE-615-open-generic-hwe-24.04\" and .retired == false"

# The word moves it: the new stack with its module, the old one goes; no DKMS on the way.
for key in 615-open 615; do
  for mode in all tracked; do
    world_plan new-series-nvidia "{\"mode\": \"$mode\", \"accept\": [\"series:nvidia=$key\"]}"
    plan_applicable
    assert_json "$PLAN" '.gated.decision == "move"'
    plan_target "$K42" "$K42" "$D615"
    plan_changes install nvidia-driver-615-open "$MODULE-615-open-generic-hwe-24.04" "$MODULE-615-open-7.0.0-42-generic" nvidia-firmware-615-615.71.09
    plan_no_change install nvidia-dkms-615-open
    plan_changes remove nvidia-driver-595-open "$MODULE-595-open-generic-hwe-24.04" "$MODULE-595-open-7.0.0-42-generic" "$MODULE-595-open-7.0.0-38-generic"
    assert_json "$PLAN" '[.changes.remove[].reason] | unique == ["series-change"]'
  done
done

# ubuntu-drivers knows the hardware: when it answers, it decides what suits this machine,
# and its recommendation is said next to the highest.
world_ubuntu_drivers '== /sys/devices/pci0000:00/synthetic ==
vendor   : NVIDIA Corporation
driver   : nvidia-driver-615-open - distro non-free
driver   : nvidia-driver-595-open - distro non-free recommended
driver   : xserver-xorg-video-nouveau - distro free builtin'
world_plan new-series-nvidia
plan_item series-available 'and .class == "nvidia" and .series == "615-open" and .recommended == "595-open" and (.message | test("recommended 595-open"))'

# A driver the tool does not list for this hardware is no candidate.
world_ubuntu_drivers 'driver   : nvidia-driver-595-open - distro non-free recommended'
world_plan new-series-nvidia
plan_no_item series-available
