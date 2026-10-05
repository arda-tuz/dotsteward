# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# `scan --staged`: the staged set is every path whose index entry differs
# from HEAD (or every index entry before the first commit), read from the
# index blobs, never from the working tree. An empty set passes.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

user=$(rand_word 8)
leak=$(home_path "$user")

new_repo repo
cd repo

# Before the first commit every index entry is staged.
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"
printf '%s\n' "$leak" >first.txt
git add first.txt
assert_exit 1 scan --staged --redact
assert_eq "home-path first.txt:1" "$DS_STDOUT"
printf 'clean\n' >first.txt
git add first.txt
commit_all . "docs: first"

# Committed content that is not staged again is not part of the set.
printf '%s\n' "$leak" >committed.txt
git add committed.txt
git commit -q -m "docs: committed"
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"

# The index blob is scanned, not the working tree file.
printf 'line one\n%s\n' "$leak" >notes.txt
git add notes.txt
printf 'line one\nclean now\n' >notes.txt
assert_exit 1 scan --staged --redact
assert_eq "home-path notes.txt:2" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 1 finding in 1 files, 0 commits" "$DS_STDERR"
git add notes.txt
printf '%s\n' "$leak" >notes.txt
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"

# Untracked files are not staged.
printf '%s\n' "$leak" >untracked.txt
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"
rm untracked.txt
git checkout -q -- notes.txt

# Staged deletions are skipped; modifications and renames are scanned under
# their new path.
git rm -q --cached committed.txt
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"
git add committed.txt
git mv committed.txt moved.txt
assert_exit 1 scan --staged --redact
assert_eq "home-path moved.txt:1" "$DS_STDOUT"
git mv moved.txt committed.txt
assert_exit 0 scan --staged

# Forbidden paths, binary blobs and symlinks in the index.
mkdir -p conf
printf 'KEY=value\n' >conf/.env
{
  printf 'bin\0ary\n'
  pem_header
  printf '\n'
} >image.bin
ln -s "$(home_path "$user" target)" link
git add conf/.env image.bin link
assert_exit 1 scan --staged --redact
assert_eq "forbidden-path conf/.env (path)
home-path link:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 2 findings in 4 files, 0 commits" "$DS_STDERR"

# Paths are relative to the work tree root, also from a subdirectory.
cd conf
assert_exit 1 scan --staged --redact
assert_eq "forbidden-path conf/.env (path)
home-path link:1" "$DS_STDOUT"
