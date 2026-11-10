# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# The upgrade commit `dotsteward contribute upgrade` makes in the instance has UTC dates
# (docs/privacy.md), whatever time zone the shell of the person has.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
write_flake git
released_run add-feature
base=$(git -C "$ct_inst" rev-parse HEAD)

reset_calls
TZ=UTC-3 assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD^)" "one upgrade commit on the base"
assert_eq "+0000 +0000" "$(git -C "$ct_inst" log -1 --format='%ad %cd' --date=format:%z)" "the dates of the upgrade commit"
