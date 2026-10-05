# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Which commits the hook scans: remote..local for an existing ref, the local
# tip minus every ref of the named remote for a new ref, the whole history
# for a push to a URL, nothing for a deletion. A force push over a remote
# commit that is unknown locally falls back to the new-ref range. One push
# with several refs is refused as a whole.
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

write_denylist "$(rand_word 12)"
leak=$(home_path "$(rand_word 8)")

hook_repo repo
cd repo

# A new ref on an empty remote: the whole history, clean.
assert_exit 0 push origin main
assert_contains "$(hook_output)" "[dotsteward] scan clean: 3 files, 1 commits"
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"

# An existing ref: only remote..local. A leak added and removed again is
# found at the commit that added it, although the tip's tree is clean.
add_file . notes.txt "$(printf 'one\n%s' "$leak")" "docs: add notes"
added=$(short_sha . HEAD)
add_file . notes.txt "one" "docs: trim notes"
assert_exit 1 push origin main
assert_eq "home-path commit $added notes.txt:2" "$(finding_lines)"
assert_contains "$(hook_output)" "[dotsteward] ERROR: scan found 1 finding in 2 files, 2 commits"
assert_contains "$(hook_output)" "push refused"
assert_not_contains "$(hook_output)" "$leak"
# Land the two commits without the hook, as if they predated it.
git push -q --no-verify origin main
leaky_history=$(git rev-parse main)

# The next push scans only its own commit, not the leak below it.
add_file . more.txt "more" "docs: add more"
assert_exit 0 push origin main
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"

# A new branch: the remote's refs are excluded, so only the new commit.
git switch -q -c feature
add_file . feature.txt "feature" "feat: add feature"
assert_exit 0 push origin feature
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_eq "$(git rev-parse feature)" "$(remote_sha ../repo.git feature)"

# A new branch whose unpushed history holds a leak is refused.
git switch -q -c topic main
add_file . topic.txt "$leak" "docs: add topic"
topic_leak=$(short_sha . HEAD)
add_file . topic.txt "topic" "docs: clean topic"
assert_exit 1 push origin topic
assert_eq "home-path commit $topic_leak topic.txt:1" "$(finding_lines)"
assert_eq "" "$(remote_sha ../repo.git topic)"

# A push to a URL has no remote-tracking refs to exclude: the whole history
# of the pushed commit, including the leak that predates the hook.
git switch -q main
assert_exit 1 push ../repo.git main:refs/heads/by-url
assert_eq "home-path commit $added notes.txt:2" "$(finding_lines)"
assert_eq "" "$(remote_sha ../repo.git by-url)"

# Several refs in one push: one leaky ref refuses the whole push, and the
# clean ref's scan still runs.
git switch -q -c clean-two main
add_file . two.txt "two" "docs: add two"
assert_exit 1 push origin clean-two topic
assert_eq "home-path commit $topic_leak topic.txt:1" "$(finding_lines)"
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_eq "" "$(remote_sha ../repo.git clean-two)"
assert_eq "" "$(remote_sha ../repo.git topic)"

# A deletion is not scanned and needs no denylist.
remove_denylist
assert_exit 0 push origin :feature
assert_eq "" "$(remote_sha ../repo.git feature)"
assert_not_contains "$(hook_output)" "scan"
write_denylist "$(rand_word 12)"

# A force push over a remote commit this clone has never seen: the hook
# cannot use remote..local and scans the tip minus the known remote refs.
cd "$DS_TEST_ROOT/work"
git clone -q repo.git other
add_file other other.txt "other" "docs: add other"
git -C other push -q --no-verify origin main
cd repo
git switch -q main
git reset -q --hard "$leaky_history"
add_file . replaced.txt "$leak" "docs: replace history"
replaced=$(short_sha . HEAD)
assert_exit 1 push --force origin main
assert_eq "home-path commit $replaced replaced.txt:1" "$(finding_lines)"
git reset -q --hard "$leaky_history"
add_file . replaced.txt "replaced" "docs: replace history"
assert_exit 0 push --force origin main
assert_contains "$(hook_output)" "[dotsteward] scan clean: 1 files, 1 commits"
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"
assert_no_hook_temp
