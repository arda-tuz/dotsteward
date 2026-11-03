# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` waits only for the lint job (ci) and the
# generic privacy scans (privacy) of the pull request head: the full check
# runs on main after the merge and gates the release. A full check that
# still runs (or failed) on the pull request neither holds nor stops the
# merge; a pending lint is waited for, a failed one is red with main
# untouched, and a pull request without lint or generic is not merged. The
# default checks have the shape of the split CI, where the full check is
# skipped on a pull request of the repository itself.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=3
export DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS=6

rt_setup owner
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1

# --- the full check still running on the pull request: merged on lint and generic ----------

checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
main_before=$(upstream_main)
mark_trialled full false
hub_knob full-check pending
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] waiting for the CI checks lint and generic of $pr_url (the full check runs on main after the merge)"
assert_contains "$DS_STDOUT" "[dotsteward] CI is green on $pr_url: lint and generic passed"
assert_eq "$sha" "$(upstream_main)" "upstream main after a publish with the full check pending"
state_json | assert_json - ".merged_sha == \"$sha\" and .step == \"release\""

# --- a failed full check on the pull request does not stop the merge ----------------------------

state_set '.step = "done"'
checked_run second-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
mark_trialled full false
hub_knob full-check fail
assert_exit 0 run_contribute publish
assert_eq "$sha" "$(upstream_main)" "upstream main after a publish with the full check red"

# --- lint pending: waited for; lint failed: red, main untouched ---------------------------------

state_set '.step = "done"'
rm -f "$rt_hub/knobs/full-check"
checked_run third-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
mark_trialled full false
hub_knob checks-pending 3
assert_exit 0 run_contribute publish
[[ ! -e $rt_hub/knobs/checks-pending ]] || ds_fail "publish did not wait for the pending lint and generic"
assert_eq "$sha" "$(upstream_main)" "upstream main after a pending lint"

state_set '.step = "done"'
checked_run fourth-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
mark_trialled full false
main_before=$(upstream_main)
hub_knob lint fail
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/4
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: CI is not green on $pr_url (lint failed); main is untouched"
assert_eq "$main_before" "$(upstream_main)" "upstream main after a red lint"
state_json | assert_json - '.step == "publish" and .merged_sha == null'

# A lint that keeps running is not waited for forever.
hub_knob lint pending
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the CI checks lint and generic of $pr_url did not finish within 6s; main is untouched"
assert_eq "$main_before" "$(upstream_main)" "upstream main after a lint that never finished"

# --- no lint or generic on the pull request: never merged ------------------------------------

rm -f "$rt_hub/knobs/lint"
hub_knob checks none
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the CI checks lint and generic did not appear on $pr_url within 3s; publishing needs them green, main is untouched"
assert_eq "$main_before" "$(upstream_main)" "upstream main without the publish checks"

# Green again: merged.
rm -f "$rt_hub/knobs/checks"
assert_exit 0 run_contribute publish
assert_eq "$sha" "$(upstream_main)" "upstream main after the checks passed"
