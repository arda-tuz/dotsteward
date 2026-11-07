# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# What apply refuses, before the gate and before any change to the checkout: a change without a
# subject, a subject that is not a conventional commit, an unknown option, a checkout on another
# branch or with another origin, a checkout behind the remote, a lock that another command holds.
# A clean checkout on the published tip has nothing to apply and says so.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)

# Nothing to apply.
clear_log
assert_exit 0 apply --activate --publish
assert_contains "$DS_STDOUT" "nothing to apply"
assert_eq "" "$(<"$UP_LOG")" "no command ran"

# Usage errors: exit 2, nothing staged, nothing run.
edit "a change"
clear_log
assert_exit 2 apply --activate
assert_contains "$DS_STDERR" "-m"
assert_exit 2 apply -m "add the guide" --activate
assert_contains "$DS_STDERR" "conventional"
assert_exit 2 apply -m "docs: a change" --no-such-option
assert_exit 2 apply -m "docs: a change" --activate --no-activate
assert_eq "" "$(<"$UP_LOG")" "no command ran"
assert_eq " M docs/guide.md" "$(git -C "$up_inst" status --porcelain)" "nothing was staged"

# Another branch.
git -C "$up_inst" switch -q -c elsewhere
assert_exit 1 apply -m "docs: a change"
assert_contains "$DS_STDERR" "elsewhere"
git -C "$up_inst" switch -q main

# Another origin.
git -C "$up_inst" remote set-url origin git@github.com:someone/else.git
assert_exit 1 apply -m "docs: a change"
assert_contains "$DS_STDERR" "origin"
git -C "$up_inst" remote set-url origin "$UP_REMOTE"

# The remote moved since the transaction began: begin again, which fast-forwards.
push_from_elsewhere "a commit of another machine"
clear_log
assert_exit 1 apply -m "docs: a change"
assert_contains "$DS_STDERR" "dotsteward maintain begin"
assert_eq "$base" "$(head_oid)"
assert_no_step '^static '

# Another command holds the instance lock.
assert_exit 0 begin
moved=$(remote_oid)
assert_eq "$moved" "$(head_oid)" "begin fast-forwarded the checkout"
cat >"$DS_TEST_ROOT/hold.py" <<'PY'
import sys, time
from dotsteward_cli import locks
with locks.instance_lock("upgrade", state_root=sys.argv[1]):
    print("held", flush=True)
    time.sleep(60)
PY
PYTHONPATH=$fw/cli/python python3 "$DS_TEST_ROOT/hold.py" "$DOTSTEWARD_STATE_ROOT" >"$DS_TEST_ROOT/hold.out" &
holder=$!
for _ in $(seq 100); do
  [[ ! -s $DS_TEST_ROOT/hold.out ]] || break
  sleep 0.1
done
clear_log
assert_exit 1 apply -m "docs: a change" --activate --publish
assert_contains "$DS_STDERR" "upgrade"
assert_no_step '^static '
kill "$holder"
wait "$holder" 2>/dev/null || true
assert_eq "$moved" "$(head_oid)"
