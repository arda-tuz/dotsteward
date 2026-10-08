# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute start --slug S`: branch
# fix/<slug> from a freshly fetched upstream main (owner: origin/main; fork:
# upstream/main, not the fork's main), and the run's state file
# <state>/contribute/<id>.json (mode 0600 in a 0700 directory) with every
# field of the run, plus the `current` pointer. Starting the same slug again
# resumes the run; a dirty clone, a missing clone and a branch no run
# records are refused before any write.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

# --- before setup -------------------------------------------------------------

write_denylist
assert_exit 1 run_contribute start --slug add-feature
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no framework clone at $ct_clone; run 'dotsteward contribute setup' first"
[[ ! -e $ct_runs ]] || ds_fail "start wrote state without a clone"

# --- owner --------------------------------------------------------------------

setup_owner
# The upstream moves after setup: start fetches it.
push_upstream docs/late.md 'late' 'docs: a later upstream commit'
upstream_head=$(upstream_main)
assert_exit 0 run_contribute start --slug add-feature
assert_contains "$DS_STDOUT" "[dotsteward] started run"
assert_contains "$DS_STDOUT" "branch fix/add-feature from origin/main ${upstream_head:0:12}"

assert_eq fix/add-feature "$(git -C "$ct_clone" symbolic-ref --short HEAD)" "checked-out branch"
assert_eq "$upstream_head" "$(git -C "$ct_clone" rev-parse HEAD)" "branch start"
if git -C "$ct_clone" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  ds_fail "the fix branch tracks a remote branch"
fi

id=$(current_id)
[[ $id =~ ^[0-9]{8}T[0-9]{6}Z-add-feature$ ]] || ds_fail "unexpected run id: $id"
state_file=$ct_runs/$id.json
assert_file_mode "$ct_runs" 700
assert_file_mode "$state_file" 600
assert_file_mode "$ct_runs/current" 600
state_json >"$DS_TEST_ROOT/state.json"
assert_json "$DS_TEST_ROOT/state.json" \
  '(keys | sort) == (["id","slug","mode","clone","branch","base_sha","test_sha","tested_tree","trial_switched","pr","merged_sha","tag","instance_commit","step"] | sort)'
assert_json "$DS_TEST_ROOT/state.json" ".id == \"$id\" and .slug == \"add-feature\" and .mode == \"owner\""
assert_json "$DS_TEST_ROOT/state.json" ".clone == \"$ct_clone\" and .branch == \"fix/add-feature\""
assert_json "$DS_TEST_ROOT/state.json" ".base_sha == \"$upstream_head\""
assert_json "$DS_TEST_ROOT/state.json" \
  '.test_sha == null and .tested_tree == null and .trial_switched == false and .pr == null'
assert_json "$DS_TEST_ROOT/state.json" \
  '.merged_sha == null and .tag == null and .instance_commit == null and .step == "reproduce"'

# Starting the same slug again resumes the run: same id, nothing reset.
clone_commit feature.txt 'feature' 'feat: add the feature'
git -C "$ct_clone" switch -q main
: >"$DS_CALL_LOG"
assert_exit 0 run_contribute start --slug add-feature
assert_contains "$DS_STDOUT" "[dotsteward] resuming run $id at step reproduce"
assert_eq "$id" "$(current_id)" "current run after the resume"
assert_eq fix/add-feature "$(git -C "$ct_clone" symbolic-ref --short HEAD)" "branch after the resume"
assert_eq "feature" "$(<"$ct_clone/feature.txt")" "the branch's work survives the resume"
assert_eq 1 "$(find "$ct_runs" -name '*.json' | wc -l)" "state files after the resume"
assert_call_count 0 gh

# A second slug is a second run and becomes current.
assert_exit 0 run_contribute start --slug other-fix
other=$(current_id)
[[ $other == *-other-fix && $other != "$id" ]] || ds_fail "unexpected second run id: $other"
assert_eq "$upstream_head" "$(git -C "$ct_clone" rev-parse HEAD)" "second branch start"

# --- refusals -----------------------------------------------------------------

# A dirty clone (tracked change or untracked file).
printf 'dirty\n' >>"$ct_clone/README.md"
assert_exit 1 run_contribute start --slug dirty-run
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the clone $ct_clone has uncommitted changes"
git -C "$ct_clone" checkout -q -- README.md
printf 'new\n' >"$ct_clone/untracked.txt"
assert_exit 1 run_contribute start --slug dirty-run
assert_contains "$DS_STDERR" "has uncommitted changes"
rm -f "$ct_clone/untracked.txt"
# Ignored files do not count.
mkdir -p "$ct_clone/ignored"
printf 'build output\n' >"$ct_clone/ignored/output.txt"

# A branch that no run records.
git -C "$ct_clone" branch fix/stray "$upstream_head"
assert_exit 1 run_contribute start --slug stray
assert_contains "$DS_STDERR" "[dotsteward] ERROR: branch fix/stray exists in $ct_clone but no run records it"
assert_eq 2 "$(find "$ct_runs" -name '*.json' | wc -l)" "state files after the refusals"
assert_eq "$other" "$(current_id)" "current run after the refusals"

# The upstream cannot be fetched.
assert_exit 1 env DS_FAKESSH_FAIL=1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$ct_inst" contribute start --slug offline
assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch main from origin"
assert_eq 2 "$(find "$ct_runs" -name '*.json' | wc -l)" "state files after the failed fetch"

# --- fork ---------------------------------------------------------------------

rm -rf -- "$ct_clone" "$ct_runs"
setup_fork
# The upstream moves ahead of the fork: the branch starts at upstream main.
push_upstream docs/ahead.md 'ahead' 'docs: upstream ahead of the fork'
upstream_head=$(upstream_main)
[[ $upstream_head != "$(fork_main)" ]] || ds_fail "the fixture fork should be behind the upstream"
assert_exit 0 run_contribute start --slug fork-fix
assert_contains "$DS_STDOUT" "branch fix/fork-fix from upstream/main ${upstream_head:0:12}"
assert_eq "$upstream_head" "$(git -C "$ct_clone" rev-parse HEAD)" "fork branch start"
state_json >"$DS_TEST_ROOT/state.json"
assert_json "$DS_TEST_ROOT/state.json" ".mode == \"fork\" and .base_sha == \"$upstream_head\""

assert_eq "" "$(temp_leftovers)" "temporary files left behind"
assert_call_count 0 nix
