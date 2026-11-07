# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# GRUB boots the newest installed kernel. A plan says when that kernel has no NVIDIA module, also
# when it has nothing to do itself, also when the kernel is newer than what the meta package names;
# it is silent when the plan brings the module, and on a machine without the class.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

# Nothing to do, and the newest kernel boots without a GPU.
world_modinfo "" "7.0.0-44-generic"
world_plan no-module-installed
plan_unchanged
assert_json "$PLAN" '.applicable == true and .newest_kernel.release == "7.0.0-44-generic"'
plan_item module-missing 'and .pending == true and .kernel == "7.0.0-44-generic" and (.message | test("do not reboot"))'
world_report no-module-installed
assert_eq 3 "$WORLD_STATUS"
assert_json "$REVIEW" '.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic"'

# The newest image is above the meta package, another package moves.
world_plan image-above-meta
plan_changes upgrade example-lib
assert_json "$PLAN" '.newest_kernel.release == "7.0.0-44-generic"'
plan_item module-missing 'and .kernel == "7.0.0-44-generic"'

# The same kernel with its module: nothing to say.
world_modinfo
world_plan no-module-installed
plan_no_item module-missing

# The plan brings the module of that kernel, or a newer kernel with its module.
world_modinfo "" "all"
world_plan same-string
assert_json "$PLAN" '.gated.decision == "move" and .newest_kernel.planned == true'
plan_no_item module-missing

# No driver, no module to look for.
world_plan no-nvidia
assert_json "$PLAN" '.newest_kernel.nvidia == false'
plan_no_item module-missing
