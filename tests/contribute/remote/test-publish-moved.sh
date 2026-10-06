# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# Q5, publish when upstream main moves (SPEC 9.4 step 8): before the push,
# or while CI runs, the branch is rebased onto the new main and the run goes
# back to check (exit 5, the tested commit and the trial are cleared); a
# conflicting rebase is aborted and left to the user. A pull request that
# GitHub refuses to merge is red: main is untouched and the trial switch is
# recovered. A merge that lands on a main that moved at the last moment
# (tree mismatch) releases nothing: the branch is rebased onto the merged
# main and the run goes back to check, whose merged main is then published
# and released. A closed pull request is refused.
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

# --- GitHub refuses the merge: red, recovered, main untouched ---------------------------

before=$(upstream_main)
hub_knob merge refuse
printf 'switched\n' >"$rt_live"
state_set '.trial_switched = true'
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: gh pr merge refused https://github.com/$CT_UPSTREAM_SLUG/pull/1; main is untouched"
assert_eq "$before" "$(upstream_main)" "upstream main after a refused merge"
assert_eq pinned "$(live)" "live framework after a refused merge"
assert_eq false "$(field .trial_switched)" "trial_switched after a refused merge"

# --- main moved while CI ran: rebased after the checks, before the merge -------------------

hub_knob merge normal
hub_knob ci-moves-main late.txt
reset_calls
assert_exit 5 run_contribute publish
assert_call_count 0 gh 'pr merge*'
assert_call_count 1 gh 'pr checks * --watch *'
assert_eq check "$(field .step)" "step after main moved during CI"
# The remote branch holds the old commit: the rebased one replaces it.
checked_branch_rebased=$(git -C "$ct_clone" rev-parse HEAD)
mark_checked
mark_trialled full false
reset_calls
assert_exit 0 run_contribute publish
assert_eq "$checked_branch_rebased" "$(git -C "$ct_upstream_bare" rev-parse refs/heads/fix/add-feature)" "force-pushed branch"
assert_call_count 1 gh "pr merge * --squash --match-head-commit $checked_branch_rebased"
assert_eq "$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')" "$(upstream_tree)" "tree after the merge"

# --- a merge onto a main that moved at the last moment: tree mismatch -----------------------

# The squash commit holds the fix and a concurrent change, so its tree is
# not the tested one: nothing is released; the branch is rebased onto it
# (its commits are in the squash, so it becomes upstream main) and the run
# goes back to check (exit 5) with the merged pull request kept. The live
# generation keeps the trial framework until the next trial.
checked_run race
mark_trialled full true
race_tree=$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')
printf 'switched\n' >"$rt_live"
hub_knob merge race
reset_calls
assert_exit 5 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: tree mismatch: the published commit"
assert_contains "$DS_STDERR" "but the tested tree is ${race_tree:0:12} (origin/main moved during the merge); nothing is released"
assert_contains "$DS_STDOUT" "[dotsteward] the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
squash=$(upstream_main)
race_pr=$(field .pr)
assert_eq "$squash" "$(git -C "$ct_clone" rev-parse HEAD)" "branch after the tree mismatch"
assert_eq "" "$(git -C "$ct_clone" status --porcelain)" "clone after the tree mismatch"
state_json | assert_json - ".step == \"check\" and .test_sha == null and .tested_tree == null and .trial == null
  and .trial_sha == null and .trial_switched == true and .merged_sha == \"$squash\" and .pr != null"
assert_eq switched "$(live)" "live framework after a tree mismatch"
assert_eq "" "$(instance_calls)" "instance commands after a tree mismatch"
assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "is not published yet; next: dotsteward contribute check"

# check validates upstream main as it is (the branch has no commits of its
# own), the trial switches to it, and publish takes it as the published
# commit: the merged pull request is neither merged nor opened again.
hub_knob merge normal
assert_exit 0 run_contribute check
assert_contains "$DS_STDOUT" "[dotsteward] fix/race has no commits after origin/main: its pull request is merged, so the merged origin/main is checked"
assert_eq "$squash" "$(field .test_sha)" "checked commit after the tree mismatch"
assert_exit 0 run_contribute trial
assert_eq "git+file://$ct_clone?rev=$squash" "$(live)" "live framework after the second trial"
reset_calls
assert_exit 0 run_contribute publish
assert_call_count 0 gh 'pr merge*'
assert_call_count 0 gh 'pr create*'
assert_contains "$DS_STDOUT" "[dotsteward] verified: ${squash:0:12} on origin/main has the tested tree"
state_json | assert_json - ".step == \"release\" and .merged_sha == \"$squash\" and .test_sha == \"$squash\"
  and .pr == \"$race_pr\""
assert_exit 0 run_contribute release
assert_eq "$squash" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{commit}')" "released commit"
assert_eq "$(field .tested_tree)" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{tree}')" "tree of the release"

# --- a closed pull request ----------------------------------------------------------------

checked_run closed 0.1.2
mark_trialled full false
hub_knob merge normal
hub_knob checks fail
assert_exit 1 run_contribute publish
pr=$(field .pr)
file=$(grep -l "\"$pr\"" "$rt_hub"/prs/*.json)
jq '.state = "CLOSED"' "$file" >"$file.new" && mv "$file.new" "$file"
hub_knob checks pass
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the pull request $pr is closed; reopen it, or end the run with: dotsteward contribute abort"
