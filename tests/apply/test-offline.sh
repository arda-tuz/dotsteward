# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# Without a network apply does what needs none: the gate, the commit, the rebuild and E2E without
# the repository checks, against the last known tip. The push waits (exit 6), and the same command
# with the network back runs E2E again with the repository checks, which txn publish asks for, and
# publishes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
assert_exit 0 begin

: >"$UP_CONTROL/network-down"
edit "offline"
clear_log
assert_exit 6 apply -m "docs: written offline" --activate --publish
assert_order '^static ' '^rebuild ' '^e2e .*--skip-repo-checks'
assert_eq "$base" "$(remote_oid)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)"
assert_eq partial "$(apply_step publish)"
apply_report '.status == "partial"'

rm -f -- "$UP_CONTROL/network-down"
clear_log
assert_exit 0 apply --activate --publish
assert_no_step '^rebuild '
assert_order "^e2e .*--expected-remote-base $base"
assert_no_step '^e2e .*--skip-repo-checks'
assert_eq "$(head_oid)" "$(remote_oid)"
