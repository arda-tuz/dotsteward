# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# A whole owner-mode run, from start to report, through the real local
# steps: start, the reproduction, check (privacy scans and the Nix
# check), trial, publish, release, upgrade and report. The released tag's
# tree is the tested tree (the invariant behind the framework skill links),
# the instance pins the tag, and the report names the pull request, the
# merged commit, the release, the instance commit and the tests; it ends
# the run. --json prints the same as one document.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
start_run add-feature
id=$(current_id)

# Reproduce, then fix (VERSION and the template change with it).
printf 'grep -qx feature feature.txt\n' >>"$ct_clone/tests/example/test-feature.sh"
git -C "$ct_clone" commit -q -a -m 'test(example): reproduce the missing feature'
assert_exit 0 run_contribute check --expect-fail tests/example/test-feature.sh
printf 'feature\n' >"$ct_clone/feature.txt"
printf '0.1.1\n' >"$ct_clone/VERSION"
rt_bootstrap 0.1.1 >"$ct_clone/template/bootstrap.sh"
git -C "$ct_clone" add -A
git -C "$ct_clone" commit -q -m 'feat(example): add the feature'
assert_exit 0 run_contribute check
tested=$(git -C "$ct_clone" rev-parse HEAD)
tested_tree=$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')
assert_eq trial "$(field .step)" "step after check"

assert_exit 0 run_contribute trial
assert_exit 0 run_contribute publish
assert_exit 0 run_contribute release
assert_exit 0 run_contribute upgrade --tag v0.1.1

merged=$(upstream_main)
assert_eq "$tested_tree" "$(git -C "$ct_upstream_bare" rev-parse 'refs/tags/v0.1.1^{tree}')" "tree of the release"
jq -e --arg sha "$merged" '.nodes.dotsteward.locked.rev == $sha and .nodes.dotsteward.original.ref == "v0.1.1"' \
  "$ct_inst/flake.lock" >/dev/null || ds_fail "the instance does not pin the release"
assert_eq "$(git -C "$ct_inst" rev-parse HEAD)" "$(field .instance_commit)" "instance commit"
assert_eq pinned "$(live)" "live framework at the end"

# --- report -----------------------------------------------------------------------------------

assert_exit 0 run_contribute report
assert_contains "$DS_STDOUT" "[dotsteward] contribute run $id: completed"
assert_contains "$DS_STDOUT" "  pull request: https://github.com/$CT_UPSTREAM_SLUG/pull/1"
assert_contains "$DS_STDOUT" "  merged commit: $merged"
assert_contains "$DS_STDOUT" "  release: v0.1.1 (https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.1.1)"
assert_contains "$DS_STDOUT" "  instance commit: $(git -C "$ct_inst" rev-parse HEAD)"
assert_contains "$DS_STDOUT" "  framework gate: passed at $tested"
assert_contains "$DS_STDOUT" "  trial: full"
assert_contains "$DS_STDOUT" "  upgrade: full"
state_json | assert_json - '.step == "done" and .outcome == "completed"'

assert_exit 0 run_contribute report --json
assert_json - ".schema_version == 1 and .id == \"$id\" and .outcome == \"completed\" and .merged_sha == \"$merged\"" <<<"$DS_STDOUT"
assert_json - ".tag == \"v0.1.1\" and .release_url == \"https://github.com/$CT_UPSTREAM_SLUG/releases/tag/v0.1.1\"" <<<"$DS_STDOUT"
assert_json - ".tests == {gate: \"passed\", tested_commit: \"$tested\", tested_tree: \"$tested_tree\", trial: \"full\", upgrade: \"full\"}" <<<"$DS_STDOUT"
assert_json - '.trial_switched == false and .recovery == null' <<<"$DS_STDOUT"

# A finished run: start with the same slug begins a new one.
git -C "$ct_clone" switch -q main
git -C "$ct_clone" branch -q -D fix/add-feature
sleep 1
start_run add-feature
[[ $(current_id) != "$id" ]] || ds_fail "start resumed the finished run"
