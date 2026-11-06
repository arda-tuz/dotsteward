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

# The network stays down at the push of the fork's main: red, the machine as
# it is. In order, before it: the tags of both remotes, the fetch of the
# upstream, the branch (already there), the fetch, the tags of both remotes,
# and main, read twice.
checked_run lasting-feature 0.1.2
mark_trialled full true
printf 'trial\n' >"$rt_live"
lasting=$(git -C "$ct_clone" rev-parse HEAD)
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
git -C "$ct_clone" push -q origin HEAD:refs/heads/fix/lasting-feature
network_plan .........xxxxxxxxxx
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=5
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing ${lasting:0:12} to main of $CT_FORK_SLUG failed"
assert_contains "$DS_STDOUT" "[dotsteward] the network kept failing, so the machine stays as it is; run the step again once the network is back"
assert_eq "" "$(instance_calls)" "a network that stays down runs no recovery"
assert_eq trial "$(live)" "live framework after a network that stayed down"
network_plan ''
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30
assert_exit 0 run_contribute publish
assert_eq "$lasting" "$(fork_main)" "fork main once the network is back"
assert_exit 0 run_contribute release
state_set '.step = "done"'

# The fork's main holds a commit the next run lacks: a verdict, made once.
checked_run second-feature 0.1.3
mark_trialled full false
second=$(git -C "$ct_clone" rev-parse HEAD)
: >"$DS_FAKESSH_LOG"
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: main of $CT_FORK_SLUG (${lasting:0:12}) cannot be fast-forwarded to ${second:0:12}: it has commits that fix/second-feature lacks; rebase fix/second-feature onto it"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and the push to main that does not fast-forward, once"
assert_eq "$lasting" "$(fork_main)" "fork main after the refused fast-forward"

# The answer of the push of the fork's main is lost and that main moves on:
# the push landed, so the run is published, with no call to rebase.
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
hub_knob push-lost 'refs/heads/main moved'
reset_calls
assert_exit 0 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] ${second:0:12} is on main of $CT_FORK_SLUG: its push landed although its answer was lost"
assert_not_contains "$DS_STDERR" "rebase"
[[ $(fork_main) != "$second" ]] || ds_fail "the fork's main did not move on"
git -C "$ct_fork_bare" merge-base --is-ancestor "$second" refs/heads/main || ds_fail "the tested commit is not on the fork's main"
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$second\""
