# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# privacy/policy.toml: the shipped values, the TOML subset the reader
# accepts, strict validation (a policy the reader cannot fully understand is
# an error, never a silently disabled rule), and which policy a scan uses.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"
# shellcheck source=cli/lib/privacy.sh
source "$DS_REPO_ROOT/cli/lib/privacy.sh"

join() {
  local IFS=$1
  shift
  printf '%s' "$*"
}

# The shipped policy, value by value.
ds_privacy_load_policy "$DS_REPO_ROOT/privacy/policy.toml"
assert_eq 1 "$DS_PRIVACY_GENERIC_SECRETS" generic_secrets
assert_eq 1 "$DS_PRIVACY_HOME_PATHS" home_paths.enabled
assert_eq "alice dotsteward-test runner user example" "$(join ' ' "${DS_PRIVACY_HOME_ALLOW_USERS[@]}")"
assert_eq "/homeless-shelter" "$(join ' ' "${DS_PRIVACY_HOME_ALLOW_PATHS[@]}")"
assert_eq 1 "$DS_PRIVACY_EMAILS" emails.enabled
assert_eq "example.invalid example.com example.org users.noreply.github.com" \
  "$(join ' ' "${DS_PRIVACY_EMAIL_ALLOW_DOMAINS[@]}")"
assert_eq "git@github.com noreply@github.com" "$(join ' ' "${DS_PRIVACY_EMAIL_ALLOW_EXACT[@]}")"
assert_eq 1 "$DS_PRIVACY_PRIVATE_IPV4" private_ipv4
assert_eq 1 "$DS_PRIVACY_NON_ASCII" non_ascii.enabled
assert_eq 0 "${#DS_PRIVACY_NON_ASCII_EXCEPT[@]}" non_ascii.except_files
assert_eq ".private/** .work/** **/.env* result* **/*.local.json" "$(join ' ' "${DS_PRIVACY_FORBIDDEN_PATHS[@]}")"
assert_eq '^([0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com|noreply@github\.com)$' "$DS_PRIVACY_COMMIT_EMAIL"
assert_eq 1 "$DS_PRIVACY_COMMIT_UTC_ONLY" commits.utc_only
assert_eq '^Claude-Session:|^Co-Authored-By:|Generated with \[Claude Code\]' \
  "$(join '|' "${DS_PRIVACY_COMMIT_FORBIDDEN_LINES[@]}")"
# shellcheck disable=SC2088 # the policy keeps the tilde; the scanner expands it
assert_eq "~/.config/dotsteward/denylist.txt" "$DS_PRIVACY_DENYLIST_PATH"
assert_eq 1 "$DS_PRIVACY_DENYLIST_REQUIRED_FOR_RANGE" denylist.required_for_range

# The TOML subset: comments everywhere, multi-line arrays with a trailing
# comma, basic strings with escapes, literal strings, inline tables, tables
# in any order.
policy=$DS_TEST_ROOT/policy.toml
cat >"$policy" <<'EOF'
# leading comment
schema_version = 1 # trailing comment

[denylist]
required_for_range = false
path = "/tmp/a \"quoted\" path\\x" # comment after a string

[commits]
email = '^x@example\.com$'
utc_only = false
forbidden_lines = [
  '^One:', # comment inside an array
  "two # not a comment",
]

[emails]
enabled = false
allow_domains = []

[home_paths]
enabled = true
allow_users = ["a", 'b']
EOF
# Top-level keys may not follow a table header, so they come from a second
# block inserted before the first table.
top='generic_secrets = false
private_ipv4 = false
non_ascii = { enabled = true, except_files = ["docs/**", "*.txt"] }
forbidden_paths = []
'
{
  printf '%s' "$top"
  cat "$policy"
} >"$policy.new"
mv "$policy.new" "$policy"
ds_privacy_load_policy "$policy"
assert_eq 0 "$DS_PRIVACY_GENERIC_SECRETS"
assert_eq 0 "$DS_PRIVACY_PRIVATE_IPV4"
assert_eq 1 "$DS_PRIVACY_NON_ASCII"
assert_eq "docs/** *.txt" "$(join ' ' "${DS_PRIVACY_NON_ASCII_EXCEPT[@]}")"
assert_eq 0 "${#DS_PRIVACY_FORBIDDEN_PATHS[@]}"
assert_eq '/tmp/a "quoted" path\x' "$DS_PRIVACY_DENYLIST_PATH"
assert_eq 0 "$DS_PRIVACY_DENYLIST_REQUIRED_FOR_RANGE"
assert_eq '^x@example\.com$' "$DS_PRIVACY_COMMIT_EMAIL"
assert_eq 0 "$DS_PRIVACY_COMMIT_UTC_ONLY"
assert_eq '^One:|two # not a comment' "$(join '|' "${DS_PRIVACY_COMMIT_FORBIDDEN_LINES[@]}")"
assert_eq 0 "$DS_PRIVACY_EMAILS"
assert_eq 0 "${#DS_PRIVACY_EMAIL_ALLOW_DOMAINS[@]}"
assert_eq 0 "${#DS_PRIVACY_EMAIL_ALLOW_EXACT[@]}" "optional lists default to empty"
assert_eq 1 "$DS_PRIVACY_HOME_PATHS"
assert_eq "a b" "$(join ' ' "${DS_PRIVACY_HOME_ALLOW_USERS[@]}")"
assert_eq 0 "${#DS_PRIVACY_HOME_ALLOW_PATHS[@]}"

# Invalid policies: each one is a hard error naming the problem.
# expect_invalid MESSAGE SED_EXPRESSION: edits a copy of the shipped policy
# and expects the load to fail with MESSAGE.
expect_invalid() {
  local message=$1 expression=$2 file=$DS_TEST_ROOT/broken.toml
  sed "$expression" "$DS_REPO_ROOT/privacy/policy.toml" >"$file"
  assert_exit 1 ds_privacy_load_policy "$file"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: $file: $message"
}
expect_invalid "unsupported schema_version: 2" 's/^schema_version = 1/schema_version = 2/'
expect_invalid "unknown key: generic_secret" 's/^generic_secrets =/generic_secret =/'
expect_invalid "unknown key: home_paths.allowed_users" 's/allow_users/allowed_users/'
expect_invalid "unknown key: commits.mail" 's/^email = /mail = /'
expect_invalid "private_ipv4 must be a boolean" 's/^private_ipv4 = true/private_ipv4 = "yes"/'
expect_invalid "forbidden_paths must be a list of strings" 's/^forbidden_paths = .*/forbidden_paths = ".work"/'
expect_invalid "commits.forbidden_lines must be a list of strings" "s/^forbidden_lines = .*/forbidden_lines = [true]/"
expect_invalid "missing key: private_ipv4" '/^private_ipv4 =/d'
expect_invalid "missing key: commits.email" '/^email = /d'
expect_invalid "missing key: home_paths.enabled" 's/enabled = true, allow_users/allow_users/'
expect_invalid "line 2: duplicate key: schema_version" '1s/^/schema_version = 1\n/'
expect_invalid "line 13: unterminated string" '13s/"$//'
# shellcheck disable=SC2016 # a sed address, not a shell expansion
expect_invalid "line 15: unterminated array" '$a x = ["a"'
expect_invalid "line 3: unsupported value" '3s/"alice"/alice/'
expect_invalid "line 1: expected a key" '1s/^/= 1\n/'
expect_invalid "line 1: unsupported value" '1s/^schema_version = 1/schema_version = 1.5/'
expect_invalid "line 1: unexpected text after value" '1s/$/ extra/'
expect_invalid "line 2: unsupported escape in string" '2s/^/x = "a\\q"\n/'
expect_invalid "commits.email is not a valid regular expression" "s/^email = .*/email = '(['/"
expect_invalid "commits.forbidden_lines entry 1 is not a valid regular expression" "s/^forbidden_lines = \[/forbidden_lines = ['(', /"
expect_invalid "line 8: invalid table header" 's/^\[commits\]/[commits/'
expect_invalid "line 12: duplicate table: denylist" 's/^\[commits\]/[denylist]/'
assert_exit 1 ds_privacy_load_policy "$DS_TEST_ROOT/no-such-policy.toml"
assert_contains "$DS_STDERR" "privacy policy is missing or unreadable: $DS_TEST_ROOT/no-such-policy.toml"

# Which policy a scan uses: the scan root's privacy/policy.toml when present,
# otherwise the framework's own policy.
use_noreply_identity
new_repo repo
cd repo
non_ascii_word >note.txt
printf '%s\n' "$(address "$(rand_word 6)" "$(rand_word 6).test")" >contact.txt
assert_exit 1 scan --tree --redact
assert_eq "email contact.txt:1
non-ascii note.txt:1" "$DS_STDOUT"
copy_policy .
sed -i -e 's/^emails = { enabled = true/emails = { enabled = false/' \
  -e 's/except_files = \[\]/except_files = ["*.txt"]/' privacy/policy.toml
assert_exit 0 scan --tree --redact
assert_eq "[dotsteward] scan clean: 4 files, 0 commits" "$DS_STDOUT"

# A broken policy in the scan root stops the scan before any finding.
printf 'bogus = true\n' >>privacy/policy.toml
assert_exit 1 scan --tree --redact
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "privacy/policy.toml: unknown key: denylist.bogus"

# Disabled rules stay silent; enabled ones still fire.
copy_policy .
sed -i -e 's/^private_ipv4 = true/private_ipv4 = false/' -e 's/^generic_secrets = true/generic_secrets = false/' \
  -e 's/^home_paths = { enabled = true/home_paths = { enabled = false/' privacy/policy.toml
rm contact.txt note.txt
{
  ipv4 10 1 2 3
  echo
  pem_header
  echo
  home_path "$(rand_word 8)"
  echo
  non_ascii_word
  echo
} >mixed.txt
assert_exit 1 scan --tree --redact
assert_eq "non-ascii mixed.txt:4" "$DS_STDOUT"
