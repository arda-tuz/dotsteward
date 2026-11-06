# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Kernel, module meta package and driver are one target, all or nothing, read
# from the records and not from version strings: every row of the real history, on a
# real apt with the Depends and Source of the real packages.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

MODULE=linux-modules-nvidia-595-open
META=linux-generic-hwe-24.04

# Nothing new: the gated classes stay, and the pin says what dpkg has.
world_plan no-change
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "no-move"'
plan_target "$K42" "$K42" "$D99"

# The new kernel with its module at the same string: all moves, nothing goes.
world_plan same-string
plan_applicable
assert_json "$PLAN" '.gated.decision == "move"'
plan_target "$K44" "$K44" "$D99"
plan_changes install linux-image-7.0.0-44-generic "$MODULE-7.0.0-44-generic" linux-modules-7.0.0-44-generic
plan_changes upgrade "$META" linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 "$MODULE-generic-hwe-24.04"
assert_json "$PLAN" '.changes.remove == []'

# The module meta package at `...+1` belongs to the kernel without `+1`. A rule on
# version strings skips this kernel; the Depends chain does not.
world_plan plus-n
plan_applicable
plan_target "$K44" "$K44+1" "$D99"
plan_changes install linux-image-7.0.0-44-generic "$MODULE-7.0.0-44-generic"
assert_json "$PLAN" "[.changes.upgrade[] | select(.name == \"$MODULE-generic-hwe-24.04\") | .version] == [\"$K44+1\"]"
assert_json "$PLAN" '.changes.remove == []'

# A kernel without its module waits and says so; nothing moves.
world_plan no-module
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "no-move"'
plan_item kernel-waiting "and .kernel == \"$K44\" and .reason == \"no-module\" and .pending == false"

# The module of the new kernel needs a driver that is not published yet: the kernel waits.
world_plan module-ahead
plan_applicable
plan_unchanged
plan_item kernel-waiting "and .kernel == \"$K44\" and .reason == \"no-driver\""

# The module package fixes the upstream version of the driver. The move
# goes together with the respin for this ABI; the fallback kernel loses its module, and
# the report names it. The versioned firmware and the i386 libraries come along.
world_plan driver-respin
plan_applicable
assert_json "$PLAN" '.gated.decision == "move"'
plan_target "$K42" "$K42+1" "$D106"
assert_json "$PLAN" ".gated.target.losses == [\"$MODULE-7.0.0-38-generic\"]"
plan_changes install nvidia-firmware-595-595.106.01
plan_changes upgrade nvidia-driver-595-open nvidia-kernel-common-595 "$MODULE-7.0.0-42-generic" libnvidia-gl-595 libnvidia-gl-595:i386
assert_json "$PLAN" "[.changes.remove[] | select(.reason == \"module-loss\") | .name] == [\"$MODULE-7.0.0-38-generic\"]"
assert_json "$PLAN" '.changes.remove | length == 1'
plan_item module-loss 'and .pending == false and .running == false'

# With a respin for the fallback ABI too, the fallback keeps a module and nothing is lost.
world_plan driver-respin-both
plan_applicable
plan_target "$K42" "$K42+1" "$D106"
assert_json "$PLAN" '.gated.target.losses == [] and .changes.remove == []'
assert_json "$PLAN" "[.changes.upgrade[] | select(.name == \"$MODULE-7.0.0-38-generic\") | .version] == [\"$K38+2\"]"
plan_no_item module-loss

# The driver is published before any module accepts it: it waits, the machine stays.
world_plan driver-ahead
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "no-move"'
plan_item driver-waiting "and .driver == \"$D106\" and .pending == false"

# A packaging bump inside the range moves the driver alone.
world_plan packaging-bump
plan_applicable
plan_target "$K42" "$K42" "$D99B"
plan_changes upgrade nvidia-driver-595-open libnvidia-gl-595 libnvidia-gl-595:i386
plan_no_change upgrade "$META" "$MODULE-generic-hwe-24.04"
assert_json "$PLAN" '.changes.remove == [] and .changes.install == []'

# A new kernel whose module needs the new driver: both move; the older ABIs lose their
# modules, and the running one is called out, because driver and user space differ until a reboot.
world_plan kernel-and-driver
plan_applicable
plan_target "$K44" "$K44" "$D106"
assert_json "$PLAN" ".gated.target.losses == [\"$MODULE-7.0.0-38-generic\", \"$MODULE-7.0.0-42-generic\"]"
plan_item module-loss 'and .running == true and (.message | test("until a reboot"))'
assert_json "$PLAN" '.changes.remove | length == 2'

# A retired series looks like a same-series update: same name, same Source, higher
# version. It is a change of series: nothing moves, the next series is named.
world_plan transitional
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "no-move"'
plan_target "$K42" "$K42" "$D99"
plan_item series-available 'and .class == "nvidia" and .series == "615-open" and .retired == true and .pending == false'
plan_item series-available "and .class == \"nvidia\" and .accept == \"dotsteward upgrade --accept series:nvidia=615-open\""

# The archive has dropped the driver: no candidate is left in this series. It says so,
# and the installed driver stays.
world_plan series-gone
plan_applicable
plan_unchanged
plan_item series-available 'and .class == "nvidia" and .retired == true and (.message | test("gets no more updates"))'

# Phasing does not split the set, whichever member it holds.
for name in phase-module phase-kernel; do
  world_plan "$name"
  plan_applicable
  plan_unchanged
  assert_json "$PLAN" '.gated.decision == "waiting"'
  plan_item phased-waiting 'and .scope == "gated" and .pending == false'
  assert_json "$PLAN" ".gated.target.kernel == \"$K44\""
done
world_plan phase-module
plan_item phased-waiting "and .scope == \"gated\" and .packages == [\"$MODULE-generic-hwe-24.04\"] and .reasons[\"$MODULE-generic-hwe-24.04\"] == \"phased\""

# Phasing does not apply to what is also in -security.
world_plan phase-security
plan_applicable
assert_json "$PLAN" '.gated.decision == "move"'
plan_target "$K44" "$K44" "$D99"
plan_changes install linux-image-7.0.0-44-generic "$MODULE-7.0.0-44-generic"

# The newest kernel has no module yet, and the newest driver no module that takes it: the
# newest pair that fits moves, and both waiters are named.
world_plan newest-without-module
plan_applicable
plan_target "$K44" "$K44" "$D99"
plan_item kernel-waiting "and .kernel == \"$K46\""
plan_item driver-waiting "and .driver == \"$D106\""

# -proposed, -backports and a PPA are not stable: the classes do not see them.
for name in proposed-and-ppa backports-kernel; do
  world_plan "$name"
  plan_applicable
  plan_unchanged
  plan_target "$K42" "$K42" "$D99"
  plan_no_item kernel-waiting
done

# The release pocket has a lower version of the same name with another Source; a pin
# must not fall back to it. No world here moves below what is installed.
world_plan no-change
assert_json "$PLAN" '.changes.downgrade == []'

# A machine without the NVIDIA class: the kernel moves alone.
world_plan no-nvidia
plan_applicable
assert_json "$PLAN" ".gated.target.kernel == \"$K44\" and .gated.nvidia == null and .gated.target.driver == null"
plan_changes install linux-image-7.0.0-44-generic

# DKMS: no module package to pair with: kernel and driver move on their own, the report
# leaves the module to the check of nvidia.ko.
world_plan dkms-machine
plan_applicable
assert_json "$PLAN" ".gated.target.kernel == \"$K44\" and .gated.target.driver == \"$D106\" and .gated.target.module == null"
plan_item module-through-dkms 'and .pending == false'
plan_changes install linux-image-7.0.0-44-generic
plan_changes upgrade nvidia-driver-595-open nvidia-dkms-595-open

# The classes come from what is installed: no version is data of the framework.
world_plan same-string
assert_json "$PLAN" '.gated.kernel.meta == "linux-generic-hwe-24.04" and .gated.kernel.flavour == "generic-hwe-24.04" and .gated.kernel.series == "7.0" and .gated.nvidia.series == "595-open"'

# The tracked mode marks the set by hand instead of a full upgrade: the plan is the same.
for name in same-string plus-n driver-respin driver-respin-both packaging-bump kernel-and-driver; do
  world_plan "$name"
  full=$(jq -cS .changes "$PLAN")
  world_plan "$name" '{"mode": "tracked", "tracked": []}'
  assert_eq "$full" "$(jq -cS .changes "$PLAN")" "the tracked plan of $name differs from the full one"
done

# A hold on a member of the set holds the set, whatever the rest could do; it is no phase.
world_plan held-kernel
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "waiting"'
plan_item gated-kept-back 'and .scope == "gated" and .reasons["linux-generic-hwe-24.04"] == "held" and .pending == false'

# A second kernel meta package stays where it is, and the report says so.
world_plan two-metas
plan_applicable
assert_json "$PLAN" '.gated.kernel.meta == "linux-generic-hwe-24.04" and .gated.other_metas == ["linux-generic"]'
plan_target "$K44" "$K44" "$D99"
plan_changes install linux-image-7.0.0-44-generic
plan_no_change upgrade linux-generic
plan_item kernel-meta-held 'and .packages == ["linux-generic"] and .pending == false'
