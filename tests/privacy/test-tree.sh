# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# `scan --tree`: file sources (git-visible files inside git, find outside),
# every generic content rule, forbidden paths, binary files, symlinks, the
# pattern-block exemption, redaction and the clean summary.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

user=$(rand_word 8)
domain=$(rand_word 8).test

# --- file sources inside git -------------------------------------------------
new_repo repo
cd repo
printf 'ignored.txt\nbuild/\n' >.gitignore
printf 'tracked\n' >tracked.txt
mkdir -p sub/dir
printf 'untracked\n' >sub/dir/untracked.txt
home_path "$user" >ignored.txt
mkdir build
home_path "$user" >build/out.txt
printf 'gone\n' >deleted.txt
git add -A
rm deleted.txt
# .gitignore, tracked.txt and sub/dir/untracked.txt; the deleted file is gone.
assert_exit 0 scan --tree
assert_eq "[dotsteward] scan clean: 3 files, 0 commits" "$DS_STDOUT"

# The scan root is the work tree root, also from a subdirectory.
(cd sub/dir && "$DS_CLI" scan --tree) >"$DS_TEST_ROOT/out.log"
assert_eq "[dotsteward] scan clean: 3 files, 0 commits" "$(<"$DS_TEST_ROOT/out.log")"

# An untracked, non-ignored file is scanned.
home_path "$user" >sub/leak.txt
assert_exit 1 scan --tree --redact
assert_eq "home-path sub/leak.txt:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 1 finding in 4 files, 0 commits" "$DS_STDERR"
rm sub/leak.txt

# --- every generic content rule ----------------------------------------------
cd "$DS_TEST_ROOT/work"
mkdir rules
cd rules
keyword=pass
keyword+=word
{
  pem_header RSA
  echo
  pem_header ""
  echo
  pem_header OPENSSH
  echo
  token AKIA 16
  token ghp_ 36
  token github_pat_ 40
  token AIza 35
  token sk- 32
  assignment "$keyword" "$(token v 12)"
} >secrets.txt
assert_exit 1 scan --tree --redact
assert_eq "secret-private-key secrets.txt:1
secret-private-key secrets.txt:2
secret-private-key secrets.txt:3
secret-aws-key secrets.txt:4
secret-github-token secrets.txt:5
secret-github-pat secrets.txt:6
secret-google-key secrets.txt:7
secret-sk-key secrets.txt:8
secret-assignment secrets.txt:9" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 9 findings in 1 files, 0 commits" "$DS_STDERR"
# Generic rules are case-insensitive.
tr '[:upper:]' '[:lower:]' <secrets.txt >lower.txt
rm secrets.txt
assert_exit 1 scan --tree --redact
assert_eq 9 "$(finding_count)" "lowercase secrets"
rm lower.txt

# Too-short tokens and plain words do not match.
{
  printf 'ghp_short\nsk-short\n'
  printf '%s: "set me"\n' "$keyword"
  echo "the $keyword field"
} >near-misses.txt
assert_exit 0 scan --tree
rm near-misses.txt

# Home paths: other users are findings; allowed users, URL paths and the
# Nix sandbox home are not.
{
  home_path "$user"                                        # 1 finding
  echo
  printf 'see file://%s\n' "$(home_path "$user" doc)"      # 2 finding
  printf '%s\n' "/Users/$user/Library"                     # 3 finding
  home_path alice                                          # 4
  echo
  home_path runner work                                    # 5
  echo
  printf '/Users/example/x /home/dotsteward-test/y /home/user/z\n' # 6
  printf 'https://example.com/home/%s/page\n' "$user"     # 7
  printf '/homeless-shelter/.cache /home/\n'               # 8
  # shellcheck disable=SC2016 # literal variable references, not expanded
  printf 'cd "$HOME/x" /home/$USER/y\n'                    # 9
  # Allowed users stay allowed after a slash delimiter.
  printf 'see file://%s\n' "$(home_path runner work)"      # 10
  printf 'x //%s =/HOME/Alice/y\n' "$(home_path alice)"    # 11
} >home.txt
assert_exit 1 scan --tree --redact
assert_eq "home-path home.txt:1
home-path home.txt:2
home-path home.txt:3" "$DS_STDOUT"
# Without --redact the matched text is shown.
assert_exit 1 scan --tree
assert_contains "$DS_STDOUT" "home-path home.txt:1: /home/$user"$'\n'
assert_contains "$DS_STDOUT" "home-path home.txt:2: /home/$user"$'\n'
rm home.txt

# E-mail addresses: allowed domains (and their subdomains) and exact allowed
# addresses pass; anything else is a finding.
{
  address "$user" "$domain"                           # 1 finding
  echo
  address other github.com                            # 2 finding
  echo
  address "$user" "example.com.$domain"               # 3 finding
  echo
  address a example.com                               # 4
  echo
  address b sub.example.org                           # 5
  echo
  address c example.invalid                           # 6
  echo
  printf 'git clone %s:owner/repo.git\n' "$(address git github.com)" # 7
  address noreply github.com                          # 8
  echo
  address 9+someone users.noreply.github.com          # 9
  echo
  printf 'version foo@1.2.3 and @scope/name@4.5.6\n'  # 10
} >mail.txt
assert_exit 1 scan --tree --redact
assert_eq "email mail.txt:1
email mail.txt:2
email mail.txt:3" "$DS_STDOUT"
assert_exit 1 scan --tree
assert_contains "$DS_STDOUT" "email mail.txt:1: $(address "$user" "$domain")"
rm mail.txt

# Private IPv4 ranges only.
{
  ipv4 10 0 0 1; echo                 # 1 finding
  ipv4 172 16 5 4; echo               # 2 finding
  ipv4 172 31 255 1; echo             # 3 finding
  printf 'host %s.\n' "$(ipv4 192 168 1 20)" # 4 finding
  ipv4 172 32 0 1; echo               # 5
  ipv4 8 8 8 8; echo                  # 6
  ipv4 127 0 0 1; echo                # 7
  printf 'v1%s0.0.0.1\n' 1            # 8 (110.0.0.1)
} >net.txt
assert_exit 1 scan --tree --redact
assert_eq "private-ipv4 net.txt:1
private-ipv4 net.txt:2
private-ipv4 net.txt:3
private-ipv4 net.txt:4" "$DS_STDOUT"
rm net.txt

# Non-ASCII bytes in text files.
{
  printf 'plain\n'
  non_ascii_word
  printf '\n'
  printf 'emoji %s\n' $'\xf0\x9f\x99\x82'
} >words.txt
assert_exit 1 scan --tree --redact
assert_eq "non-ascii words.txt:2
non-ascii words.txt:3" "$DS_STDOUT"
rm words.txt

# Several rules on one line are separate findings; repeated matches of one
# rule on one line are one finding.
printf '%s %s %s\n' "$(home_path "$user")" "$(address "$user" "$domain")" "$(address x "$domain")" >line.txt
assert_exit 1 scan --tree --redact
assert_eq "email line.txt:1
home-path line.txt:1" "$DS_STDOUT"
rm line.txt

# --- forbidden paths ---------------------------------------------------------
cd "$DS_TEST_ROOT/work"
new_repo paths
cd paths
mkdir -p notes deep/er docs src
for file in .env .env.production deep/er/.envrc notes/.env.local result result-2 \
  settings.local.json deep/er/x.local.json docs/result.md environment.md src/local.json; do
  printf 'ok\n' >"$file"
done
assert_exit 1 scan --tree --redact
assert_eq "forbidden-path .env (path)
forbidden-path .env.production (path)
forbidden-path deep/er/.envrc (path)
forbidden-path deep/er/x.local.json (path)
forbidden-path notes/.env.local (path)
forbidden-path result (path)
forbidden-path result-2 (path)
forbidden-path settings.local.json (path)" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 8 findings in 11 files, 0 commits" "$DS_STDERR"

# Content rules apply to file paths too. With redaction, a path with a
# generic match prints as path#<k> (its position in the sorted path list),
# also as the location of the file's content findings; a path whose match is
# allowed by the policy prints as is. Without redaction the output is
# unchanged.
cd "$DS_TEST_ROOT/work"
mkdir named
cd named
printf 'ok\n' >"$(non_ascii_word).txt"
assert_exit 1 scan --tree --redact
assert_eq "non-ascii path#1 (path)" "$DS_STDOUT"
assert_not_contains "$DS_STDOUT" "$(non_ascii_word)"
assert_exit 1 scan --tree
assert_eq "non-ascii $(non_ascii_word).txt (path): "$'\xc3\xa9' "$DS_STDOUT"
rm -- "$(non_ascii_word).txt"

github=$(token ghp_ 36)
mail=$(address bob "$domain")
home=$(home_path "$user")
home=${home%/*}
mkdir -p docs/git@github.com
home_path "$user" >"cfg-$github.json"
home_path "$user" >"docs/$mail.txt"
home_path "$user" >docs/git@github.com/readme.txt
home_path "$user" >docs/plain.txt
assert_exit 1 scan --tree --redact
assert_eq "secret-github-token path#1 (path)
home-path path#1:1
email path#2 (path)
home-path path#2:1
home-path docs/git@github.com/readme.txt:1
home-path docs/plain.txt:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 6 findings in 4 files, 0 commits" "$DS_STDERR"
output=$DS_STDOUT$DS_STDERR
assert_not_contains "$output" "$github"
assert_not_contains "$output" "ghp_"
assert_not_contains "$output" "$mail"
assert_not_contains "$output" "$domain"
assert_exit 1 scan --tree
assert_eq "secret-github-token cfg-$github.json (path): $github
home-path cfg-$github.json:1: $home
email docs/$mail.txt (path): $mail.txt
home-path docs/$mail.txt:1: $home
home-path docs/git@github.com/readme.txt:1: $home
home-path docs/plain.txt:1: $home" "$DS_STDOUT"

# --- binary files and symlinks -----------------------------------------------
cd "$DS_TEST_ROOT/work"
new_repo special
cd special
{
  printf 'bin\0ary\n'
  pem_header
  printf '\n'
} >blob.bin
{
  printf 'bin\0ary\n'
  pem_header
  printf '\n'
} >.env.bin
# A relative link, so the link text never depends on the temporary root.
pem_header >../outside.txt
ln -s ../outside.txt outside-link
ln -s "$(home_path "$user" target)" dangling-link
assert_exit 1 scan --tree --redact
assert_eq "forbidden-path .env.bin (path)
home-path dangling-link:1" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: scan found 2 findings in 4 files, 0 commits" "$DS_STDERR"

# --- outside git: find, without .git directories ----------------------------
cd "$DS_TEST_ROOT/work"
mkdir -p loose/.git loose/nested/.git loose/sub
home_path "$user" >loose/.git/config
home_path "$user" >loose/nested/.git/HEAD
printf 'one\n' >loose/a.txt
printf 'two\n' >loose/sub/b.txt
ln -s a.txt loose/link
cd loose
assert_exit 0 scan --tree
assert_eq "[dotsteward] scan clean: 3 files, 0 commits" "$DS_STDOUT"
home_path "$user" >sub/c.txt
assert_exit 1 scan --tree --redact
assert_eq "home-path sub/c.txt:1" "$DS_STDOUT"
rm sub/c.txt

# A directory that cannot be listed is an error, never a clean scan.
mkdir locked
chmod 000 locked
assert_exit 1 scan --tree
assert_contains "$DS_STDERR" "[dotsteward] ERROR: listing files failed"
assert_eq "" "$DS_STDOUT"
chmod 755 locked
rmdir locked

# An empty directory is clean.
cd "$DS_TEST_ROOT/work"
mkdir empty
cd empty
assert_exit 0 scan --tree
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"

# --- the pattern block of cli/lib/privacy.sh ----------------------------------
cd "$DS_TEST_ROOT/work"
mkdir -p exempt/cli/lib exempt/other
cd exempt
block() {
  printf '%s\n' "# dotsteward:patterns:begin"
  pem_header
  printf '\n'
  printf '%s\n' "# dotsteward:patterns:end"
}
{
  printf 'before\n'
  block
  pem_header
  printf '\n'
} >cli/lib/privacy.sh
block >other/privacy.sh
assert_exit 1 scan --tree --redact
assert_eq "secret-private-key cli/lib/privacy.sh:5
secret-private-key other/privacy.sh:2" "$DS_STDOUT"
# Without an end marker nothing is exempt.
sed -i '/patterns:end/d' cli/lib/privacy.sh
assert_exit 1 scan --tree --redact
assert_eq "secret-private-key cli/lib/privacy.sh:3
secret-private-key cli/lib/privacy.sh:4
secret-private-key other/privacy.sh:2" "$DS_STDOUT"
