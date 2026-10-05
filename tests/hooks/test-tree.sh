# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The tree scan of the pushed tip: it sees the committed tree (not the work
# tree), catches a leak that predates the pushed range, refuses a tip whose
# export attributes would hide files from it, and is not confused by a
# temporary directory that lies inside another repository.
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

term=$(rand_word 12)
write_denylist "$term"
leak=$(home_path "$(rand_word 8)")

hook_repo repo
cd repo
git push -q origin main

# Uncommitted leaks in the work tree are not part of the push.
printf '%s\n' "$leak" >untracked.txt
printf '%s\n' "$term" >>README.md
add_file . clean.txt "clean" "docs: add clean"
assert_exit 0 push origin main
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_contains "$(hook_output)" "[dotsteward] scan clean: 4 files, 0 commits"
git checkout -q -- README.md
rm untracked.txt

# A leak that reached the remote before the hook stays in the tip's tree:
# the range of the next push is clean, the tree scan refuses it.
add_file . old.txt "$term" "docs: add old"
git push -q --no-verify origin main
pushed=$(git rev-parse main)
add_file . new.txt "new" "docs: add new"
assert_exit 1 push origin main
assert_eq "denylist:2 old.txt:1" "$(finding_lines)"
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_contains "$(hook_output)" "[dotsteward] ERROR: scan found 1 finding in 6 files, 0 commits"
assert_contains "$(hook_output)" "push refused"
assert_not_contains "$(hook_output)" "$term"
assert_eq "$pushed" "$(remote_sha ../repo.git main)"
git rm -q old.txt
git commit -q -m "docs: remove old"
assert_exit 0 push origin main
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"

# Export attributes must not hide a file from the tree scan.
printf 'hidden.txt export-ignore\n' >.gitattributes
add_file . hidden.txt "hidden" "chore: hide a file from archives"
git add .gitattributes
git commit -q -m "chore: add attributes"
assert_exit 1 push origin main
assert_contains "$(hook_output)" "[dotsteward] ERROR: pre-push: the tree of $(short_sha . HEAD) could not be exported completely"
assert_contains "$(hook_output)" "push refused"
git rm -q .gitattributes
git commit -q -m "chore: remove attributes"
assert_exit 0 push origin main

# A push with GIT_DIR in the environment (git exports it to the hook): the
# tree scan must not consult that repository's index or ignore rules. The
# pushed branch holds a force-added, ignored file that the checked-out
# branch's index does not have.
git switch -q -c side
printf 'ignored.txt\n' >.gitignore
printf '%s\n' "$term" >ignored.txt
git add .gitignore
git add -f ignored.txt
git commit -q -m "chore: add an ignored file"
git push -q --no-verify origin side
add_file . side.txt "side" "docs: add side"
git switch -q main
[[ ! -e ignored.txt ]] || ds_fail "the checked-out branch must not have the ignored file"
GIT_DIR=$PWD/.git assert_exit 1 push origin side
assert_eq "denylist:2 ignored.txt:1" "$(finding_lines)"
assert_not_contains "$(hook_output)" "$term"

# A temporary directory inside another work tree: the tree scan still sees
# only the exported tip, not the outer repository's files.
outer=$DS_TEST_ROOT/outer
new_repo "$outer"
printf '%s\n' "$leak" >"$outer/leak.txt"
commit_all "$outer" "docs: outer"
mkdir "$outer/tmp"
add_file . last.txt "last" "docs: add last"
TMPDIR=$outer/tmp assert_exit 0 push origin main
assert_eq "" "$(finding_lines)"
assert_eq "" "$(compgen -G "$outer/tmp/dotsteward-hook.*" || true)"
assert_no_hook_temp
