# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# P1 exit drill, scanner side: six commits with one deliberate leak each,
# pushed to a bare remote, are scanned with exactly the arguments the
# pre-push hook uses (range, --metadata, --denylist, --require-denylist,
# --redact). Six redacted findings, none of the leaked strings in the
# output, and a refusal without the denylist. The hook's own drill through
# `git push` lives with the hook (tests/hooks).
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

generator=$DS_REPO_ROOT/tests/privacy/make-leak-commits.sh
[[ -x $generator ]] || ds_fail "make-leak-commits.sh is not executable"

term=$(rand_word 12)
denylist=$DS_TEST_ROOT/denylist.txt
printf '%s\n' "# drill denylist" "$term" >"$denylist"

git init -q --bare remote.git
mapfile -t shas < <(bash "$generator" repo "$term")
assert_eq 6 "${#shas[@]}" "the generator prints six commits"
cd repo
git remote add origin ../remote.git
git push -q origin main
assert_eq "${shas[5]}" "$(git -C ../remote.git rev-parse main)"
base=$(git rev-parse "${shas[0]}^")
assert_eq 1 "$(git rev-list --count "$base")" "a new directory gets one base commit"
[[ -f privacy/policy.toml ]] || ds_fail "the base commit carries the privacy policy"
# Only the third commit has a non-UTC date.
assert_eq "+0000 +0000
+0000 +0000
$(drill_offset) +0000
+0000 +0000
+0000 +0000
+0000 +0000" "$(git log --reverse --format='%ad %cd' --date=format:%z "$base..main")"

s() {
  printf '%s' "${shas[$1]:0:12}"
}
assert_exit 1 "$DS_REPO_ROOT/cli/commands/scan.sh" --range "$base..${shas[5]}" --metadata \
  --denylist "$denylist" --require-denylist --redact
assert_eq "home-path commit $(s 0) privacy-drill/leak-1.txt:1
email commit $(s 1) privacy-drill/leak-2.txt:1
commit-timezone commit $(s 2) author-date
commit-line commit $(s 3) message:3
denylist:2 commit $(s 4) privacy-drill/leak-5.txt:1
secret-private-key commit $(s 5) privacy-drill/leak-6.txt:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 6 findings in 6 files, 6 commits" "$DS_STDERR"
# Redacted: no leaked string anywhere in the output.
output=$DS_STDOUT$DS_STDERR
assert_not_contains "$output" "$term"
assert_not_contains "$output" "/home/"
assert_not_contains "$output" "@"
assert_not_contains "$output" ".test"
assert_not_contains "$output" "PRIVATE"
assert_not_contains "$output" "Claude-Session"
assert_not_contains "$output" "$(drill_offset)"

# The generic CI scan (no denylist) finds the other five.
assert_exit 1 scan --range "$base..main" --metadata --redact
assert_eq 5 "$(finding_count)"
assert_not_contains "$DS_STDOUT" "denylist"

# The tree of the tip holds the four content leaks.
assert_exit 1 scan --tree --denylist "$denylist" --require-denylist --redact
assert_eq "home-path privacy-drill/leak-1.txt:1
email privacy-drill/leak-2.txt:1
denylist:2 privacy-drill/leak-5.txt:1
secret-private-key privacy-drill/leak-6.txt:1" "$DS_STDOUT"

# Seventh run: the denylist is required and missing, so the scan refuses
# before scanning anything.
assert_exit 1 "$DS_REPO_ROOT/cli/commands/scan.sh" --range "$base..main" --metadata \
  --denylist "$DS_TEST_ROOT/missing-denylist.txt" --require-denylist --redact
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist file is missing or unreadable: $DS_TEST_ROOT/missing-denylist.txt"
assert_exit 1 scan --range "$base..main" --metadata --require-denylist --redact
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "denylist file is missing or unreadable: ~/.config/dotsteward/denylist.txt"

# The generator also stacks the drill on an existing repository's HEAD.
cd "$DS_TEST_ROOT/work"
use_noreply_identity
new_repo existing
printf 'existing\n' >existing/readme.txt
commit_all existing "docs: existing"
head=$(git -C existing rev-parse HEAD)
mapfile -t more < <(bash "$generator" existing "$term")
assert_eq 6 "${#more[@]}"
assert_eq "$head" "$(git -C existing rev-parse "${more[0]}^")"
mapfile -t again < <(bash "$generator" existing "$term")
assert_eq 6 "${#again[@]}" "a second run adds six more commits"
assert_eq "${more[5]}" "$(git -C existing rev-parse "${again[0]}^")"
assert_exit 1 bash "$generator" existing
assert_contains "$DS_STDERR" "usage: make-leak-commits.sh DIR DENYLIST_TERM"
mkdir not-a-repo
printf 'x\n' >not-a-repo/file
assert_exit 1 bash "$generator" not-a-repo "$term"
assert_contains "$DS_STDERR" "not a git work tree with a commit: not-a-repo"
