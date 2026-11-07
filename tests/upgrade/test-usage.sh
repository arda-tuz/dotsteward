# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The command line: the two modes exclude each other, an accept key has a form, a refusal changes
# nothing. A busy instance is refused at once.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

assert_exit 2 upgrade --tracked --all
assert_exit 2 upgrade --accept nonsense
assert_exit 2 upgrade --no-such-flag
assert_eq "" "$(cat "$UP_LOG")" "a usage error must do nothing"

assert_exit 0 upgrade --help
assert_contains "$DS_STDOUT" "--tracked"
assert_contains "$DS_STDOUT" "--all"
assert_contains "$DS_STDOUT" "--plan"
assert_contains "$DS_STDOUT" "--accept"

# Another command holds the instance lock.
started=$DS_TEST_ROOT/lock-started
release=$DS_TEST_ROOT/lock-release
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 \
  python3 -s -P -m dotsteward_cli.internal lock run --holder example --state-root "$DOTSTEWARD_STATE_ROOT" -- \
  bash "$DS_REPO_ROOT/tests/lib/hold.sh" "$started" "$release" &
holder=$!
tries=0
until [[ -e $started ]]; do
  tries=$((tries + 1))
  ((tries < 1500)) || ds_fail "the lock holder did not start"
  sleep 0.02
done
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDERR" "example"
assert_no_step '^(sudo|apt|pins|rebuild|e2e)'
: >"$release"
wait "$holder"
