# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers shared by the privacy tests. Not a test file (no test- prefix).
#
# The scanner scans this directory too, so every string that must trigger a
# rule (key headers, tokens, home paths, addresses, private IPv4 addresses,
# non-ASCII bytes) is assembled at run time from fragments or fake_secret.

DS_CLI=$DS_REPO_ROOT/cli/dotsteward

# scan [ARG...]: `dotsteward scan` in the current directory.
scan() {
  "$DS_CLI" scan "$@"
}

# Commit identity that satisfies the framework commit rules.
NOREPLY_EMAIL=1+dotsteward-test@users.noreply.github.com
use_noreply_identity() {
  export GIT_AUTHOR_NAME=dotsteward-test GIT_COMMITTER_NAME=dotsteward-test
  export GIT_AUTHOR_EMAIL=$NOREPLY_EMAIL GIT_COMMITTER_EMAIL=$NOREPLY_EMAIL
}

# new_repo DIR: an empty git repository on branch main.
new_repo() {
  git init -q "$1"
}

# commit_all DIR MESSAGE: commits every change in DIR.
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q --allow-empty -m "$2"
}

# short_sha DIR REV: the 12-character abbreviation the scanner prints.
short_sha() {
  local sha
  sha=$(git -C "$1" rev-parse --verify "$2^{object}")
  printf '%s' "${sha:0:12}"
}

# rand_word [LENGTH]: lowercase letters only.
rand_word() {
  local length=${1:-10} chars=abcdefghijklmnopqrstuvwxyz out="" i
  for ((i = 0; i < length; i++)); do
    out+=${chars:RANDOM%26:1}
  done
  printf '%s' "$out"
}

# token PREFIX LENGTH: PREFIX followed by LENGTH deterministic characters,
# for secret-shaped strings whose rule must be the only one to match (random
# characters could form a second token by chance).
token() {
  local chars=QWERTY0123456789 out="" i
  for ((i = 0; i < $2; i++)); do
    out+=${chars:i%16:1}
  done
  printf '%s%s\n' "$1" "$out"
}

# pem_header [TYPE]: a private-key header line (TYPE empty for the bare form).
pem_header() {
  local dashes=----- type=${1-RSA}
  [[ -z $type ]] || type+=" "
  printf '%sBEGIN %sPRIVATE KEY%s' "$dashes" "$type" "$dashes"
}

# home_path USER [REST]: /home/USER/REST
home_path() {
  printf '/%s/%s/%s' home "$1" "${2:-notes}"
}

# address LOCAL DOMAIN: LOCAL@DOMAIN
address() {
  printf '%s@%s' "$1" "$2"
}

# drill_offset: a non-UTC timezone offset (a fixed non-UTC zone). Built at run
# time because denylists may hold timezone literals.
drill_offset() {
  printf '+%s%s' 03 00
}

# ipv4 A B C D
ipv4() {
  printf '%s.%s.%s.%s' "$1" "$2" "$3" "$4"
}

# non_ascii_word: a word with one two-byte UTF-8 character.
non_ascii_word() {
  printf 'caf%s' $'\xc3\xa9'
}

# assignment KEYWORD VALUE: "KEYWORD = VALUE" for the secret-assignment rule.
assignment() {
  printf '%s = %s' "$1" "$2"
}

# copy_policy DIR: copies the framework policy and allowlist into DIR/privacy.
copy_policy() {
  mkdir -p "$1/privacy"
  cp "$DS_REPO_ROOT/privacy/policy.toml" "$DS_REPO_ROOT/privacy/allowlist.txt" "$1/privacy/"
}

# finding_count: the number of finding lines printed by the last assert_exit.
finding_count() {
  if [[ -z $DS_STDOUT ]]; then
    printf '0'
  else
    printf '%s\n' "$DS_STDOUT" | grep -c ''
  fi
}
