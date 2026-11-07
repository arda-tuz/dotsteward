# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# tests/lib/hold.sh, the process a test keeps running on purpose: whatever happens
# to the test, it does not stay behind.

hold=$DS_REPO_ROOT/tests/lib/hold.sh
probe=$DS_TEST_ROOT/probe
mkdir -p "$probe"

# wait_for PATH: PATH appears within 30 seconds.
wait_for() {
  local _
  for _ in $(seq 1500); do
    [[ ! -e $1 ]] || return 0
    sleep 0.02
  done
  ds_fail "$1 did not appear"
}

# alive PID: the process runs (a zombie, waiting for its parent, does not).
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [[ ! -r /proc/$1/status ]] || ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"
}

# It says it has started and waits for the release.
bash "$hold" "$probe/started" "$probe/release" &
holder=$!
wait_for "$probe/started"
alive "$holder" || ds_fail "the holder did not wait for its release"
: >"$probe/release"
wait "$holder"

# A test that was killed removes nothing, so a time limit ends the wait, as a failure.
assert_exit 1 env DS_HOLD_TIMEOUT=1 bash "$hold" "$probe/limit-started" "$probe/never"
[[ -e $probe/limit-started ]] || ds_fail "the holder did not say it had started"

# A test that fails while a holder runs: the harness removes the root of the test and
# the holder goes with it.
cat >"$probe/test-leaves-a-holder.sh" <<'TEST'
bash "$DS_REPO_ROOT/tests/lib/hold.sh" "$DS_TEST_ROOT/started" "$DS_TEST_ROOT/release" &
printf '%s\n' "$!" >"$HOLD_PROBE/pid"
for _ in $(seq 1500); do
  [[ ! -e $DS_TEST_ROOT/started ]] || break
  sleep 0.02
done
ds_fail "a failure while a holder runs"
TEST
assert_exit 1 env HOLD_PROBE="$probe" bash "$DS_REPO_ROOT/tests/run.sh" --jobs 1 "$probe/test-leaves-a-holder.sh"
assert_contains "$DS_STDOUT" "a failure while a holder runs"
left=$(<"$probe/pid")
# As long as wait_for: on a busy machine the harness takes its time to remove the root.
for _ in $(seq 1500); do
  alive "$left" || break
  sleep 0.02
done
! alive "$left" || ds_fail "process $left stayed behind after its test had ended"
