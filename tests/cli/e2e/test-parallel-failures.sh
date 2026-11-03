# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # hook bodies are single-quoted on purpose
# Failed parallel E2E hooks end the run as they do with --jobs 1: the same
# exit status, standard output, standard error, --json findings and E2E
# record. Fail-fast: once a hook failed no further hook starts, the report
# of the first failed hook in plan order ends the run, and the hooks still
# running are stopped (SIGTERM to their sessions) and reaped before it
# ends; with --keep-going every hook runs and the findings keep the plan
# order. A run ended by a signal stops and reaps its hooks too, and
# records a failed result.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

marks=$DS_TEST_ROOT/marks
record=$DOTSTEWARD_STATE_ROOT/update/e2e.json
mkdir -p "$marks"

# stop_recorded FILE...: kills the processes whose PIDs the files hold, so a
# failed assertion leaves nothing running.
stop_recorded() {
  local file
  for file in "$@"; do
    if [[ -s $file ]]; then
      kill -KILL "$(<"$file")" 2>/dev/null || true
    fi
  done
}
ds_defer stop_recorded "$marks/inflight.pid" "$marks/inflight-child.pid" "$marks/e2e.pid" \
  "$marks/sleeper-1.pid" "$marks/sleeper-1-child.pid" "$marks/sleeper-2.pid" "$marks/sleeper-2-child.pid"

# gone PIDFILE: the process whose PID the file holds no longer runs.
gone() {
  [[ -s $1 ]] || ds_fail "no PID in $1"
  if kill -0 "$(<"$1")" 2>/dev/null; then
    ds_fail "process $(<"$1") ($1) still runs"
  fi
}

# with_marks: standard input after a line that sets marks.
with_marks() {
  printf 'marks=%q\n' "$marks"
  cat
}

# record_without_time: the E2E record without its time.
record_without_time() {
  jq -c 'del(.recorded_at)' "$record"
}

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
publish_instance

# --- Fail-fast ----------------------------------------------------------------------------

# term-broken fails while term-slow still runs and app-inflight has started;
# app-later comes after them. With E2E_WAIT_FOR_INFLIGHT=1, term-slow ends
# only once app-inflight runs and term-broken has ended, and a second later,
# so the run learns of the failure first (each wait at most 30 seconds).
cat <<'SH' | with_marks | add_e2e_hook example-term term-slow main null true
if [[ ${E2E_WAIT_FOR_INFLIGHT:-} == 1 ]]; then
  for _ in $(seq 1 1500); do
    if [[ -s $marks/inflight-child.pid && -s $marks/broken.pid ]] && ! kill -0 "$(<"$marks/broken.pid")" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  sleep 1
fi
printf 'term-slow: done\n'
SH
cat <<'SH' | with_marks | add_e2e_hook example-term term-broken main null true
printf 'term-broken: the check cannot pass\n' >&2
printf '%s\n' "$$" >"$marks/broken.pid"
exit 7
SH
cat <<'SH' | with_marks | add_e2e_hook example-app app-inflight main null true
trap 'printf "terminated\n" >"$marks/inflight.terminated"; exit 143' TERM
printf '%s\n' "$$" >"$marks/inflight.pid"
sleep 30 &
printf '%s\n' "$!" >"$marks/inflight-child.pid"
wait "$!"
printf 'app-inflight: done\n'
SH
cat <<'SH' | with_marks | add_e2e_hook example-app app-later main null true
printf 'app-later\n' >>"$marks/started"
SH

assert_exit 1 run_e2e --skip-repo-checks --jobs 1
serial_stdout=$DS_STDOUT
serial_stderr=$DS_STDERR
rm -f -- "$marks/broken.pid"
assert_contains "$serial_stdout" "term-slow: done"
assert_contains "$serial_stderr" "term-broken: the check cannot pass
[dotsteward] ERROR: component example-term hook term-broken failed (exit 7)"
[[ ! -e $marks/inflight.pid && ! -e $marks/started ]] || ds_fail "hooks after the failed one ran with --jobs 1"
assert_json "$record" '.result == "failed" and .findings == 1'
serial_record=$(record_without_time)

E2E_WAIT_FOR_INFLIGHT=1 assert_exit 1 run_e2e --skip-repo-checks
assert_eq "$serial_stdout" "$DS_STDOUT" "standard output after a failed parallel hook"
assert_eq "$serial_stderr" "$DS_STDERR" "standard error after a failed parallel hook"
assert_eq "$serial_record" "$(record_without_time)" "the record after a failed parallel hook"
assert_eq terminated "$(cat "$marks/inflight.terminated" 2>/dev/null)" "app-inflight was stopped with SIGTERM"
gone "$marks/inflight.pid"
gone "$marks/inflight-child.pid"
[[ ! -e $marks/started ]] || ds_fail "app-later started after term-broken failed"
assert_eq "" "$(temp_dirs)" "no temporary directory is left behind"

# --json: the same document.
assert_exit 1 run_e2e --skip-repo-checks --json --jobs 1
serial_stdout=$DS_STDOUT
rm -f -- "$marks"/inflight* "$marks/broken.pid"
assert_eq '[["example-term:term-broken","hook-failed","example-term/term-broken"]]' "$(findings)"
assert_json - '.result == "failed" and .findings[0].message == "component example-term hook term-broken failed (exit 7)"' \
  <<<"$serial_stdout"
E2E_WAIT_FOR_INFLIGHT=1 assert_exit 1 run_e2e --skip-repo-checks --json
assert_eq "$serial_stdout" "$DS_STDOUT" "the --json document after a failed parallel hook"
gone "$marks/inflight.pid"
[[ ! -e $marks/started ]] || ds_fail "app-later started after term-broken failed"

# The first hook in plan order fails while the hooks after it run: they
# are stopped, and their output is not reported.
manifest_edit '.checks.e2e |= map(select(.name != "term-slow"))'
rm -f -- "$marks"/inflight*
assert_exit 1 run_e2e --skip-repo-checks --jobs 1
serial_stdout=$DS_STDOUT
serial_stderr=$DS_STDERR
assert_exit 1 run_e2e --skip-repo-checks
assert_eq "$serial_stdout" "$DS_STDOUT"
assert_eq "$serial_stderr" "$DS_STDERR"
assert_not_contains "$DS_STDOUT" "app-inflight: done"
if [[ -s $marks/inflight.pid ]]; then
  gone "$marks/inflight.pid"
fi
if [[ -s $marks/inflight-child.pid ]]; then
  gone "$marks/inflight-child.pid"
fi
assert_eq "" "$(temp_dirs)" "no temporary directory is left behind"

# --- Keep-going ---------------------------------------------------------------------------

# fail_hook NAME STATUS: a line on standard error, then exit STATUS.
fail_hook() {
  printf 'name=%q\nstatus=%q\n' "$1" "$2"
  cat <<'SH'
printf '%s: failing\n' "$name" >&2
exit "$status"
SH
}
manifest_edit '.checks.e2e = []'
fail_hook term-early 2 | add_e2e_hook example-term term-early early null true
printf 'sleep 0.5\nprintf "term-a: ok\\n"\n' | add_e2e_hook example-term term-a main null true
fail_hook term-b 3 | add_e2e_hook example-term term-b main null true
fail_hook term-serial 4 | add_e2e_hook example-term term-serial main
fail_hook app-c 5 | add_e2e_hook example-app app-c main null true
printf 'sleep 0.3\nprintf "app-d: ok\\n"\n' | add_e2e_hook example-app app-d main null true
fail_hook app-late 6 | add_e2e_hook example-app app-late late null true
expected='[["example-term:term-early","hook-failed","example-term/term-early"],
  ["example-term:term-b","hook-failed","example-term/term-b"],
  ["example-term:term-serial","hook-failed","example-term/term-serial"],
  ["example-app:app-c","hook-failed","example-app/app-c"],
  ["example-app:app-late","hook-failed","example-app/app-late"]]'

assert_exit 1 run_e2e --skip-repo-checks --keep-going --json --jobs 1
serial_stdout=$DS_STDOUT
serial_stderr=$DS_STDERR
assert_eq "$(jq -c . <<<"$expected")" "$(findings)"
assert_contains "$serial_stderr" "[dotsteward] ERROR: e2e failed: 5 findings"
assert_json "$record" '.result == "failed" and .findings == 5'
serial_record=$(record_without_time)
assert_exit 1 run_e2e --skip-repo-checks --keep-going --json
assert_eq "$serial_stdout" "$DS_STDOUT" "the --json document with --keep-going"
assert_eq "$serial_stderr" "$DS_STDERR" "standard error with --keep-going"
assert_eq "$serial_record" "$(record_without_time)" "the record with --keep-going"

assert_exit 1 run_e2e --skip-repo-checks --keep-going --jobs 1
serial_stdout=$DS_STDOUT
serial_stderr=$DS_STDERR
assert_exit 1 run_e2e --skip-repo-checks --keep-going
assert_eq "$serial_stdout" "$DS_STDOUT"
assert_eq "$serial_stderr" "$DS_STDERR"

# Repaired, the parallel run passes and records it.
manifest_edit '.checks.e2e |= map(select(.name == "term-a" or .name == "app-d"))'
assert_exit 0 run_e2e --skip-repo-checks
assert_json "$record" '.result == "passed" and .findings == 0'

# --- A run ended by a signal ---------------------------------------------------------------

# sleeper_hook N: records its PID and its child's, then waits; SIGTERM ends
# it with a mark.
sleeper_hook() {
  printf 'marks=%q\nn=%q\n' "$marks" "$1"
  cat <<'SH'
trap 'printf "terminated\n" >"$marks/sleeper-$n.terminated"; exit 143' TERM
printf '%s\n' "$$" >"$marks/sleeper-$n.pid"
sleep 30 &
printf '%s\n' "$!" >"$marks/sleeper-$n-child.pid"
wait "$!"
SH
}
manifest_edit '.checks.e2e = []'
sleeper_hook 1 | add_e2e_hook example-term sleeper-1 main null true
sleeper_hook 2 | add_e2e_hook example-app sleeper-2 main null true
"$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation --skip-repo-checks \
  </dev/null >"$DS_TEST_ROOT/interrupted.log" 2>&1 &
printf '%s\n' "$!" >"$marks/e2e.pid"
for _ in $(seq 1 1500); do
  [[ -s $marks/sleeper-1-child.pid && -s $marks/sleeper-2-child.pid ]] && break
  sleep 0.02
done
[[ -s $marks/sleeper-1-child.pid && -s $marks/sleeper-2-child.pid ]] ||
  ds_fail "the parallel hooks did not start together: $(cat "$DS_TEST_ROOT/interrupted.log")"
kill -TERM "$(<"$marks/e2e.pid")"
status=0
wait "$(<"$marks/e2e.pid")" || status=$?
assert_eq 143 "$status" "the run ends with the signal"
for n in 1 2; do
  assert_eq terminated "$(cat "$marks/sleeper-$n.terminated" 2>/dev/null)" "sleeper-$n was stopped with SIGTERM"
  gone "$marks/sleeper-$n.pid"
  gone "$marks/sleeper-$n-child.pid"
done
assert_json "$record" '.result == "failed"' "an interrupted run is not a passed run"
assert_eq "" "$(temp_dirs)" "no temporary directory is left behind"
