# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# P1 exit drill through `git push` (SPEC 12.6): a copy of the framework's
# hook, CLI and privacy policy is committed to a repository that installs the
# hook the way the dev checkout does (core.hooksPath=.githooks, relative).
# A clean push passes; six commits with one deliberate leak each are refused
# with six redacted findings; a seventh push without the denylist is refused
# for the missing denylist before anything is scanned.
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

term=$(rand_word 12)
write_denylist "$term"

new_repo repo
git init -q --bare repo.git
cp -R "$DS_REPO_ROOT/.githooks" "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/privacy" repo/
commit_all repo "chore: framework copy"
cd repo
git config core.hooksPath .githooks
git remote add origin ../repo.git

# The framework itself passes its own hook.
assert_exit 0 push origin main
assert_contains "$(hook_output)" "[dotsteward] scan clean:"
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"
base=$(git rev-parse main)

mapfile -t shas < <(bash "$DS_REPO_ROOT/tests/privacy/make-leak-commits.sh" . "$term")
assert_eq 6 "${#shas[@]}" "the generator prints six commits"
s() {
  printf '%s' "${shas[$1]:0:12}"
}

assert_exit 1 push origin main
assert_eq "home-path commit $(s 0) privacy-drill/leak-1.txt:1
email commit $(s 1) privacy-drill/leak-2.txt:1
commit-timezone commit $(s 2) author-date
commit-line commit $(s 3) message:3
denylist:2 commit $(s 4) privacy-drill/leak-5.txt:1
secret-private-key commit $(s 5) privacy-drill/leak-6.txt:1" "$(finding_lines)"
output=$(hook_output)
assert_contains "$output" "[dotsteward] ERROR: scan found 6 findings in 6 files, 6 commits"
assert_contains "$output" "[dotsteward] ERROR: pre-push: push refused"
assert_eq "$base" "$(remote_sha ../repo.git main)" "the refused push changes nothing"
# Redacted: no leaked string anywhere in the output.
assert_not_contains "$output" "$term"
assert_not_contains "$output" "/home/"
assert_not_contains "$output" "@"
assert_not_contains "$output" ".test"
assert_not_contains "$output" "PRIVATE"
assert_not_contains "$output" "Claude-Session"
assert_not_contains "$output" "$(drill_offset)"
assert_no_hook_temp

# Seventh push: no denylist, so the hook refuses before scanning.
remove_denylist
assert_exit 1 push origin main
output=$(hook_output)
assert_contains "$output" "[dotsteward] ERROR: pre-push: the denylist ~/.config/dotsteward/denylist.txt is missing"
assert_contains "$output" "push refused"
assert_eq "" "$(finding_lines)" "nothing is scanned without the denylist"
assert_not_contains "$output" "scan clean"
assert_not_contains "$output" "scan found"
assert_eq "$base" "$(remote_sha ../repo.git main)"
assert_no_hook_temp
