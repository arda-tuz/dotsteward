# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Tracked-only planning: only tracked packages move, with what they need, and a phased
# update stays phased: a mark by hand goes through the phase, so only what a full
# upgrade would upgrade is marked.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

# A tracked package moves, an untracked one stays; `all` moves both. Phased: neither.
world_plan tracked '{"mode": "tracked", "tracked": ["example-tracked"]}'
plan_applicable
assert_json "$PLAN" '[.changes.upgrade[].name] == ["example-tracked"]'
plan_no_item phased-waiting

world_plan tracked
plan_applicable
assert_json "$PLAN" '[.changes.upgrade[].name] | sort == ["example-other", "example-tracked", "linux-libc-dev"]'
plan_item phased-waiting 'and .scope == "all" and .packages == ["example-lib"] and .pending == false'
assert_json "$PLAN" '[.phased[].name] == ["example-lib"]'

# A tracked package under phasing is not pierced, and the report says why it waits.
world_plan tracked-phased '{"mode": "tracked", "tracked": ["example-tracked"]}'
plan_applicable
plan_unchanged
plan_item phased-waiting 'and .scope == "tracked" and .packages == ["example-tracked"]'
assert_json "$PLAN" '.phased == [{"candidate": "2.0-1", "current": "1.0-1", "name": "example-tracked", "percentage": 0}]'

# A tracked package that needs a phased library: the mark does not pull the library in.
world_plan tracked-phased-dependency '{"mode": "tracked", "tracked": ["example-tracked"]}'
plan_applicable
plan_unchanged
plan_item kept-back 'and .packages == ["example-tracked"]'

# The tracked set does not move a gated class by name; the shared target does, or nothing.
world_plan phase-module '{"mode": "tracked", "tracked": ["linux-generic-hwe-24.04", "nvidia-driver-595-open", "linux-image-generic-hwe-24.04"]}'
plan_applicable
plan_unchanged
assert_json "$PLAN" '.gated.decision == "waiting"'

world_plan no-module '{"mode": "tracked", "tracked": ["linux-generic-hwe-24.04"]}'
plan_applicable
plan_unchanged

# A name that is not installed is no change.
world_plan tracked '{"mode": "tracked", "tracked": ["example-not-installed"]}'
plan_applicable
plan_unchanged
