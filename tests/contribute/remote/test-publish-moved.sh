# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Publish when upstream main moves: before the push,
# or while CI runs, the branch is rebased onto the new main and the run goes
# back to check (exit 5, the tested commit and the trial are cleared); a
# conflicting rebase is aborted and left to the user. A push to main that
# the remote refuses is red: main is untouched and the trial switch is
# recovered. A push that no longer fast-forwards (main moved at the last
# moment) rebases the branch and goes back to check the same way. A pull
# request merged on GitHub by hand with other changes (tree mismatch)
# releases nothing: the branch is rebased onto the merged main and the run
# goes back to check, whose merged main is then published and released. A
# closed pull request is refused.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
checked_run add-feature
mark_trialled full false
sha=$(git -C "$ct_clone" rev-parse HEAD)

# --- main moved before the push: rebased, back to check -------------------------------

push_upstream other.txt other 'feat: an unrelated change'
moved=$(upstream_main)
reset_calls
assert_exit 5 run_contribute publish
assert_contains "$DS_STDOUT" "[dotsteward] origin/main moved to ${moved:0:12}; rebasing fix/add-feature onto it"
assert_contains "$DS_STDOUT" "[dotsteward] the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
rebased=$(git -C "$ct_clone" rev-parse HEAD)
assert_eq "$moved" "$(git -C "$ct_clone" rev-parse HEAD~2)" "base of the rebased branch"
[[ $rebased != "$sha" ]] || ds_fail "the branch was not rebased"
assert_eq "+0000" "$(git -C "$ct_clone" log -1 --format=%cd --date=format:%z)" "committer offset of the rebased commit"
state_json | assert_json - '.step == "check" and .test_sha == null and .tested_tree == null and .trial == null and .trial_sha == null'
assert_call_count 0 gh 'pr *'
[[ -z $(git -C "$ct_upstream_bare" for-each-ref refs/heads/fix) ]] || ds_fail "the branch was pushed"
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "has not passed the trial; next: dotsteward contribute check"

# --- a conflicting rebase is aborted -------------------------------------------------------

mark_checked
mark_trialled full false
push_upstream add-feature.txt 'other content' 'feat: a conflicting change'
assert_exit 5 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: fix/add-feature conflicts with origin/main: rebase it by hand in $ct_clone (with TZ=UTC), then run: dotsteward contribute check"
assert_eq "$rebased" "$(git -C "$ct_clone" rev-parse HEAD)" "branch after the aborted rebase"
assert_eq "" "$(git -C "$ct_clone" status --porcelain)" "clone after the aborted rebase"
[[ ! -d $ct_clone/.git/rebase-merge && ! -d $ct_clone/.git/rebase-apply ]] || ds_fail "a rebase is still in progress"
assert_eq check "$(field .step)" "step after the conflict"

# Resolved by hand: the upstream change wins, the branch keeps its own file.
git -C "$ct_clone" fetch -q origin
git -C "$ct_clone" reset -q --hard origin/main
checked_branch() {
  printf 'feature\n' >"$ct_clone/feature-two.txt"
  printf '0.1.1\n' >"$ct_clone/VERSION"
  git -C "$ct_clone" add -A
  git -C "$ct_clone" commit -q -m 'feat(example): the feature, again'
  mark_checked
  mark_trialled full "${1:-false}"
}
checked_branch

# --- main refuses the push: red, recovered, main untouched -----------------------------

before=$(upstream_main)
refused=$(git -C "$ct_clone" rev-parse HEAD)
hub_knob push-main refuse
printf 'switched\n' >"$rt_live"
state_set '.trial_switched = true'
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing ${refused:0:12} to main of $CT_UPSTREAM_SLUG was refused; main is untouched"
assert_eq "$before" "$(upstream_main)" "upstream main after a refused push"
assert_eq pinned "$(live)" "live framework after a refused push"
assert_eq false "$(field .trial_switched)" "trial_switched after a refused push"
assert_eq publish "$(field .step)" "step after a refused push"

# --- main moved while CI ran: rebased after the checks, before the merge -------------------

hub_knob push-main none
hub_knob ci-moves-main late.txt
reset_calls
assert_exit 5 run_contribute publish
assert_call_count 1 gh 'pr checks * --watch *'
[[ $(upstream_main) != "$(git -C "$ct_clone" rev-parse HEAD)" ]] || ds_fail "main was fast-forwarded after it moved during CI"
assert_eq check "$(field .step)" "step after main moved during CI"
# The remote branch holds the old commit: the rebased one replaces it.
checked_branch_rebased=$(git -C "$ct_clone" rev-parse HEAD)
mark_checked
mark_trialled full false
reset_calls
assert_exit 0 run_contribute publish
assert_eq "$checked_branch_rebased" "$(git -C "$ct_upstream_bare" rev-parse refs/heads/fix/add-feature)" "force-pushed branch"
assert_eq "$checked_branch_rebased" "$(upstream_main)" "upstream main after the merge"
assert_call_count 0 gh 'pr merge*'

# --- main moved at the last moment: the push no longer fast-forwards ------------------------

# A commit lands on main between the last check and the push: main stays as
# it is, the branch is rebased onto it and the run goes back to check (exit
# 5). The live generation keeps the trial framework until the next trial.
assert_exit 0 run_contribute release
checked_run race 0.1.2
mark_trialled full true
race=$(git -C "$ct_clone" rev-parse HEAD)
printf 'switched\n' >"$rt_live"
hub_knob push-main race
reset_calls
assert_exit 5 run_contribute publish
concurrent=$(upstream_main)
assert_eq "chore: a concurrent change" "$(git -C "$ct_upstream_bare" log -1 --format=%s "$concurrent")" "the concurrent commit on main"
assert_contains "$DS_STDOUT" "[dotsteward] origin/main moved to ${concurrent:0:12}; rebasing fix/race onto it"
assert_contains "$DS_STDOUT" "[dotsteward] the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
assert_eq "$concurrent" "$(git -C "$ct_clone" rev-parse HEAD~2)" "base of the rebased branch"
[[ $(git -C "$ct_clone" rev-parse HEAD) != "$race" ]] || ds_fail "the branch was not rebased after the refused push"
state_json | assert_json - '.step == "check" and .test_sha == null and .trial == null and .trial_switched == true
  and .merged_sha == null'
assert_eq switched "$(live)" "live framework after the refused push"
assert_eq "" "$(instance_calls)" "instance commands after the refused push"
mark_checked
mark_trialled full false
assert_exit 0 run_contribute publish
assert_eq "$(git -C "$ct_clone" rev-parse HEAD)" "$(upstream_main)" "upstream main after the second publish"
assert_exit 0 run_contribute release

# --- a pull request merged on GitHub by hand, with other changes: tree mismatch ---------------

# The squash commit holds the fix and a concurrent change, so its tree is
# not the tested one: nothing is released; the branch is rebased onto it
# (its commits are in the squash, so it becomes upstream main) and the run
# goes back to check (exit 5) with the merged pull request kept.
checked_run by-hand 0.1.3
mark_trialled full false
hand_tree=$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')
hub_knob checks fail
assert_exit 1 run_contribute publish
hand_pr=$(field .pr)
push_upstream other-by-hand.txt other 'feat: a change merged meanwhile'
gh pr merge "$hand_pr" --squash --match-head-commit "$(git -C "$ct_clone" rev-parse HEAD)"
squash=$(upstream_main)
hub_knob checks pass
reset_calls
assert_exit 5 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: tree mismatch: the published commit ${squash:0:12}"
assert_contains "$DS_STDERR" "but the tested tree is ${hand_tree:0:12} (the pull request was merged on GitHub with other changes); nothing is released"
assert_contains "$DS_STDOUT" "[dotsteward] the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
assert_eq "$squash" "$(git -C "$ct_clone" rev-parse HEAD)" "branch after the tree mismatch"
assert_eq "" "$(git -C "$ct_clone" status --porcelain)" "clone after the tree mismatch"
state_json | assert_json - ".step == \"check\" and .test_sha == null and .tested_tree == null and .trial == null
  and .trial_sha == null and .merged_sha == \"$squash\" and .pr == \"$hand_pr\""
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "is not published yet; next: dotsteward contribute check"

# check validates upstream main as it is (the branch has no commits of its
# own), the trial switches to it, and publish takes it as the published
# commit: the merged pull request is neither merged nor opened again.
assert_exit 0 run_contribute check
assert_contains "$DS_STDOUT" "[dotsteward] fix/by-hand has no commits after origin/main: its pull request is merged, so the merged origin/main is checked"
assert_eq "$squash" "$(field .test_sha)" "checked commit after the tree mismatch"
assert_exit 0 run_contribute trial
assert_eq "git+file://$ct_clone?rev=$squash" "$(live)" "live framework after the second trial"
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'pr create*'
assert_eq "$squash" "$(upstream_main)" "upstream main after publishing the merged main"
assert_contains "$DS_STDOUT" "[dotsteward] verified: ${squash:0:12} on origin/main has the tested tree"
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$squash\" and .test_sha == \"$squash\"
  and .pr == \"$hand_pr\""
assert_exit 0 run_contribute release
assert_eq "$squash" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.3^{commit}')" "released commit"
assert_eq "$(field .tested_tree)" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.3^{tree}')" "tree of the release"

# --- a closed pull request ----------------------------------------------------------------

checked_run closed 0.1.4
mark_trialled full false
hub_knob checks fail
assert_exit 1 run_contribute publish
pr=$(field .pr)
file=$(grep -l "\"$pr\"" "$rt_hub"/prs/*.json)
jq '.state = "CLOSED"' "$file" >"$file.new" && mv "$file.new" "$file"
hub_knob checks pass
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the pull request $pr is closed; reopen it, or end the run with: dotsteward contribute abort"
