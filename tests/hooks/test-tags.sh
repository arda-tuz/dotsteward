# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Pushed tags: an annotated tag's own metadata and message are scanned even
# when the commit it points to is already on the remote; a tag on unpushed
# commits brings their history into the scan; tag deletions are skipped.
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

term=$(rand_word 12)
write_denylist "$term"
mail=$(address "$(rand_word 8)" "$(rand_word 8).test")

hook_repo repo
cd repo
git push -q origin main

# Lightweight and annotated tags without leaks.
git tag v0.1.0
git tag -a v0.1.1 -m "release: v0.1.1"
assert_exit 0 push origin v0.1.0 v0.1.1
# Both tags share one tree, which is scanned once.
assert_eq 1 "$(hook_output | grep -c '^\[dotsteward\] pre-push: checking the tree of ')"
assert_eq 2 "$(hook_output | grep -c '^\[dotsteward\] pre-push: checking the commits up to ')"
assert_eq "$(git rev-parse v0.1.1)" "$(remote_sha ../repo.git refs/tags/v0.1.1)"
assert_eq "$(git rev-parse v0.1.0)" "$(remote_sha ../repo.git refs/tags/v0.1.0)"

# An annotated tag on a pushed commit, with a leak in its message.
git tag -a v0.2.0 -m "release: v0.2.0" -m "Contact $mail"
assert_exit 1 push origin v0.2.0
assert_eq "email tag $(short_sha . v0.2.0) message:3" "$(finding_lines)"
assert_contains "$(hook_output)" "push refused"
assert_not_contains "$(hook_output)" "$mail"
assert_eq "" "$(remote_sha ../repo.git refs/tags/v0.2.0)"

# A denylist term in the tag name, and a tagger date that is not UTC.
git tag -a "v0.3.0-$term" -m "release: v0.3.0"
GIT_COMMITTER_DATE="1700000000 $(drill_offset)" git tag -a v0.3.1 -m "release: v0.3.1"
assert_exit 1 push origin "v0.3.0-$term" v0.3.1
output=$(hook_output)
assert_contains "$output" "denylist:2 tag $(short_sha . "v0.3.0-$term") tag-name"
assert_contains "$output" "commit-timezone tag $(short_sha . v0.3.1) tagger-date"
assert_not_contains "$output" "$term"

# A tag on unpushed commits: their history is scanned as well.
add_file . notes.txt "$(home_path "$(rand_word 8)")" "docs: add notes"
leak_commit=$(short_sha . HEAD)
add_file . notes.txt "notes" "docs: trim notes"
git tag -a v0.4.0 -m "release: v0.4.0"
assert_exit 1 push origin v0.4.0
assert_eq "home-path commit $leak_commit notes.txt:1" "$(finding_lines)"

# Deleting a tag on the remote is not scanned.
remove_denylist
assert_exit 0 push origin :refs/tags/v0.1.0
assert_eq "" "$(remote_sha ../repo.git refs/tags/v0.1.0)"
assert_no_hook_temp
