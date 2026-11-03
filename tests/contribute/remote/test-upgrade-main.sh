# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute upgrade --main`: right after publish (no release
# needed: release trains), the instance follows the main commit that this
# run's check and trial passed for (the merged commit with the tested
# tree), pinned by its revision on the same repository URL
# (github:OWNER/REPO/<commit>, or a git+ URL with
# ?ref=refs/heads/main&rev=<commit>); flake.lock must lock that commit, the
# template-owned files come from it, and the commit subject names
# main@<commit>. Everything else is the upgrade of a release. --tag before a
# release is refused and names --main; a commit that did not pass check
# and trial is never followed; an interrupted upgrade continues on main.
# release refuses a run without a pending release and names --main too.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
published_run add-feature 0.1.0
merged=$(field .merged_sha)
base=$(git -C "$ct_inst" rev-parse HEAD)
id=$(current_id)

pinned() {
  call_line dotsteward-launcher "$@"
  call_line "dotsteward-$1" "${@:2}"
}

# --- no release: the refusals name --main ------------------------------------------------------

assert_exit 1 run_contribute release
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no release is pending at the merged commit ${merged:0:12}: VERSION is still 0.1.0, the release it is based on, so the next release bundles it (release trains); follow it with: dotsteward contribute upgrade --main, or end the run with: dotsteward contribute report"
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $id is not released; run: dotsteward contribute release (a release commit), or follow its merged commit with: dotsteward contribute upgrade --main"
assert_exit 1 run_contribute upgrade --tag v0.1.1 --main
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --tag and --main exclude each other"

# Only a commit that passed check and trial is followed.
state_set '.trial_sha = "0000000000000000000000000000000000000000"'
assert_exit 1 run_contribute upgrade --main
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the trial of run $id did not pass for its checked commit; the instance follows only a commit that passed check and trial"
state_set '.trial_sha = .test_sha | .tested_tree = "0000000000000000000000000000000000000000"'
assert_exit 1 run_contribute upgrade --main
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the merged commit ${merged:0:12} does not have the tested tree 000000000000; the instance follows only a commit that passed check and trial"
# shellcheck disable=SC2016 # jq variables
state_set '.tested_tree = $tree' --arg tree "$(git -C "$ct_clone" rev-parse "$merged^{tree}")"
assert_eq "" "$(instance_calls)" "instance commands of the refusals"

# --- the github form ---------------------------------------------------------------------------

reset_calls
assert_exit 0 run_contribute upgrade --main
assert_eq "$(
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$base"
  pinned update publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the upgrade to main"
assert_contains "$(cat "$ct_inst/flake.nix")" "dotsteward.url = \"github:example-org/dotsteward/$merged\";"
jq -e --arg sha "$merged" '.nodes.dotsteward.locked.rev == $sha
  and .nodes.dotsteward.original == {owner: "example-org", repo: "dotsteward", rev: $sha, type: "github"}' \
  "$ct_inst/flake.lock" >/dev/null || ds_fail "flake.lock does not lock the merged commit"
assert_eq "$(git -C "$ct_clone" show "$merged:template/bootstrap.sh")" "$(cat "$ct_inst/bootstrap.sh")" \
  "bootstrap.sh from the merged commit"
assert_eq "chore(dotsteward): upgrade to main@${merged:0:12}" "$(git -C "$ct_inst" log -1 --format=%s)" "upgrade commit subject"
assert_contains "$DS_STDOUT" "[dotsteward] flake.lock: dotsteward main@${merged:0:12} at ${merged:0:12}"
assert_contains "$DS_STDOUT" "[dotsteward] upgraded the instance to main@${merged:0:12}"
state_json | assert_json - '.upgrade_to == "main" and .tag == null and .step == "report" and .upgrade == "full"'

assert_exit 0 run_contribute report
assert_contains "$DS_STDOUT" "  release: none"
assert_contains "$DS_STDOUT" "  instance commit: $(git -C "$ct_inst" rev-parse HEAD)"
git -C "$ct_inst" push -q origin HEAD:main

# --- the git+ form, interrupted and resumed on main ----------------------------------------------

write_flake git
published_run second-feature 0.1.0
merged=$(field .merged_sha)
base=$(git -C "$ct_inst" rev-parse HEAD)
stand_in_fail gate '--scope maintain'
assert_exit 1 run_contribute upgrade --main
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: the gate failed on the upgraded instance"
assert_contains "$(cat "$ct_inst/flake.nix")" \
  "url = \"git+ssh://git@github.com/example-org/dotsteward?ref=refs/heads/main&rev=$merged\";"
jq -e --arg sha "$merged" '.nodes.dotsteward.locked.rev == $sha and .nodes.dotsteward.original.rev == $sha
  and .nodes.dotsteward.original.ref == "refs/heads/main"' "$ct_inst/flake.lock" >/dev/null ||
  ds_fail "flake.lock does not lock the merged commit from main"
stand_in_clear gate
assert_exit 1 run_contribute upgrade --tag v0.1.0
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the upgrade of run $(current_id) follows its merged commit on main; run: dotsteward contribute upgrade --main"
reset_calls
assert_exit 0 run_contribute upgrade
assert_eq "chore(dotsteward): upgrade to main@${merged:0:12}" "$(git -C "$ct_inst" log -1 --format=%s)" "subject of the resumed upgrade"
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD^)" "one upgrade commit on the base"
state_json | assert_json - '.upgrade_to == "main" and .step == "report"'
