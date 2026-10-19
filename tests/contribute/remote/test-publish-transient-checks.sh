# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` reads the CI checks until none is pending,
# and a GitHub answer that fails for a moment (HTTP 502 and the like) is
# not a CI result: publishing reads again and merges once the checks are
# green. Only a failed or cancelled check stops it as CI not green, and
# only answers that keep failing stop it as checks that cannot be read.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner
checked_run add-feature
sha=$(git -C "$ct_clone" rev-parse HEAD)
pr_url=https://github.com/$CT_UPSTREAM_SLUG/pull/1
mark_trialled full false

# Answers that keep failing stop the wait; main is untouched.
hub_knob checks-flaky 10
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read the CI checks of $pr_url (10 failed answers in a row); main is untouched"
[[ $(upstream_main) != "$sha" ]] || ds_fail "main moved although the checks could not be read"

# Checks pending for a while, two failing answers in between: green.
hub_knob checks-pending 2
hub_knob checks-flaky 2
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] CI is green on $pr_url"
assert_eq "$sha" "$(upstream_main)" "upstream main after the merge"
[[ ! -e $rt_hub/knobs/checks-pending && ! -e $rt_hub/knobs/checks-flaky ]] ||
  ds_fail "publish did not read the checks through the pending and failing answers"
