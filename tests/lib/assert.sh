# shellcheck shell=bash
# Assertions for dotsteward tests. Sourced by tests/run.sh into every test
# process together with tests/lib/harness.sh.
#
# Every assertion is silent on success. On failure it prints one line
# starting with "assertion failed:" to stderr (newlines in the message are
# shown as \n) and exits the test process with status 1, so tests/run.sh
# reports that line as the failure message.

ds_fail() {
  local message="$*"
  printf 'assertion failed: %s\n' "${message//$'\n'/\\n}" >&2
  exit 1
}

# Appends ": MESSAGE" to a failure description when a message was given.
_ds_with_message() {
  if [[ -n ${2:-} ]]; then
    printf '%s: %s' "$2" "$1"
  else
    printf '%s' "$1"
  fi
}

# assert_eq EXPECTED ACTUAL [MESSAGE]
assert_eq() {
  (($# >= 2)) || ds_fail "assert_eq: usage: assert_eq EXPECTED ACTUAL [MESSAGE]"
  [[ $1 == "$2" ]] && return 0
  ds_fail "$(_ds_with_message "expected [$1], got [$2]" "${3:-}")"
}

# assert_contains HAYSTACK NEEDLE [MESSAGE]  (fixed-string match)
assert_contains() {
  (($# >= 2)) || ds_fail "assert_contains: usage: assert_contains HAYSTACK NEEDLE [MESSAGE]"
  [[ $1 == *"$2"* ]] && return 0
  ds_fail "$(_ds_with_message "expected to contain [$2], got [$1]" "${3:-}")"
}

# assert_not_contains HAYSTACK NEEDLE [MESSAGE]  (fixed-string match)
assert_not_contains() {
  (($# >= 2)) || ds_fail "assert_not_contains: usage: assert_not_contains HAYSTACK NEEDLE [MESSAGE]"
  [[ $1 != *"$2"* ]] && return 0
  ds_fail "$(_ds_with_message "expected not to contain [$2], got [$1]" "${3:-}")"
}

# assert_exit EXPECTED_STATUS COMMAND [ARG...]
# Runs COMMAND in a subshell (errexit does not apply inside it) and compares
# its exit status. Its standard output and standard error are captured into
# DS_STDOUT and DS_STDERR (trailing newlines removed) and its status into
# DS_STATUS for later assertions; both streams are shown in the failure
# message when the status differs.
assert_exit() {
  (($# >= 2)) || ds_fail "assert_exit: usage: assert_exit EXPECTED_STATUS COMMAND [ARG...]"
  local expected=$1 status=0 out_file err_file
  shift
  out_file=$(mktemp "${TMPDIR:-/tmp}/dotsteward-assert.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/dotsteward-assert.XXXXXX")
  (
    trap - ERR
    "$@"
  ) >"$out_file" 2>"$err_file" || status=$?
  DS_STDOUT=$(<"$out_file")
  DS_STDERR=$(<"$err_file")
  rm -f -- "$out_file" "$err_file"
  # shellcheck disable=SC2034 # DS_STATUS is read by the calling test.
  DS_STATUS=$status
  [[ $status == "$expected" ]] && return 0
  ds_fail "expected exit $expected, got $status from [$*]; stdout [$DS_STDOUT]; stderr [$DS_STDERR]"
}

# assert_file_mode PATH OCTAL_MODE  (for example 600 or 0755)
assert_file_mode() {
  (($# == 2)) || ds_fail "assert_file_mode: usage: assert_file_mode PATH OCTAL_MODE"
  [[ -e $1 || -L $1 ]] || ds_fail "assert_file_mode: no such file [$1]"
  local actual expected
  actual=$(stat -c %a -- "$1")
  expected=$((8#$2))
  (($((8#$actual)) == expected)) && return 0
  ds_fail "expected mode $2 for [$1], got $actual"
}

# assert_symlink_to LINK TARGET  (compares the literal link text)
assert_symlink_to() {
  (($# == 2)) || ds_fail "assert_symlink_to: usage: assert_symlink_to LINK TARGET"
  [[ -L $1 ]] || ds_fail "expected [$1] to be a symlink"
  local actual
  actual=$(readlink -- "$1")
  [[ $actual == "$2" ]] && return 0
  ds_fail "expected [$1] to point to [$2], got [$actual]"
}

# assert_calls [LINE...]
# The call log ($DS_CALL_LOG, written by ds_record_call) must contain exactly
# the given lines, in order. Without arguments the log must be empty or absent.
assert_calls() {
  local expected="" actual="" line
  for line in "$@"; do
    expected+="$line"$'\n'
  done
  if [[ -s ${DS_CALL_LOG:?DS_CALL_LOG is not set} ]]; then
    actual=$(<"$DS_CALL_LOG")$'\n'
  fi
  [[ $actual == "$expected" ]] && return 0
  ds_fail "call log mismatch; expected [${expected%$'\n'}], got [${actual%$'\n'}]"
}

# assert_json FILE|- JQ_EXPRESSION [MESSAGE]
# Passes when `jq -e JQ_EXPRESSION` succeeds on the document ("-" reads stdin).
assert_json() {
  (($# >= 2)) || ds_fail "assert_json: usage: assert_json FILE|- JQ_EXPRESSION [MESSAGE]"
  local input=$1 expression=$2 document
  if [[ $input == - ]]; then
    document=$(cat)
  else
    [[ -f $input ]] || ds_fail "assert_json: no such file [$input]"
    document=$(<"$input")
  fi
  jq -e "$expression" >/dev/null 2>&1 <<<"$document" && return 0
  ds_fail "$(_ds_with_message "jq expression [$expression] is false or invalid for [$document]" "${3:-}")"
}

# assert_call_count EXPECTED NAME [GLOB]
# The call log must hold exactly EXPECTED calls of stub NAME whose logged
# argument text matches the shell glob GLOB (default: every call); see
# ds_call_count in harness.sh.
assert_call_count() {
  (($# == 2 || $# == 3)) || ds_fail "assert_call_count: usage: assert_call_count EXPECTED NAME [GLOB]"
  local actual
  actual=$(ds_call_count "$2" "${3:-*}") || ds_fail "assert_call_count: cannot read the call log"
  [[ $actual == "$1" ]] && return 0
  ds_fail "expected $1 calls of $2${3:+ matching [$3]}, got $actual; calls [$(ds_calls_of "$2")]"
}
