# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` in fork mode over a network that drops for
# a moment: every read of the fork and the upstream, the pushes to the fork
# and the listing of the fork's CI runs are made again (see
# test-publish-network.sh), and a main of the fork that does not
# fast-forward stays a verdict, made once.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup fork
upstream_before=$(upstream_main)
checked_run add-feature
mark_trialled full false
sha=$(git -C "$ct_clone" rev-parse HEAD)

# A read takes x. (dropped, served); a push x.x.. (its read dropped and
# served, the push dropped, the read served, the push served). In order: the
# tags of both remotes and the fetch of the upstream; the branch; the fetch
# and the tags of both remotes again; main, read and pushed; the fetch of the
# verification and the tags of both remotes for the last line.
network_plan x.x.x.x.x..x.x.x.x.x.x.x..x.x.x.
hub_knob runs-flaky 1
: >"$DS_FAKESSH_LOG"
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot list the tags of upstream; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from upstream; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/fix/add-feature on origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read or push refs/heads/main on origin; trying again in 1s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot read the workflow runs of ${sha:0:12} in $CT_FORK_SLUG; reading GitHub again in 1s"
assert_contains "$DS_STDOUT" "[dotsteward] published: main of $CT_FORK_SLUG is ${sha:0:12}"
assert_eq "$sha" "$(fork_main)" "fork main after the drops"
assert_eq "$upstream_before" "$(upstream_main)" "upstream main after the drops"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and the fork's main, one each"
network_plan ''
assert_exit 0 run_contribute release
state_set '.step = "done"'

# The fork's main holds a commit the next run lacks: a verdict, made once.
checked_run second-feature 0.1.2
mark_trialled full false
second=$(git -C "$ct_clone" rev-parse HEAD)
: >"$DS_FAKESSH_LOG"
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: main of $CT_FORK_SLUG (${sha:0:12}) cannot be fast-forwarded to ${second:0:12}: it has commits that fix/second-feature lacks; rebase fix/second-feature onto it"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and the push to main that does not fast-forward, once"
assert_eq "$sha" "$(fork_main)" "fork main after the refused fast-forward"
