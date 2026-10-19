# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` waits for the checks of the pushed commit,
# not of the pull request's previous head: right after a push to an open
# pull request GitHub still answers for the old head for a moment (with its
# old, here failed, check), then reports the new head before any check of
# it is registered. Publishing waits through both and merges once the
# checks of the pushed commit are green.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1
mark_trialled full false

hub_knob stale-head 1
hub_knob checks-later 1
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] CI is green on $pr_url"
assert_contains "$DS_STDOUT" "[dotsteward] merging $pr_url: fast-forwarding main of $CT_UPSTREAM_SLUG to ${sha:0:12}"
assert_eq "$sha" "$(upstream_main)" "upstream main after the merge"
assert_call_count 1 gh "pr checks $pr_url --watch --fail-fast --interval 1"
[[ ! -e $rt_hub/knobs/stale-head && ! -e $rt_hub/knobs/checks-later ]] ||
  ds_fail "publish did not wait through the stale head and the missing checks"
