# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Fork mode (publish, release and upgrade): publish pushes fix/<slug> to the
# fork, waits for the fork's CI runs of the commit (skipped with a warning
# when GitHub Actions are disabled there; a build-only trial then is
# refused), fast-forwards the fork's main to the tested commit and opens an
# upstream pull request only with upstream.pr_to_upstream or
# --pr-to-upstream; it never merges into the upstream. release tags the
# fork (no GitHub release); the next tag counts the upstream's tags too.
# upgrade moves the instance's dotsteward input to the fork's tag.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup fork
upstream_before=$(upstream_main)
checked_run add-feature
mark_trialled full false
sha=$(git -C "$ct_clone" rev-parse HEAD)

# --- the fork's CI is red ------------------------------------------------------------

hub_knob ci failure
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: CI run "
assert_contains "$DS_STDERR" "on ${sha:0:12} concluded with failure: https://github.com/$CT_FORK_SLUG/actions/runs/"
assert_eq "$sha" "$(git -C "$ct_fork_bare" rev-parse refs/heads/fix/add-feature)" "branch pushed to the fork"
assert_eq "$upstream_before" "$(fork_main)" "fork main after red CI"
assert_call_count 0 gh 'pr *'

# No CI run at all while Actions are enabled: red as well.
hub_knob ci none
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no CI run appeared in $CT_FORK_SLUG for ${sha:0:12} within 1s; nothing is published"

# --- green: the fork's main fast-forwarded, no pull request ---------------------------

hub_knob ci success
reset_calls
assert_exit 0 run_contribute publish
assert_eq "$sha" "$(fork_main)" "fork main after the publish"
assert_eq "$upstream_before" "$(upstream_main)" "upstream main is never touched in fork mode"
assert_call_count 0 gh 'pr *'
assert_contains "$DS_STDOUT" "[dotsteward] published: main of $CT_FORK_SLUG is ${sha:0:12}"
state_json | assert_json - ".merged_sha == \"$sha\" and .step == \"release\" and .pr == null"

# --- release on the fork ---------------------------------------------------------------

# The upstream released v0.1.4 meanwhile: the next tag follows it, and the
# fix's VERSION (0.1.1) no longer matches.
git -C "$ct_upstream_src" tag -a v0.1.4 -m 'dotsteward v0.1.4' HEAD
git -C "$ct_upstream_src" push -q "$ct_upstream_bare" refs/tags/v0.1.4
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.1.1 at the merged commit ${sha:0:12}, but the next release is v0.1.5"
git -C "$ct_upstream_bare" tag -d v0.1.4 >/dev/null

reset_calls
assert_exit 0 run_contribute release
assert_eq "$sha" "$(git -C "$ct_fork_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "tag on the fork"
assert_eq tag "$(git -C "$ct_fork_bare" cat-file -t refs/tags/v0.1.1)" "the tag is annotated"
if git -C "$ct_upstream_bare" rev-parse --verify --quiet refs/tags/v0.1.1 >/dev/null; then
  ds_fail "fork mode tagged the upstream"
fi
assert_call_count 0 gh 'release *'
state_json | assert_json - '.tag == "v0.1.1" and .step == "upgrade"'

# --- upgrade to the fork's tag ------------------------------------------------------------

write_flake git
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_contains "$(cat "$ct_inst/flake.nix")" 'url = "git+ssh://git@github.com/dotsteward-test/dotsteward?ref=refs/tags/v0.1.1";'
jq -e --arg sha "$sha" '.nodes.dotsteward.locked.rev == $sha and .nodes.dotsteward.original.ref == "refs/tags/v0.1.1"' \
  "$ct_inst/flake.lock" >/dev/null || ds_fail "flake.lock does not lock the fork's tag"
assert_eq "$(rt_bootstrap 0.1.1)" "$(cat "$ct_inst/bootstrap.sh")" "bootstrap.sh from the fork's release"
assert_eq report "$(field .step)" "step after the upgrade"

# The instance follows the upstream again for the next runs (its flake.lock
# names the framework upstream).
cp "$ct_fixtures/instance/flake.lock" "$ct_inst/flake.lock"
write_flake github

# --- a pull request to the upstream on request ----------------------------------------------

checked_run second-feature 0.1.2
mark_trialled full false
sha2=$(git -C "$ct_clone" rev-parse HEAD)
# The fork's main holds the first fix, which the upstream does not have: the
# second fix (from upstream main) cannot fast-forward it.
reset_calls
assert_exit 1 run_contribute publish --pr-to-upstream
assert_contains "$DS_STDERR" "[dotsteward] ERROR: main of $CT_FORK_SLUG (${sha:0:12}) cannot be fast-forwarded to ${sha2:0:12}: it has commits that fix/second-feature lacks"
assert_eq "$sha" "$(fork_main)" "fork main after a refused fast-forward"

# Once the fork's main follows the upstream again, the pull request opens.
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
reset_calls
assert_exit 0 run_contribute publish --pr-to-upstream
assert_eq "$sha2" "$(fork_main)" "fork main after the second publish"
assert_call_count 1 gh "pr create -R $CT_UPSTREAM_SLUG --base main --head dotsteward-test:fix/second-feature *"
assert_eq "https://github.com/$CT_UPSTREAM_SLUG/pull/1" "$(field .pr)" "upstream pull request"
assert_call_count 0 gh 'pr merge*'
assert_eq "$upstream_before" "$(upstream_main)" "upstream main after the pull request"

# upstream.pr_to_upstream = true does the same without the flag; an open
# pull request is reused.
rt_setup fork 'pr_to_upstream = true'
checked_run third-feature 0.1.2
mark_trialled full false
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 1 gh "pr create -R $CT_UPSTREAM_SLUG --base main --head dotsteward-test:fix/third-feature *"

# --- Actions disabled on the fork ------------------------------------------------------------

checked_run fourth-feature 0.1.2
mark_trialled build-only false
hub_knob actions false
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the build-only trial needs clean-install.yml green, but GitHub Actions are disabled on $CT_FORK_SLUG; enable them there, or run a full trial"
[[ -z $(git -C "$ct_fork_bare" for-each-ref refs/heads/fix/fourth-feature) ]] || ds_fail "pushed before the refusal"

mark_trialled full false
assert_exit 0 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] WARNING: GitHub Actions are disabled on $CT_FORK_SLUG, so no CI runs there; relying on the framework gate and the trial"
assert_eq "$(git -C "$ct_clone" rev-parse HEAD)" "$(fork_main)" "fork main without Actions"

# --- VERSION must equal the next release before the fork is touched -------------------------

# The next release is v0.1.2 (the fork's v0.1.1 and the upstream's v0.1.0).
hub_knob actions true
checked_run fifth-feature 0.2.0
mark_trialled full false
sha5=$(git -C "$ct_clone" rev-parse HEAD)
git -C "$ct_fork_bare" update-ref refs/heads/main "$upstream_before"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: VERSION is 0.2.0 at ${sha5:0:12}, but the next release is v0.1.2: set VERSION to 0.1.2 in the fix, then run: dotsteward contribute check; nothing is published"
[[ -z $(git -C "$ct_fork_bare" for-each-ref refs/heads/fix/fifth-feature) ]] || ds_fail "pushed to the fork despite the VERSION mismatch"
assert_eq "$upstream_before" "$(fork_main)" "fork main after a VERSION mismatch"
assert_eq "$upstream_before" "$(upstream_main)" "upstream main after a VERSION mismatch"
assert_call_count 0 gh 'pr *'
state_json | assert_json - '.step == "publish" and .merged_sha == null'
