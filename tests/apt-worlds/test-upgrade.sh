# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# `dotsteward upgrade` on the real engine and real apt in rootless worlds: the plan of both modes,
# a phased update that stays phased, the read only analysis. Nothing here can install anything: no
# terminal, no root, and the lists and the status file are the world's.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require
world_up tracked
tracked_world=$WORLD
world_up tracked-phased
phased_world=$WORLD

UP_REAL_APT=world
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"
tool_stub fwupdmgr 'exit 2'
export DOTSTEWARD_APT_SUDO=""

# Both modes, from one plan command.
export APT_CONFIG=$tracked_world/apt.conf
assert_exit 0 upgrade --plan --json
assert_stdout_json '[.tracked.apt.changes.upgrade[].name] == ["example-tracked"]'
assert_stdout_json '[.all.apt.changes.upgrade[].name] | sort == ["example-other", "example-tracked", "linux-libc-dev"]'
assert_stdout_json '[.all.apt.items[] | select(.code == "phased-waiting") | .packages] == [["example-lib"]]'

# The plan a person reads.
assert_exit 0 upgrade --plan
assert_contains "$DS_STDOUT" "1 upgrade"
assert_contains "$DS_STDOUT" "3 upgrade"

# A tracked package under phasing is not pierced: no change, and the report says why.
export APT_CONFIG=$phased_world/apt.conf
assert_exit 0 upgrade --plan --json
assert_stdout_json '.tracked.apt.changes.upgrade == []'
assert_stdout_json '[.tracked.apt.items[] | select(.code == "phased-waiting" and .scope == "tracked") | .packages] == [["example-tracked"]]'

# The analysis of a run without a terminal: what is outside the tracked set, read by the engine.
export APT_CONFIG=$tracked_world/apt.conf
assert_exit 3 upgrade --tracked
analysis=$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json
assert_json "$analysis" '.channels.apt.available == true'
assert_json "$analysis" '[.channels.apt.packages[].name] | index("example-other") != null'
assert_json "$analysis" '[.channels.apt.packages[].name] | index("example-tracked") == null'
