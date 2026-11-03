# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the test files below are written with a literal $
# tests/run.sh with several files at once: --jobs N (or DS_TEST_JOBS, else
# the number of CPUs) bounds the files that run together, the output is the
# one of a run file after file (results in file order, the indented output
# of a failing file, the summary and the exit status), whatever order the
# files finish in, and 1 runs them strictly one after another. An
# interrupted run stops its test processes. Exercised on a scratch copy of
# the runner.
# shellcheck source=tests/skeleton/helpers.sh
source "$DS_REPO_ROOT/tests/skeleton/helpers.sh"

fw=$DS_TEST_ROOT/fw
copy_framework "$fw"
probe=$DS_TEST_ROOT/probe
export PARALLEL_PROBE=$probe

# The runner under test starts with SIGINT at its default disposition, as
# from a terminal, whatever its caller left it at: an asynchronous job of a
# non-interactive shell (a command an agent runs in the background, for one)
# starts with SIGINT ignored, which every child inherits and cannot trap.
default_int=()
if env --default-signal=INT true 2>/dev/null; then
  default_int=(--default-signal=INT)
fi

# run_suite DIR ARG...: the runner over DIR with ARG..., with no worker count
# of the caller's (an outer run's DS_TEST_JOBS).
run_suite() {
  local dir=$1
  shift
  env -u DS_TEST_JOBS "${default_int[@]}" bash "$fw/tests/run.sh" "$fw/tests/$dir" "$@"
}

# reset_probe: an empty probe directory for the next run.
reset_probe() {
  rm -rf "$probe"
  mkdir -p "$probe/running" "$probe/ended"
}

# A suite of six files that each wait until PARALLEL_WANT files run at the
# same time (fewer once fewer are left to run), or 30 seconds pass, and
# record how many ran together: a run with fewer files at once never reaches
# the count, one with more exceeds it.
mkdir -p "$fw/tests/barrier"
for name in a b c d e f; do
  cat >"$fw/tests/barrier/test-$name.sh" <<'EOF'
name=$(basename "$DS_TEST_FILE" .sh)
count() { find "$PARALLEL_PROBE/$1" -type f | wc -l | tr -d ' '; }
printf 'start %s\n' "$name" >>"$PARALLEL_PROBE/events"
: >"$PARALLEL_PROBE/running/$name"
for _ in $(seq 600); do
  left=$((6 - $(count ended)))
  (($(count running) >= (PARALLEL_WANT < left ? PARALLEL_WANT : left))) && break
  sleep 0.05
done
count running >>"$PARALLEL_PROBE/together"
sleep 0.2
rm "$PARALLEL_PROBE/running/$name"
: >"$PARALLEL_PROBE/ended/$name"
printf 'end %s\n' "$name" >>"$PARALLEL_PROBE/events"
EOF
done
barrier_pass="PASS tests/barrier/test-a.sh
PASS tests/barrier/test-b.sh
PASS tests/barrier/test-c.sh
PASS tests/barrier/test-d.sh
PASS tests/barrier/test-e.sh
PASS tests/barrier/test-f.sh
6 passed, 0 failed"

# most_together: the largest number of files that ran at the same time.
most_together() {
  sort -n "$probe/together" | tail -n 1
}

# --jobs 3: three files run together, never more.
reset_probe
PARALLEL_WANT=3 assert_exit 0 run_suite barrier --jobs 3
assert_eq "$barrier_pass" "$DS_STDOUT" "the results of --jobs 3"
assert_eq 3 "$(most_together)" "files running together under --jobs 3"

# --jobs 1: one file after another, in file order.
reset_probe
PARALLEL_WANT=1 assert_exit 0 run_suite barrier --jobs 1
assert_eq "$barrier_pass" "$DS_STDOUT" "the results of --jobs 1"
assert_eq 1 "$(most_together)" "files running together under --jobs 1"
assert_eq "start test-a
end test-a
start test-b
end test-b
start test-c
end test-c
start test-d
end test-d
start test-e
end test-e
start test-f
end test-f" "$(<"$probe/events")" "the order of a --jobs 1 run"

# DS_TEST_JOBS sets the count, --jobs wins over it, and the default is the
# number of CPUs (nproc).
reset_probe
DS_TEST_JOBS=2 PARALLEL_WANT=2 assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/barrier"
assert_eq 2 "$(most_together)" "files running together under DS_TEST_JOBS=2"
reset_probe
DS_TEST_JOBS=1 PARALLEL_WANT=3 assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/barrier" --jobs=3
assert_eq 3 "$(most_together)" "files running together under --jobs=3 over DS_TEST_JOBS=1"
mkdir -p "$DS_TEST_ROOT/cpus"
# The running bash as the interpreter: the build sandbox has no /usr/bin/env.
printf '#!%s\necho 2\n' "$BASH" >"$DS_TEST_ROOT/cpus/nproc"
chmod 0755 "$DS_TEST_ROOT/cpus/nproc"
reset_probe
PATH=$DS_TEST_ROOT/cpus:$PATH PARALLEL_WANT=2 assert_exit 0 run_suite barrier
assert_eq "$barrier_pass" "$DS_STDOUT" "the results of a default run"
assert_eq 2 "$(most_together)" "files running together by default on a machine with 2 CPUs"

# The output does not depend on the order the files finish in: the first
# files take longest, a failing file prints its output under its FAIL line,
# and the summary and exit status are those of a run file after file.
mkdir -p "$fw/tests/order"
printf 'sleep 1.5\necho "slow one"\n' >"$fw/tests/order/test-1.sh"
printf 'sleep 1\necho "before the failure"\nassert_eq 1 2 "numbers differ"\n' >"$fw/tests/order/test-2.sh"
printf 'sleep 0.5\n' >"$fw/tests/order/test-3.sh"
printf 'echo "fails at once"\nfalse\n' >"$fw/tests/order/test-4.sh"
printf 'assert_eq 1 1\n' >"$fw/tests/order/test-5.sh"
assert_exit 1 run_suite order --jobs 1
serial=$DS_STDOUT
assert_eq "PASS tests/order/test-1.sh
FAIL tests/order/test-2.sh: assertion failed: numbers differ: expected [1], got [2]
PASS tests/order/test-3.sh
FAIL tests/order/test-4.sh: error: command failed (exit 1) at $fw/tests/order/test-4.sh:2: false
PASS tests/order/test-5.sh
3 passed, 2 failed" "$(grep -v '^    ' <<<"$serial")" "the results of the order suite"
assert_contains "$serial" "numbers differ: expected [1], got [2]
    before the failure"
for jobs in 2 5 9; do
  assert_exit 1 run_suite order --jobs "$jobs"
  assert_eq "$serial" "$DS_STDOUT" "the output of --jobs $jobs against --jobs 1"
done
assert_exit 0 run_suite order --jobs 4 --only 'test-[135]'
assert_eq "PASS tests/order/test-1.sh
PASS tests/order/test-3.sh
PASS tests/order/test-5.sh
3 passed, 0 failed" "$DS_STDOUT"

# A file of a parallel run gets the signal dispositions of a run file after
# file: it can trap SIGINT.
mkdir -p "$fw/tests/signals"
for name in a b; do
  cat >"$fw/tests/signals/test-$name.sh" <<'EOF'
status=0
bash -c 'trap "exit 7" INT; kill -INT $$; sleep 5' || status=$?
assert_eq 7 "$status" "the exit status of a shell that traps SIGINT"
EOF
done
for jobs in 1 2; do
  assert_exit 0 run_suite signals --jobs "$jobs"
  assert_eq "PASS tests/signals/test-a.sh
PASS tests/signals/test-b.sh
2 passed, 0 failed" "$DS_STDOUT" "SIGINT in a run with $jobs jobs"
done

# The per-file timeout applies to every file of a parallel run.
mkdir -p "$fw/tests/hang"
printf 'sleep 30\n' >"$fw/tests/hang/test-hang.sh"
printf 'assert_eq 1 1\n' >"$fw/tests/hang/test-quick.sh"
DS_TEST_TIMEOUT=1 assert_exit 1 run_suite hang --jobs 2
assert_eq "FAIL tests/hang/test-hang.sh: timed out after 1s
PASS tests/hang/test-quick.sh
1 passed, 1 failed" "$(grep -v '^    ' <<<"$DS_STDOUT")"

# Usage errors.
for value in 0 -1 two 1.5 ""; do
  assert_exit 1 run_suite order --jobs "$value"
  assert_contains "$DS_STDERR" "run.sh: --jobs must be a positive integer"
done
assert_exit 1 run_suite order --jobs
assert_contains "$DS_STDERR" "run.sh: --jobs requires a number"
DS_TEST_JOBS=many assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/order"
assert_contains "$DS_STDERR" "run.sh: DS_TEST_JOBS must be a positive integer"
assert_exit 0 bash "$fw/tests/run.sh" --help
assert_contains "$DS_STDOUT" "Usage: tests/run.sh [PATH...] [--only PATTERN] [--jobs N]"

# An interrupted parallel run stops the files still running and reaps them:
# each file records its process and that of a child it starts, and none of
# them outlives the runner, which exits with the status of the signal.
mkdir -p "$fw/tests/interrupt"
for name in a b; do
  cat >"$fw/tests/interrupt/test-$name.sh" <<'EOF'
sleep 300 &
ds_defer _ds_stop_process "$!"
printf '%s %s\n' "$$" "$!" >"$PARALLEL_PROBE/pids.$(basename "$DS_TEST_FILE" .sh)"
wait
EOF
done
reset_probe
env -u DS_TEST_JOBS bash "$fw/tests/run.sh" "$fw/tests/interrupt" --jobs 2 >"$DS_TEST_ROOT/interrupt.out" 2>&1 &
runner=$!
ds_defer _ds_stop_process "$runner"
for _ in $(seq 600); do
  [[ -s $probe/pids.test-a && -s $probe/pids.test-b ]] && break
  sleep 0.05
done
[[ -s $probe/pids.test-a && -s $probe/pids.test-b ]] ||
  ds_fail "the interrupt suite did not start: $(<"$DS_TEST_ROOT/interrupt.out")"
kill -TERM "$runner"
status=0
wait "$runner" || status=$?
assert_eq 143 "$status" "the exit status of an interrupted run"

# alive PID: the process runs (a zombie, waiting for its parent, does not).
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [[ ! -r /proc/$1/status ]] || ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"
}
started=()
for name in a b; do
  read -r shell child <"$probe/pids.test-$name"
  started+=("$shell" "$child")
done
assert_eq 4 "${#started[@]}" "processes recorded by the interrupt suite"
for pid in "${started[@]}"; do
  for _ in $(seq 200); do
    alive "$pid" || break
    sleep 0.05
  done
  ! alive "$pid" || ds_fail "process $pid of an interrupted run is still running"
done
assert_eq "" "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-run.*')" "run directories left behind"
