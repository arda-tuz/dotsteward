# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from the harness
# `scan --tree --secrets-only` looks at somebody else's tree for what is dangerous in any tree: the
# shape of real credentials. A name in an example, a word in another script, a mail address or a
# credential assignment in its documentation is the business of a publishing policy, not of this.
# The answers: 0 clean, 1 with findings on standard output, 1 with an error and none.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

mkdir plain
cd plain
# Assembled here too, so that this file passes the policy of the framework.
at=@
word=pass
printf 'Contact: someone%sexample.net\nText with \xc3\xa9\n%sword: see below\n/ho%s/someone/x\n' "$at" "$word" me >readme.txt
assert_exit 0 scan --tree --secrets-only --redact
assert_contains "$DS_STDOUT" "scan clean"

# The token in the file is assembled here, so this test itself has none.
prefix=ghp
printf 'token %s_%s\n' "$prefix" 123456789012345678901234567890abcdef >config.txt
assert_exit 1 scan --tree --secrets-only --redact
assert_contains "$DS_STDOUT" "secret-github-token config.txt"
assert_not_contains "$DS_STDOUT" "1234567890"
assert_not_contains "$DS_STDOUT" "readme.txt"

# It is one way or the other.
assert_exit 1 scan --tree --secrets-only --instance-policy
assert_contains "$DS_STDERR" "--secrets-only"
