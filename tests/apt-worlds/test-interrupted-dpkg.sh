# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The journal of dpkg holds updates: dpkg runs now or was killed, and apt sees half a transaction.
# A plan says so and decides nothing, whatever it could work out from that picture.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

world_plan same-string
assert_json "$PLAN" '.gated.decision == "move" and .applicable == true'
mkdir -p "$WORLD/var/lib/dpkg/updates"
: >"$WORLD/var/lib/dpkg/updates/0001"
world_plan same-string
plan_item dpkg-interrupted 'and .pending == true'
plan_unchanged
assert_json "$PLAN" '.gated.decision == "waiting" and .applicable == false and .newest_kernel == null'
rm -f "$WORLD/var/lib/dpkg/updates/0001"
: >"$WORLD/var/lib/dpkg/updates/tmp.i"
world_plan same-string
plan_no_item dpkg-interrupted
assert_json "$PLAN" '.gated.decision == "move"'
