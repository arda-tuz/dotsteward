# shellcheck shell=bash
# The commit rules of the framework repository, checked before a commit
# exists (the pre-push hook and `dotsteward contribute check` refuse the same
# commits later, after the work is done): a conventional subject, no
# trailers or attribution lines in the message, UTC dates. Shared by
# `dotsteward contribute commit` and the commit-msg and pre-commit hooks of
# .githooks/, which source this file from the checkout they run in. It needs
# bash 4, git, grep and sed, and only defines constants and functions.
#
#   COMMIT_RULES_TYPES       the conventional commit types, as
#                            commit.conventional_types of `dotsteward context
#                            --json` lists them
#   COMMIT_RULES_SUBJECT     the ERE of a subject: TYPE(SCOPE)!: text, with
#                            SCOPE (lower case, digits, ._/-) and ! optional
#   COMMIT_RULES_FORBIDDEN_LINES
#                            EREs of message lines refused anywhere in the
#                            message (case-insensitive): the attribution
#                            lines, a superset of commits.forbidden_lines of
#                            privacy/policy.toml
#   commit_rules_message FILE
#                            the problems of the commit message in FILE, one
#                            per line (comment lines and everything from a
#                            scissors line on do not count, as git drops
#                            them): the subject, a trailer block (the
#                            `Key: value` lines that end the message, as git
#                            interpret-trailers reads them) and the forbidden
#                            lines; status 1 when there is any. Runs git in
#                            the current directory (the repository).
#   commit_rules_dates       the problems of the author and committer dates
#                            the next commit gets (`git var`, so
#                            GIT_AUTHOR_DATE, GIT_COMMITTER_DATE and TZ count
#                            as git applies them): any offset other than
#                            +0000; status 1 when there is any

COMMIT_RULES_TYPES=(feat fix perf refactor docs chore test build ci style revert)
COMMIT_RULES_SUBJECT="^($(
  IFS='|'
  printf '%s' "${COMMIT_RULES_TYPES[*]}"
))(\\([a-z0-9._/-]+\\))?!?: .+"
# shellcheck disable=SC2034 # read by the hooks and the commit step
COMMIT_RULES_FORBIDDEN_LINES=('^Co-Authored-By:' '^Signed-off-by:' '^Claude-Session:' 'Generated with \[Claude Code\]')

commit_rules_message() {
  local file=$1 text subject trailers pattern number found=0
  # The message as git keeps it: no comment lines, no verbose diff.
  text=$(sed '/^# -\{24\} >8 -\{24\}$/,$d' "$file" | git stripspace --strip-comments) || {
    printf 'cannot read the commit message %s\n' "$file"
    return 1
  }
  subject=${text%%$'\n'*}
  if [[ -z $subject ]]; then
    printf 'the commit message is empty\n'
    return 1
  fi
  if [[ ! $subject =~ $COMMIT_RULES_SUBJECT ]]; then
    printf 'the subject is not a conventional commit (TYPE(AREA): text, TYPE one of %s): %s\n' \
      "${COMMIT_RULES_TYPES[*]}" "$subject"
    found=1
  fi
  trailers=$(git interpret-trailers --parse <<<"$text" | sed -n 's/^\([^:]*\):.*$/\1/p' | awk '!seen[$0]++') || {
    printf 'cannot read the trailers of the commit message\n'
    return 1
  }
  if [[ -n $trailers ]]; then
    printf 'the message ends with trailers (%s): framework commits carry none\n' "${trailers//$'\n'/, }"
    found=1
  fi
  for pattern in "${COMMIT_RULES_FORBIDDEN_LINES[@]}"; do
    while IFS= read -r number; do
      [[ -n $number ]] || continue
      printf 'message line %s matches the forbidden line pattern %s\n' "$number" "$pattern"
      found=1
    done < <(grep -n -i -E -e "$pattern" <<<"$text" | cut -d: -f1 || true)
  done
  return "$found"
}

commit_rules_dates() {
  local who ident offset found=0
  for who in author committer; do
    ident=$(git var "GIT_${who^^}_IDENT") || {
      printf 'cannot read the %s identity of the next commit (git var GIT_%s_IDENT)\n' "$who" "${who^^}"
      found=1
      continue
    }
    offset=${ident##* }
    if [[ $offset != +0000 ]]; then
      printf 'the %s date would carry the offset %s, not +0000 (UTC)\n' "$who" "$offset"
      found=1
    fi
  done
  return "$found"
}
