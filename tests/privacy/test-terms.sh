# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Denylist and extra terms: entry kinds (plain, word:, re:), comments,
# case-insensitivity, entry line numbers in rule ids, allowlist masking,
# paths and commit fields, redaction (never a term in redacted output, and
# no path that contains one), --require-denylist and entry validation.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

plain=$(rand_word 10)
word=$(rand_word 6)
stem=$(rand_word 7)
extra=$(rand_word 9)
use_noreply_identity

denylist=$DS_TEST_ROOT/denylist.txt
cat >"$denylist" <<EOF
# private terms

$plain
word:$word
re:${stem}-[0-9]+
EOF
extra_terms=$DS_TEST_ROOT/extra.txt
printf '%s\n' "# extra" "$extra" >"$extra_terms"

new_repo repo
cd repo
copy_policy .
{
  printf 'first line\n'
  printf 'mentions %s in upper case\n' "${plain^^}"     # 2: plain, case-insensitive
  printf 'prefix%ssuffix\n' "$plain"                   # 3: plain substring
  printf 'a %s here\n' "$word"                         # 4: word
  printf 'a %sx here\n' "$word"                        # 5: no whole word
  printf 'build %s-42\n' "$stem"                       # 6: regex
  printf 'build %s-x\n' "$stem"                        # 7: no regex match
  printf 'and %s\n' "$extra"                           # 8: extra term
} >notes.txt
assert_exit 1 scan --tree --denylist "$denylist" --extra-terms "$extra_terms" --redact
assert_eq "denylist:3 notes.txt:2
denylist:3 notes.txt:3
denylist:4 notes.txt:4
denylist:5 notes.txt:6
extra-term:2 notes.txt:8" "$DS_STDOUT"
for term in "$plain" "${plain^^}" "$word" "$stem" "$extra"; do
  assert_not_contains "$DS_STDOUT$DS_STDERR" "$term"
done
# Without --redact the matched text is shown.
assert_exit 1 scan --tree --denylist "$denylist" --extra-terms "$extra_terms"
assert_contains "$DS_STDOUT" "denylist:3 notes.txt:2: ${plain^^}"
assert_contains "$DS_STDOUT" "denylist:5 notes.txt:6: $stem-42"
# Terms only apply when given.
assert_exit 0 scan --tree
rm notes.txt

# --- allowlist masking ----------------------------------------------------------
# Strings in the scan root's privacy/allowlist.txt are masked before term
# matching (case-insensitively); generic rules still see the original text.
org=$(rand_word 6)
printf '%s\n' "# public strings" "$org-$plain/widget" "$(address "$org" "$plain.test")" >privacy/allowlist.txt
{
  printf 'see %s-%s/widget\n' "$org" "$plain"                    # masked
  printf 'see %s-%s/WIDGET\n' "${org^^}" "${plain^^}"            # masked
  printf 'see %s-%s/other\n' "$org" "$plain"                     # finding
} >public.txt
printf 'mail %s\n' "$(address "$org" "$plain.test")" >mail.txt
assert_exit 1 scan --tree --denylist "$denylist" --redact
assert_eq "email mail.txt:1
email privacy/allowlist.txt:3
denylist:3 public.txt:3" "$DS_STDOUT"
printf '%s\n' "# public strings" "$org-$plain/widget" >privacy/allowlist.txt
rm public.txt mail.txt

# --- paths: a path that contains a term is a finding and is never printed in
# redacted output, not even as the location of another finding.
mkdir -p "docs/a-$plain"
printf 'clean\n' >"docs/a-$plain/readme.txt"
home_path "$(rand_word 8)" >"docs/a-$plain/home.txt"
printf 'clean\n' >docs/other.txt
assert_exit 1 scan --tree --denylist "$denylist" --redact
assert_eq "denylist:3 path#1 (path)
home-path path#1:1
denylist:3 path#2 (path)" "$DS_STDOUT"
assert_not_contains "$DS_STDOUT" "$plain"
assert_exit 1 scan --tree --denylist "$denylist"
assert_contains "$DS_STDOUT" "denylist:3 docs/a-$plain/home.txt (path): $plain"
assert_contains "$DS_STDOUT" "home-path docs/a-$plain/home.txt:1"
rm -r docs

# Binary content is skipped, a binary file's path is checked.
printf 'bin\0%s\n' "$plain" >data.bin
printf 'bin\0\n' >"zz-$word.bin"
assert_exit 1 scan --tree --denylist "$denylist" --redact
assert_eq "denylist:4 path#4 (path)" "$DS_STDOUT"
rm data.bin "zz-$word.bin"

# The pattern block exemption covers generic rules only, never terms.
mkdir -p cli/lib
printf '%s\n' "# dotsteward:patterns:begin" "$plain" "# dotsteward:patterns:end" >cli/lib/privacy.sh
assert_exit 1 scan --tree --denylist "$denylist" --redact
assert_eq "denylist:3 cli/lib/privacy.sh:2" "$DS_STDOUT"
rm -r cli

# --- commit fields and range blobs -------------------------------------------------
commit_all . "docs: base"
base=$(git rev-parse HEAD)
printf 'note about %s\n' "$extra" >range.txt
git add range.txt
GIT_AUTHOR_NAME="$plain dev" git commit -q -m "docs: range" -m "Refs $word."
first=$(short_sha . HEAD)
assert_exit 1 scan --range "$base..HEAD" --metadata --denylist "$denylist" --extra-terms "$extra_terms" --redact
assert_eq "denylist:3 commit $first author-name
denylist:4 commit $first message:3
extra-term:2 commit $first range.txt:1" "$DS_STDOUT"
# A public address in the allowlist is masked in identity fields too.
printf '%s\n' "noreply.github" >"$DS_TEST_ROOT/identity-terms.txt"
assert_exit 1 scan --range "$base..HEAD" --extra-terms "$DS_TEST_ROOT/identity-terms.txt" --redact
assert_eq "extra-term:1 commit $first author-email
extra-term:1 commit $first committer-email" "$DS_STDOUT"
printf '%s\n' "$NOREPLY_EMAIL" >>privacy/allowlist.txt
assert_exit 0 scan --range "$base..HEAD" --metadata --extra-terms "$DS_TEST_ROOT/identity-terms.txt" --redact
assert_eq "[dotsteward] scan clean: 1 files, 1 commits" "$DS_STDOUT"

# --- --require-denylist --------------------------------------------------------
# Without --denylist it uses the policy path (~ is the home directory).
assert_exit 1 scan --tree --require-denylist
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist file is missing or unreadable: ~/.config/dotsteward/denylist.txt"
assert_eq "" "$DS_STDOUT"
mkdir -p "$HOME/.config/dotsteward"
cp "$denylist" "$HOME/.config/dotsteward/denylist.txt"
printf '%s\n' "$word" >tree.txt
assert_exit 1 scan --tree --require-denylist --redact
assert_eq "denylist:4 tree.txt:1" "$DS_STDOUT"
rm tree.txt
assert_exit 0 scan --tree --require-denylist --redact
# A denylist without entries is refused when required, accepted otherwise.
printf '# nothing yet\n\n' >"$DS_TEST_ROOT/empty.txt"
assert_exit 1 scan --tree --denylist "$DS_TEST_ROOT/empty.txt" --require-denylist
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist has no entries: $DS_TEST_ROOT/empty.txt"
assert_exit 0 scan --tree --denylist "$DS_TEST_ROOT/empty.txt"

# --- entry validation: errors name the line, never the entry --------------------
bad=$DS_TEST_ROOT/bad.txt
secret_regex="$(rand_word 8)(["
printf '%s\n' "# header" "re:$secret_regex" >"$bad"
assert_exit 1 scan --tree --denylist "$bad"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist line 2: invalid regular expression"
assert_not_contains "$DS_STDERR" "$secret_regex"
printf '%s\n' "re:x*" >"$bad"
assert_exit 1 scan --tree --denylist "$bad"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist line 1: entry matches the empty string"
printf '%s\n' "ok" "word:" >"$bad"
assert_exit 1 scan --tree --extra-terms "$bad"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: extra-terms line 2: empty entry"
# Surrounding whitespace is ignored; a CRLF file works.
printf '  %s  \r\n' "$plain" >"$bad"
printf 'x %s y\n' "$plain" >crlf.txt
assert_exit 1 scan --tree --denylist "$bad" --redact
assert_eq "denylist:1 crlf.txt:1" "$DS_STDOUT"
