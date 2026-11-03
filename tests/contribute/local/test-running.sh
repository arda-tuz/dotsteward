# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The running marker of the long contribute steps and `status --wait`.
# check (like trial, publish, release, upgrade, abort and report, which may
# run the recovery of a trial switch) records
# running = {step, pid, started_at} in the run's state while it works and
# replaces it with last_step = {step, status, started_at, ended_at} when it
# ends: after a pass, a failure, a privacy stop, and when SIGTERM or SIGINT
# interrupts it. Meanwhile every step that changes the clone, a run or the
# machine refuses and names the running step; status shows it; status
# --wait blocks until it ends and exits with its status (3 when --timeout
# passes first). A marker whose process is gone, or belongs to another
# program, is stale: it is reported, cleared, and counts as an unknown
# outcome (exit 1 of status --wait).
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

setup_owner
write_mirror
start_run add-feature
id=$(current_id)
clone_commit feature.txt feature 'feat: add the feature'
good=$(git -C "$ct_clone" rev-parse HEAD)

field() {
  state_json | jq -r "$1"
}

# The flake check of the nix stub writes its process into the started file
# and blocks until the test writes its exit status into the release file:
# 120 seconds at most, and never after the test root is gone.
release_file=$DS_TEST_ROOT/nix.release
started_file=$DS_TEST_ROOT/nix.started
ds_stub_override nix <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$started_file"
for ((i = 0; i < 1200; i++)); do
  [[ -d "$DS_TEST_ROOT" ]] || exit 1
  [[ ! -e "$release_file" ]] || exit "\$(<"$release_file")"
  sleep 0.1
done
exit 1
EOF

# release STATUS: the blocked flake check exits with STATUS (the file appears
# whole, so the stub never reads it half written).
release() {
  printf '%s\n' "$1" >"$release_file.new"
  mv -f -- "$release_file.new" "$release_file"
}

# alive PID: PID runs and is not a zombie waiting to be reaped.
alive() {
  local stat
  kill -0 "$1" 2>/dev/null || return 1
  [[ -r /proc/$1/stat ]] || return 0
  stat=$(<"/proc/$1/stat")
  stat=${stat##*) }
  [[ ${stat%% *} != Z ]]
}

# stop_stub: kills a stub that still blocks (its check was killed).
stop_stub() {
  local stub
  stub=$(cat "$started_file" 2>/dev/null || true)
  if [[ $stub =~ ^[0-9]+$ ]] && alive "$stub"; then
    kill -KILL "$stub" 2>/dev/null || true
  fi
}

bg=""
# stop_background: on every exit path of the test, ends a check still
# running in the background: releases and kills its stub, gives the check
# 10 seconds to end, kills it otherwise, and reaps it, so that no process
# outlives the test root.
stop_background() {
  local i
  release 0
  stop_stub
  [[ -n $bg ]] || return 0
  for ((i = 0; i < 100; i++)); do
    alive "$bg" || break
    sleep 0.1
  done
  ! alive "$bg" || kill -KILL "$bg" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true
  bg=""
}
ds_defer stop_background

# wait_for FILE: FILE exists and is not empty within 30 seconds.
wait_for() {
  local i
  for ((i = 0; i < 300; i++)); do
    [[ -s $1 ]] && return 0
    sleep 0.1
  done
  ds_fail "timed out waiting for $1"
}

# start_check: `contribute check` in the background (with SIGINT at its
# default, which a background job of a script would ignore), once its flake
# check is blocked; bg is its process.
start_check() {
  rm -f -- "$release_file" "$started_file"
  env --default-signal=INT "$DS_REPO_ROOT/cli/dotsteward" --instance "$ct_inst" contribute check \
    </dev/null >"$DS_TEST_ROOT/bg.out" 2>"$DS_TEST_ROOT/bg.err" &
  bg=$!
  wait_for "$started_file"
}

# finish_check STATUS: the blocked flake check exits with STATUS; bg_status is
# the exit status of the background check (wait runs in this shell, the
# parent of the job).
finish_check() {
  release "$1"
  bg_status=0
  wait "$bg" || bg_status=$?
  bg=""
}

utc_time='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# --- a running check ----------------------------------------------------------

start_check
state_json | assert_json - '(.running | keys) == ["pid", "started_at", "step"] and .running.step == "check"'
state_json | assert_json - 'has("last_step") | not'
pid=$(field .running.pid)
started=$(field .running.started_at)
assert_eq "$bg" "$pid" "the marker names the process of the step"
[[ $started =~ $utc_time ]] || ds_fail "started_at is not a UTC time: $started"

# status shows the running step; --json is still the state document.
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "[dotsteward] check running since $started (pid $pid)"
assert_exit 0 run_contribute status --json
assert_json - ".running.pid == $pid and .running.started_at == \"$started\"" <<<"$DS_STDOUT"
# mode only reads: it runs.
assert_exit 0 run_contribute mode

# Every step that changes the clone, a run or the machine refuses.
busy="[dotsteward] ERROR: check is running for run $id since $started (pid $pid); wait for it with: dotsteward contribute status --wait"
for args in check "check --expect-fail tests/example/test-feature.sh" trial publish release upgrade abort \
  report setup "start --slug other-fix" "start --slug add-feature"; do
  # shellcheck disable=SC2086 # the step and its arguments, split on purpose
  assert_exit 1 run_contribute $args
  assert_contains "$DS_STDERR" "$busy" "contribute $args while check runs"
done
printf 'notes\n' >"$ct_clone/notes.md"
assert_exit 1 run_contribute commit -m 'docs(example): notes'
assert_contains "$DS_STDERR" "$busy" "contribute commit while check runs"
rm -f "$ct_clone/notes.md"
assert_eq "$pid" "$(field .running.pid)" "the marker after the refusals"
state_json | assert_json - 'has("last_step") | not'
assert_eq 1 "$(find "$ct_runs" -name '*.json' | wc -l)" "runs after the refusals"
assert_eq fix/add-feature "$(git -C "$ct_clone" symbolic-ref --short HEAD)" "branch after the refusals"

# --wait with a timeout gives up while the step runs: exit 3.
assert_exit 3 run_contribute status --wait --timeout 1
assert_contains "$DS_STDOUT" "[dotsteward] check running since $started (pid $pid)"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: check is still running after 1 s; wait again with: dotsteward contribute status --wait"

# --- the end of the step ------------------------------------------------------

# The step passes: the marker becomes last_step, and --wait exits 0.
release 0
assert_exit 0 run_contribute status --wait --timeout 60
assert_contains "$DS_STDOUT" "  last_step: check exited 0 (started $started, ended "
assert_not_contains "$DS_STDOUT" "running since"
finish_check 0
assert_eq 0 "$bg_status" "exit status of the check"
assert_contains "$(<"$DS_TEST_ROOT/bg.out")" "[dotsteward] contribute check passed: ${good:0:12}"
state_json | assert_json - '(has("running") | not) and .last_step.step == "check" and .last_step.status == 0'
state_json | assert_json - "(.last_step | keys) == [\"ended_at\", \"started_at\", \"status\", \"step\"] and .last_step.started_at == \"$started\""
[[ $(field .last_step.ended_at) =~ $utc_time ]] || ds_fail "ended_at is not a UTC time: $(field .last_step.ended_at)"
# The check removed its private terms directory on the way out.
assert_eq "" "$(temp_leftovers)" "temporary files after the check"
# Without a running step --wait answers at once, with the last outcome.
assert_exit 0 run_contribute status --wait

# A red flake check: exit 1, for the step and for --wait.
start_check
release 1
assert_exit 1 run_contribute status --wait --timeout 60
assert_contains "$DS_STDOUT" "  last_step: check exited 1"
finish_check 1
assert_eq 1 "$bg_status" "exit status of a red check"
state_json | assert_json - '(has("running") | not) and .last_step.status == 1 and .test_sha == null'

# A privacy stop: exit 4, reflected by --wait.
clone_commit notes.md 'the synthetic-private-term appears here' 'docs: add notes'
assert_exit 4 run_contribute check
assert_exit 4 run_contribute status --wait
state_json | assert_json - '(has("running") | not) and .last_step.status == 4'
git -C "$ct_clone" reset -q --hard "$good"

# --- signals ------------------------------------------------------------------

# SIGTERM and SIGINT end the step through its cleanup once its current
# command returns: the marker becomes last_step with the signal's status,
# which --wait reports as a failure.
for signal in TERM INT; do
  start_check
  pid=$(field .running.pid)
  kill -s "$signal" "$pid"
  case $signal in
    TERM) expected=143 ;;
    INT) expected=130 ;;
  esac
  finish_check 0
  assert_eq "$expected" "$bg_status" "exit status after SIG$signal"
  state_json | assert_json - "(has(\"running\") | not) and .last_step.step == \"check\" and .last_step.status == $expected"
  assert_exit 1 run_contribute status --wait
  assert_contains "$DS_STDOUT" "  last_step: check exited $expected"
  assert_eq "" "$(temp_leftovers)" "temporary files after SIG$signal"
done

# --- stale markers ------------------------------------------------------------

# A step killed outright leaves its marker behind.
start_check
pid=$(field .running.pid)
started=$(field .running.started_at)
kill -s KILL "$pid"
finish_check 0
assert_eq 137 "$bg_status" "exit status after SIGKILL"
# Its orphaned stub ends with the release; make sure it is gone.
stop_stub
assert_eq "$pid" "$(field .running.pid)" "the marker of the killed step"
stale="[dotsteward] WARNING: the check of run $id (pid $pid, since $started) ended without clearing its running marker; the marker is cleared and the outcome of that check is unknown"
assert_exit 0 run_contribute status
assert_contains "$DS_STDERR" "$stale"
assert_not_contains "$DS_STDOUT" "running since"
assert_contains "$DS_STDOUT" "  last_step: check ended without recording its outcome (started $started)"
state_json | assert_json - "(has(\"running\") | not) and .last_step == {step: \"check\", status: null, started_at: \"$started\", ended_at: null}"
# An unknown outcome is a failure for --wait.
assert_exit 1 run_contribute status --wait
assert_eq "" "$DS_STDERR" "the stale marker is reported once"

# A marker whose process number now belongs to another program is stale.
# The stand-in program is ended and reaped right after (by the deferred
# stop_other when an assertion fails first).
sleep 60 &
other=$!
stop_other() {
  [[ -n $other ]] || return 0
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  other=""
}
ds_defer stop_other
jq --argjson pid "$other" '.running = {step: "trial", pid: $pid, started_at: "2026-01-01T00:00:00Z"}' \
  "$ct_runs/$id.json" >"$DS_TEST_ROOT/state.json"
cp "$DS_TEST_ROOT/state.json" "$ct_runs/$id.json"
assert_exit 0 run_contribute status
assert_contains "$DS_STDERR" "[dotsteward] WARNING: the trial of run $id (pid $other, since 2026-01-01T00:00:00Z) ended without clearing its running marker"
state_json | assert_json - '(has("running") | not) and .last_step.step == "trial" and .last_step.status == null'
stop_other

# A step clears a stale marker it finds, then runs.
jq '.running = {step: "publish", pid: 999999999, started_at: "2026-01-01T00:00:00Z"}' \
  "$ct_runs/$id.json" >"$DS_TEST_ROOT/state.json"
cp "$DS_TEST_ROOT/state.json" "$ct_runs/$id.json"
release 0
assert_exit 0 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] WARNING: the publish of run $id (pid 999999999, since 2026-01-01T00:00:00Z) ended without clearing its running marker"
state_json | assert_json - '(has("running") | not) and .last_step.step == "check" and .last_step.status == 0'
assert_eq trial "$(field .step)" "step after the check"

# report is a long step as well (at step release it first runs the recovery
# of a trial switch): it records its marker, and its outcome is last_step.
jq '.step = "report"' "$ct_runs/$id.json" >"$DS_TEST_ROOT/state.json"
cp "$DS_TEST_ROOT/state.json" "$ct_runs/$id.json"
assert_exit 0 run_contribute report
state_json | assert_json - '(has("running") | not) and .step == "done" and .last_step.step == "report" and .last_step.status == 0'
assert_exit 0 run_contribute status --wait --timeout 5
