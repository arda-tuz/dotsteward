# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh and assert.sh
# Every assertion passes silently on good input and, on bad input, exits 1
# with one "assertion failed:" line on stderr.

# expect_failure FRAGMENT COMMAND [ARG...]: COMMAND must exit 1, print
# nothing on stdout and print a single assertion line containing FRAGMENT.
# Written with plain bash so it does not depend on the code under test.
expect_failure() {
  local fragment=$1 out err status=0
  shift
  out=$(mktemp)
  err=$(mktemp)
  ("$@") >"$out" 2>"$err" || status=$?
  if [[ $status != 1 ]]; then
    printf 'expected exit 1 from [%s], got %s\n' "$*" "$status" >&2
    exit 1
  fi
  if [[ -s $out ]]; then
    printf 'expected no stdout from [%s], got [%s]\n' "$*" "$(<"$out")" >&2
    exit 1
  fi
  if [[ $(wc -l <"$err") -ne 1 || $(<"$err") != "assertion failed: "*"$fragment"* ]]; then
    printf 'expected one assertion line with [%s] from [%s], got [%s]\n' \
      "$fragment" "$*" "$(<"$err")" >&2
    exit 1
  fi
  rm -f "$out" "$err"
}

# expect_success COMMAND [ARG...]: COMMAND must exit 0 without output.
expect_success() {
  local output status=0
  output=$("$@" 2>&1) || status=$?
  if [[ $status != 0 || -n $output ]]; then
    printf 'expected silent success from [%s], got exit %s and [%s]\n' "$*" "$status" "$output" >&2
    exit 1
  fi
}

# assert_eq
expect_success assert_eq abc abc
expect_success assert_eq "" ""
expect_failure 'expected [abc], got [abd]' assert_eq abc abd
expect_failure 'the label: expected [1], got [2]' assert_eq 1 2 "the label"
expect_failure 'usage' assert_eq only-one
# Multi-line values stay on one failure line.
expect_failure 'expected [a\nb], got [c]' assert_eq $'a\nb' c

# assert_contains / assert_not_contains (fixed strings, not globs)
expect_success assert_contains "hello world" "lo wo"
expect_failure 'expected to contain [*]' assert_contains "hello" "*"
expect_failure 'expected to contain [xyz]' assert_contains "hello" "xyz"
expect_success assert_not_contains "hello" "xyz"
expect_success assert_not_contains "hello" "*"
expect_failure 'expected not to contain [ell]' assert_not_contains "hello" "ell"

# assert_exit captures status and both streams.
emit() {
  printf 'out line\n'
  printf 'err line\n' >&2
  return "$1"
}
expect_success assert_exit 0 emit 0
assert_exit 3 emit 3
if [[ $DS_STATUS != 3 || $DS_STDOUT != "out line" || $DS_STDERR != "err line" ]]; then
  printf 'assert_exit captured [%s] [%s] [%s]\n' "$DS_STATUS" "$DS_STDOUT" "$DS_STDERR" >&2
  exit 1
fi
expect_failure 'expected exit 0, got 3' assert_exit 0 emit 3
expect_failure 'stderr [err line]' assert_exit 0 emit 3
# A command that calls exit must not end the test.
exits_five() { exit 5; }
assert_exit 5 exits_five
# Failing commands inside the checked command do not leak harness noise.
fails_inside() {
  false
  echo after
}
assert_exit 0 fails_inside
[[ $DS_STDERR == "" ]] || {
  echo "unexpected stderr [$DS_STDERR]" >&2
  exit 1
}

# assert_file_mode accepts 3 and 4 digit octal modes.
touch private public
chmod 600 private
chmod 0755 public
expect_success assert_file_mode private 600
expect_success assert_file_mode private 0600
expect_success assert_file_mode public 755
expect_failure 'expected mode 644 for [private], got 600' assert_file_mode private 644
expect_failure 'no such file [absent]' assert_file_mode absent 600

# assert_symlink_to compares the literal link text.
ln -s ../target link
expect_success assert_symlink_to link ../target
expect_failure 'expected [link] to point to [target], got [../target]' assert_symlink_to link target
expect_failure 'expected [private] to be a symlink' assert_symlink_to private target

# assert_calls compares the call log line by line.
expect_success assert_calls
ds_record_call example-app install "two words" --flag
ds_record_call example-term
expect_success assert_calls 'example-app install two\ words --flag' 'example-term'
expect_failure 'call log mismatch' assert_calls 'example-term' 'example-app install two\ words --flag'
expect_failure 'call log mismatch' assert_calls 'example-app install two\ words --flag'
expect_failure 'call log mismatch' assert_calls

# assert_json evaluates a jq expression on a file or stdin.
printf '{"a": 1, "b": [1, 2]}\n' >doc.json
expect_success assert_json doc.json '.a == 1 and (.b | length) == 2'
expect_success assert_json - '.ok' <<<'{"ok": true}'
expect_failure 'jq expression [.a == 2]' assert_json doc.json '.a == 2'
expect_failure 'jq expression [.a ==]' assert_json doc.json '.a =='
expect_failure 'not json: jq expression' assert_json - '.' "not json" <<<'{'
expect_failure 'no such file [absent.json]' assert_json absent.json '.'
