#!/usr/bin/env bash
# Creates the six deliberate privacy leaks of the privacy drill as six
# commits, one leak each, and prints their full SHAs, oldest first.
#
# Usage: tests/privacy/make-leak-commits.sh DIR DENYLIST_TERM
#
# DIR is either an existing git work tree with at least one commit (the
# commits go on top of HEAD) or a missing or empty directory, which becomes a
# new repository on branch main with a base commit that carries the
# framework privacy policy (so it is recognized as a framework repository).
#
# The leaks:
#   1. a home path in a file
#   2. an e-mail address with a non-allowed domain in a file
#   3. an author date with a non-UTC offset (-0700)
#   4. a Claude-Session line in the commit message
#   5. DENYLIST_TERM in a file (found only with a denylist that holds it)
#   6. a private-key header in a file
# Everything else satisfies the framework commit rules (noreply identity,
# UTC dates, no trailers), so a metadata range scan with the denylist reports
# exactly six findings. Secret-shaped strings are assembled at run time.
# The script is standalone: it needs only bash and git.
set -Eeuo pipefail

die() {
  printf 'make-leak-commits: %s\n' "$*" >&2
  exit 1
}

(($# == 2)) || die "usage: make-leak-commits.sh DIR DENYLIST_TERM"
dir=$1
term=$2
[[ -n $term && $term != *[[:space:]]* ]] || die "the denylist term must be one non-empty word"

script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
framework_root=$(cd -P -- "$script_dir/../.." && pwd)

export TZ=UTC
export GIT_AUTHOR_NAME=dotsteward-test GIT_COMMITTER_NAME=dotsteward-test
export GIT_AUTHOR_EMAIL=0+dotsteward-test@users.noreply.github.com
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
# The non-UTC offset of leak 3.
offset=-0700

git_in() {
  git -C "$dir" -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

rand_word() {
  local chars=abcdefghijklmnopqrstuvwxyz out="" i
  for ((i = 0; i < $1; i++)); do
    out+=${chars:RANDOM%26:1}
  done
  printf '%s' "$out"
}

if [[ ! -e $dir ]] || [[ -d $dir && -z $(ls -A -- "$dir") ]]; then
  mkdir -p -- "$dir"
  git -C "$dir" init -q
  git_in symbolic-ref HEAD refs/heads/main
  mkdir -p -- "$dir/privacy"
  for file in policy.toml allowlist.txt; do
    if [[ -f $framework_root/privacy/$file ]]; then
      cp -- "$framework_root/privacy/$file" "$dir/privacy/$file"
    fi
  done
  printf 'Privacy drill repository.\n' >"$dir/README.md"
  git_in add -A
  git_in commit -q --no-verify -m "chore: privacy drill base"
elif ! git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  die "not a git work tree with a commit: $dir"
fi

drill=privacy-drill
mkdir -p -- "$dir/$drill"

# leak N MESSAGE CONTENT [ENV...]: writes CONTENT and a nonce line (so a
# repeated run still changes the file) to privacy-drill/leak-N.txt and
# commits only that file with MESSAGE and the extra environment.
leak() {
  local n=$1 message=$2 content=$3 path
  shift 3
  path=$drill/leak-$n.txt
  printf '%s\ndrill %s\n' "$content" "$nonce" >"$dir/$path"
  git_in add -- "$path"
  env "$@" git -C "$dir" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --no-verify -m "$message" -- "$path"
  git_in rev-parse HEAD
}

nonce=$(rand_word 8)
dashes=-----
leak 1 "test: privacy drill leak 1 of 6" "notes in /home/$(rand_word 8)/notes"
leak 2 "test: privacy drill leak 2 of 6" "contact $(rand_word 8)@$(rand_word 8).test"
leak 3 "test: privacy drill leak 3 of 6" "timezone drill" GIT_AUTHOR_DATE="$(date +%s) $offset"
leak 4 "test: privacy drill leak 4 of 6

Claude-Session: https://example.invalid/session/$nonce" "session drill"
leak 5 "test: privacy drill leak 5 of 6" "term drill $term"
leak 6 "test: privacy drill leak 6 of 6" "${dashes}BEGIN OPENSSH PRIVATE KEY${dashes}
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
${dashes}END OPENSSH PRIVATE KEY${dashes}"
