# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The denylist requirement and the commit rules. A framework repository
# (privacy/policy.toml at its root) cannot push without a usable denylist;
# any other repository falls back to the generic rules without one and uses
# the denylist when it exists. The framework commit rules (SPEC 0.2) refuse
# trailers, foreign e-mail addresses and non-UTC dates.
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

term=$(rand_word 12)

# --- framework repository -------------------------------------------------------
hook_repo repo
cd repo

# Missing denylist: refused before any scan, even for a clean push.
assert_exit 1 push origin main
assert_contains "$(hook_output)" "[dotsteward] ERROR: pre-push: the denylist ~/.config/dotsteward/denylist.txt is missing"
assert_not_contains "$(hook_output)" "scan clean"
assert_eq "" "$(remote_sha ../repo.git main)"

# A denylist without entries is refused by the scanner.
write_denylist
assert_exit 1 push origin main
assert_contains "$(hook_output)" "denylist has no entries"
assert_contains "$(hook_output)" "push refused"
assert_eq "" "$(remote_sha ../repo.git main)"

write_denylist "$term"
assert_exit 0 push origin main
assert_eq "$(git rev-parse main)" "$(remote_sha ../repo.git main)"

# Commit rules: the trailers the harness would add, a personal address and a
# local timezone are refused.
pushed=$(git rev-parse main)
printf 'a\n' >a.txt
git add a.txt
git commit -q -m "feat: a" -m "Co-Authored-By: Someone <noreply@example.com>"
coauthor=$(short_sha . HEAD)
printf 'b\n' >b.txt
git add b.txt
git commit -q -m "feat: b" -m "Generated with [Claude Code](https://example.com)"
generated=$(short_sha . HEAD)
printf 'c\n' >c.txt
git add c.txt
GIT_AUTHOR_EMAIL=dotsteward-test@example.invalid git commit -q -m "feat: c"
foreign=$(short_sha . HEAD)
printf 'd\n' >d.txt
git add d.txt
GIT_COMMITTER_DATE="1700000000 $(drill_offset)" git commit -q -m "feat: d"
local_date=$(short_sha . HEAD)
assert_exit 1 push origin main
output=$(finding_lines)
assert_contains "$output" "commit-line commit $coauthor message:3"
assert_contains "$output" "commit-line commit $generated message:3"
assert_contains "$output" "commit-email commit $foreign author-email"
assert_contains "$output" "commit-timezone commit $local_date committer-date"
assert_eq 4 "$(printf '%s\n' "$output" | grep -c '')"
assert_eq "$pushed" "$(remote_sha ../repo.git main)"

# --- other repository (no privacy/policy.toml) --------------------------------
cd "$DS_TEST_ROOT/work"
remove_denylist
hook_repo plain plain
cd plain

# Without a denylist the generic rules still run.
assert_exit 0 push origin main
assert_contains "$(hook_output)" "[dotsteward] WARNING: pre-push: no denylist at ~/.config/dotsteward/denylist.txt; generic rules only"
assert_contains "$(hook_output)" "[dotsteward] scan clean:"
assert_eq "$(git rev-parse main)" "$(remote_sha ../plain.git main)"
add_file . notes.txt "$(home_path "$(rand_word 8)")" "docs: add notes"
assert_exit 1 push origin main
assert_eq "home-path commit $(short_sha . HEAD) notes.txt:1" "$(finding_lines)"
git reset -q --hard HEAD^

# With a denylist its terms apply.
write_denylist "$term"
add_file . term.txt "$term" "docs: add term"
assert_exit 1 push origin main
assert_eq "denylist:2 commit $(short_sha . HEAD) term.txt:1" "$(finding_lines)"
assert_not_contains "$(hook_output)" "WARNING"
assert_not_contains "$(hook_output)" "$term"
assert_no_hook_temp
