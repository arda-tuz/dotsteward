# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The commit subject policy of update publish: in the update
# scope the last subject must be exactly commit.update_subject (earlier
# commits are not checked); in the maintain scope every subject after the
# base must be a conventional commit (feat, fix, perf, refactor, docs, chore,
# test, build, ci, style or revert, an optional lowercase scope of
# [a-z0-9._/-], an optional "!"). A refused subject stops the publish before
# any network call.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

assert_exit 0 run_update prepare --official-sources-only
base=$(head_oid)

# commit_subject SUBJECT: commits a change with SUBJECT and validates HEAD
# for SCOPE (default maintain).
commit_subject() {
  change_and_commit "$1"
  write_validation ".scope = \"${SCOPE:-maintain}\""
}

refused() {
  local message=$1
  shift
  reset_logs
  assert_exit 1 run_update publish "$@"
  assert_eq "[dotsteward] ERROR: $message" "$DS_STDERR"
  assert_no_network
  assert_eq "$base" "$(remote_oid)" "the remote moved"
}

# --- update scope -------------------------------------------------------------

SCOPE=update
commit_subject "chore: update pinned tool version"
refused "unexpected update commit subject: chore: update pinned tool version (expected $UP_UPDATE_SUBJECT)"
refused "unexpected update commit subject: chore: update pinned tool version (expected $UP_UPDATE_SUBJECT)" \
  --scope update

# Only the last subject counts in the update scope.
git -C "$up_inst" reset -q --hard "$base"
commit_subject "Not conventional at all"
commit_subject "$UP_UPDATE_SUBJECT"
reset_logs
assert_exit 0 run_update publish
assert_eq "$(head_oid)" "$(remote_oid)"
base=$(head_oid)
assert_exit 0 run_update prepare --official-sources-only

# The subject comes from commit.update_subject.
set_toml commit update_subject '"chore: refresh pins"'
SCOPE=update
commit_subject "$UP_UPDATE_SUBJECT"
refused "unexpected update commit subject: $UP_UPDATE_SUBJECT (expected chore: refresh pins)"
git -C "$up_inst" commit -q --amend -m "chore: refresh pins"
write_validation '.scope = "update"'
reset_logs
assert_exit 0 run_update publish --scope update
assert_eq "$(head_oid)" "$(remote_oid)"
base=$(head_oid)

# --- maintain scope -------------------------------------------------------------

SCOPE=maintain
assert_exit 0 run_update prepare --official-sources-only --scope maintain

for subject in "Fix the guide" "feat(Docs): uppercase scope" "feat:" "feature: unknown type" \
  "fix(docs) missing colon" "docs(a b): space in scope" "fix!:no space"; do
  git -C "$up_inst" reset -q --hard "$base"
  commit_subject "$subject"
  refused "commit subject is not a conventional commit: $subject" --scope maintain
done

# Every subject is checked; the message lists each bad one.
git -C "$up_inst" reset -q --hard "$base"
commit_subject "first bad"
commit_subject "docs: fine"
commit_subject "second bad"
refused "commit subject is not a conventional commit: second bad, first bad" --scope maintain

# Every accepted form.
git -C "$up_inst" reset -q --hard "$base"
for type in feat fix perf refactor docs chore test build ci style revert; do
  commit_subject "$type: plain $type"
done
commit_subject "feat(x)!: breaking change"
commit_subject "fix(a.b_c/d-1): every scope character"
commit_subject "refactor!: breaking without scope"
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
