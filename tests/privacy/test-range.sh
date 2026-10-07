# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# `scan --range`: blobs changed by every commit in the range (so a leak that
# a later commit removes is still found), commit messages and identities,
# annotated tags, the commit rules under --metadata, and the history
# rewriting features (mailmap, replace refs) that must not hide anything.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

user=$(rand_word 8)
domain=$(rand_word 8).test
leak=$(home_path "$user")
use_noreply_identity

new_repo repo
cd repo
printf 'base\n' >readme.txt
commit_all . "docs: base"
base=$(git rev-parse HEAD)

# A leak added and removed again is found at the commit that added it.
printf 'one\n%s\n' "$leak" >notes.txt
commit_all . "docs: add notes"
added=$(short_sha . HEAD)
printf 'one\n' >notes.txt
commit_all . "docs: trim notes"
assert_exit 1 scan --range "$base..HEAD" --redact
assert_eq "home-path commit $added notes.txt:2" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 1 finding in 2 files, 2 commits" "$DS_STDERR"
# The tree of the tip is clean.
assert_exit 0 scan --tree

# Content rules apply to the message and the identity fields.
printf 'two\n' >>notes.txt
git add notes.txt
git commit -q -m "docs: extend notes" -m "Contact $(address "$user" "$domain") for details."
message_commit=$(short_sha . HEAD)
printf 'three\n' >>notes.txt
git add notes.txt
GIT_AUTHOR_NAME="$(non_ascii_word) dev" git commit -q -m "docs: more notes"
name_commit=$(short_sha . HEAD)
assert_exit 1 scan --range "$base..HEAD" --redact
assert_eq "home-path commit $added notes.txt:2
email commit $message_commit message:3
non-ascii commit $name_commit author-name" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 3 findings in 4 files, 4 commits" "$DS_STDERR"
assert_exit 1 scan --range "$base..HEAD"
assert_contains "$DS_STDOUT" "email commit $message_commit message:3: $(address "$user" "$domain")"
reset_point=$(git rev-parse HEAD)

# --- commit rules (--metadata) ------------------------------------------------
cd "$DS_TEST_ROOT/work"
new_repo meta
cd meta
printf 'base\n' >readme.txt
commit_all . "docs: base"
meta_base=$(git rev-parse HEAD)
printf 'a\n' >a.txt
git add a.txt
GIT_AUTHOR_EMAIL=dotsteward-test@example.invalid git commit -q -m "feat: a"
bad_author=$(short_sha . HEAD)
printf 'b\n' >b.txt
git add b.txt
GIT_COMMITTER_EMAIL=noreply@github.com GIT_COMMITTER_DATE="1700000000 $(drill_offset)" git commit -q -m "feat: b"
bad_committer_date=$(short_sha . HEAD)
printf 'c\n' >c.txt
git add c.txt
git commit -q -m "feat: c" -m "Body line." -m "Claude-Session: https://example.invalid/s/$(rand_word 6)"
session=$(short_sha . HEAD)
printf 'd\n' >d.txt
git add d.txt
git commit -q -m "feat: d" -m "co-authored-by: Someone <someone@example.com>"
coauthor=$(short_sha . HEAD)
printf 'e\n' >e.txt
git add e.txt
git commit -q -m "feat: e" -m "Generated with [Claude Code](https://example.com)"
generated=$(short_sha . HEAD)
printf 'f\n' >f.txt
git add f.txt
GIT_AUTHOR_DATE="1700000000 -0500" git commit -q -m "feat: f" -m "Mentions Claude-Session: mid-line, which is fine."
bad_author_date=$(short_sha . HEAD)

# Without --metadata the commit rules do not apply.
assert_exit 0 scan --range "$meta_base..HEAD"
assert_eq "[dotsteward] scan clean: 6 files, 6 commits" "$DS_STDOUT"
assert_exit 1 scan --range "$meta_base..HEAD" --metadata --redact
assert_eq "commit-email commit $bad_author author-email
commit-timezone commit $bad_committer_date committer-date
commit-line commit $session message:5
commit-line commit $coauthor message:3
commit-line commit $generated message:3
commit-timezone commit $bad_author_date author-date" "$DS_STDOUT"
assert_exit 1 scan --range "$meta_base..HEAD" --metadata
assert_contains "$DS_STDOUT" "commit-email commit $bad_author author-email: dotsteward-test@example.invalid"
assert_contains "$DS_STDOUT" "commit-timezone commit $bad_author_date author-date: -0500"

# --- whole history, root commit, merges, binaries -----------------------------
cd "$DS_TEST_ROOT/work"
new_repo history
cd history
printf '%s\n' "$leak" >root.txt
commit_all . "docs: root"
root=$(short_sha . HEAD)
git checkout -q -b side
printf 'side\n%s\n' "$(address "$user" "$domain")" >side.txt
commit_all . "docs: side"
side=$(short_sha . HEAD)
git checkout -q main
printf 'main\n' >main.txt
{
  printf 'bin\0ary\n'
  pem_header
  printf '\n'
} >blob.bin
mkdir -p notes
printf '{}\n' >notes/app.local.json
commit_all . "docs: main"
main_commit=$(short_sha . HEAD)
git merge -q --no-edit side
git rm -q -r --cached notes
rm -rf notes
commit_all . "chore: drop local settings"
# Parallel branches have no fixed order in the walk, so compare sorted.
assert_exit 1 scan --range HEAD --metadata --redact
assert_eq "email commit $side side.txt:2
forbidden-path commit $main_commit notes/app.local.json (path)
home-path commit $root root.txt:1" "$(LC_ALL=C sort <<<"$DS_STDOUT")"
assert_eq "[dotsteward] ERROR: scan found 3 findings in 5 files, 5 commits" "$DS_STDERR"
# Several revisions, including exclusions. A merge contributes only what
# differs from all of its parents, so content of an excluded branch is not
# reported again.
assert_exit 1 scan --range "main ^$side" --redact
assert_eq "forbidden-path commit $main_commit notes/app.local.json (path)" "$DS_STDOUT"
assert_exit 0 scan --range "HEAD..HEAD"
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"
# Content that a merge adds itself (in no parent) is found at the merge.
before_merge=$(git rev-parse HEAD)
git checkout -q -b side2
printf 'side two\n' >side2.txt
commit_all . "docs: side2"
git checkout -q main
printf 'main two\n' >main2.txt
commit_all . "docs: main2"
git merge -q --no-commit side2
printf '%s\n' "$leak" >resolution.txt
git add resolution.txt
git commit -q -m "Merge branch side2"
merge=$(short_sha . HEAD)
assert_exit 1 scan --range "$before_merge..HEAD" --redact
assert_eq "home-path commit $merge resolution.txt:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 1 finding in 3 files, 3 commits" "$DS_STDERR"

# --- annotated tags -----------------------------------------------------------
cd "$DS_TEST_ROOT/work/repo"
git reset -q --hard "$reset_point"
printf 'tagged\n' >tagged.txt
commit_all . "docs: tagged"
GIT_COMMITTER_DATE="1700000000 $(drill_offset)" git tag -a v1 -m "release for $(address "$user" "$domain")"
tag_v1=$(short_sha . v1)
git tag lightweight
GIT_COMMITTER_EMAIL=dotsteward-test@example.invalid git tag -a v0 -m "old" "$base"
tip=$(git rev-parse HEAD)
assert_exit 1 scan --range "$reset_point..HEAD" --metadata --redact
assert_eq "commit-timezone tag $tag_v1 tagger-date
email tag $tag_v1 message:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 2 findings in 1 files, 1 commits" "$DS_STDERR"
# A tag named as the range end is scanned even when the commit is not new.
git tag -d v1 >/dev/null
GIT_COMMITTER_EMAIL=dotsteward-test@example.invalid git tag -a v2 -m "plain" "$tip"
tag_v2=$(short_sha . v2)
assert_exit 1 scan --range "$tip..v2" --metadata --redact
assert_eq "commit-email tag $tag_v2 tagger-email" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 1 finding in 0 files, 0 commits" "$DS_STDERR"

# --- mailmap and replace refs never hide a commit's real content -------------
cd "$DS_TEST_ROOT/work"
new_repo hidden
cd hidden
printf 'base\n' >readme.txt
commit_all . "docs: base"
hidden_base=$(git rev-parse HEAD)
printf 'data\n' >data.txt
git add data.txt
GIT_AUTHOR_EMAIL=$(address "$user" "$domain") git commit -q -m "docs: data"
mapped=$(short_sha . HEAD)
printf '%s <%s> <%s>\n' dotsteward-test "$NOREPLY_EMAIL" "$(address "$user" "$domain")" >.mailmap
# The mailmap is effective for git log.
assert_eq "$NOREPLY_EMAIL" "$(git log -1 --format=%aE)"
printf '%s\n' "$leak" >leak.txt
commit_all . "docs: leak"
leaky=$(git rev-parse HEAD)
leaky_short=${leaky:0:12}
git rm -q leak.txt
clean=$(git commit-tree -p "$leaky^" -m "docs: leak" "$(git write-tree)")
git replace "$leaky" "$clean"
git reset -q --hard
# The replacement is effective for ordinary git commands.
assert_eq "" "$(git ls-tree --name-only HEAD leak.txt)"
assert_exit 1 scan --range "$hidden_base..HEAD" --metadata --redact
assert_eq "commit-email commit $mapped author-email
email commit $mapped author-email
email commit $leaky_short .mailmap:1
home-path commit $leaky_short leak.txt:1" "$DS_STDOUT"
