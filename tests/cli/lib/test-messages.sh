# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ in test values and bash -c scripts
# log, warn and die (the [dotsteward] output convention), strict mode in the
# caller, require_command, timestamp_utc and ensure_private_dir.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

assert_exit 0 log "hello" "world"
assert_eq "[dotsteward] hello world" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_exit 0 warn "careful"
assert_eq "" "$DS_STDOUT"
assert_eq "[dotsteward] WARNING: careful" "$DS_STDERR"
assert_exit 1 die "broken" "thing"
assert_eq "" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: broken thing" "$DS_STDERR"
# A message is printed verbatim (no format interpretation).
assert_exit 0 log '%s %d \n'
assert_eq '[dotsteward] %s %d \n' "$DS_STDOUT"

# Sourcing the library turns on strict mode in the caller, like today.
assert_exit 0 in_lib_shell 'printf "%s|%s\n" "$-" "$(set -o | awk "\$1 == \"pipefail\" { print \$2 }")"'
[[ ${DS_STDOUT%%|*} == *e* && ${DS_STDOUT%%|*} == *u* && ${DS_STDOUT%%|*} == *E* ]] ||
  ds_fail "errexit, nounset and errtrace are on: $DS_STDOUT"
assert_eq on "${DS_STDOUT#*|}" "pipefail is on"
# A failing command stops the caller.
assert_exit 1 in_lib_shell 'false; echo unreachable'
assert_eq "" "$DS_STDOUT"

# require_command
assert_exit 0 require_command bash
# (A variable, so the command-name rule never sees an invented name.)
missing_command=dotsteward-test-missing-$RANDOM
assert_exit 1 require_command "$missing_command"
assert_eq "[dotsteward] ERROR: required command not found: $missing_command" "$DS_STDERR"

# timestamp_utc: sortable UTC stamps, the backup directory names.
stamp=$(timestamp_utc)
[[ $stamp =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || ds_fail "unexpected timestamp: $stamp"
assert_eq "$(TZ=Asia/Tokyo date -u +%Y%m%d)" "${stamp:0:8}"

# ensure_private_dir creates parents and forces 0700, also on existing
# directories.
ensure_private_dir "$DS_TEST_ROOT/private/a/b"
assert_file_mode "$DS_TEST_ROOT/private/a/b" 700
mkdir -p "$DS_TEST_ROOT/open"
chmod 0755 "$DS_TEST_ROOT/open"
ensure_private_dir "$DS_TEST_ROOT/open"
assert_file_mode "$DS_TEST_ROOT/open" 700
(cd "$DS_TEST_ROOT" && ensure_private_dir -leading-dash)
assert_file_mode "$DS_TEST_ROOT/-leading-dash" 700
