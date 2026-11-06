# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # hook bodies are single-quoted on purpose
# Parallel E2E hooks: a checks.e2e hook declared with parallel: true runs
# at the same time as the parallel hooks next to it in its phase, at most
# --jobs N at a time (else DOTSTEWARD_E2E_JOBS, else 3); any other hook runs
# alone, after every hook before it and before every hook after it, and the
# phases stay barriers, also where the plan puts main and late hooks next
# to each other (--skip-repo-checks, no login shell). A hook without the
# field (a manifest of an older framework) is not parallel. With --jobs 1
# every hook runs as before. A parallel hook runs in a session of its own
# with standard input from /dev/null, and its output is reported in plan
# order, so standard output and standard error (apart, together and with
# --json) are those of the run with --jobs 1.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

probe=$DS_TEST_ROOT/probe

# probe_reset: an empty timeline and no hook running.
probe_reset() {
  rm -rf -- "$probe"
  mkdir -p "$probe"
  printf '0\n' >"$probe/running"
  printf '0\n' >"$probe/max"
  : >"$probe/timeline"
}

# probe_hook NAME: a hook body that logs "start NAME" and "end NAME" in the
# timeline and counts the hooks running at the same time (the highest count
# goes to max). Before it ends it waits, at most 20 seconds (a loaded
# machine starts processes slowly), until that count has reached
# E2E_PROBE_TARGET (default 1), so hooks that are allowed to run together
# are seen together; no passing run waits that long.
probe_hook() {
  printf 'name=%q\nprobe=%q\n' "$1" "$probe"
  cat <<'SH'
target=${E2E_PROBE_TARGET:-1}
lock() { until mkdir "$probe/lock" 2>/dev/null; do [[ -d $probe ]] || exit 1; sleep 0.01; done; }
unlock() { rmdir "$probe/lock"; }
lock
running=$(($(<"$probe/running") + 1))
printf '%s\n' "$running" >"$probe/running"
((running <= $(<"$probe/max"))) || printf '%s\n' "$running" >"$probe/max"
printf 'start %s\n' "$name" >>"$probe/timeline"
unlock
for _ in $(seq 1 1000); do
  lock
  max=$(<"$probe/max")
  unlock
  ((max < target)) || break
  sleep 0.02
done
lock
printf '%s\n' "$(($(<"$probe/running") - 1))" >"$probe/running"
printf 'end %s\n' "$name" >>"$probe/timeline"
unlock
SH
}

# at EVENT NAME: the line number of "EVENT NAME" in the timeline.
at() {
  local line
  line=$(grep -n -x -F -- "$1 $2" "$probe/timeline" | cut -d: -f1)
  [[ -n $line ]] || ds_fail "no '$1 $2' in the timeline: $(<"$probe/timeline")"
  printf '%s\n' "$line"
}

# assert_before A B: hook A ended before hook B started.
assert_before() {
  local end start
  end=$(at end "$1")
  start=$(at start "$2")
  ((end < start)) || ds_fail "$1 did not end before $2 started: $(<"$probe/timeline")"
}

# reset_hooks: no E2E hook; the hooks below replace the previous ones.
reset_hooks() {
  manifest_edit '.checks.e2e = []'
}

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component gamma external "$none"
publish_instance

# --- The bound -----------------------------------------------------------------

# Six parallel hooks in one phase: three at a time by default, as many as
# --jobs or DOTSTEWARD_E2E_JOBS allow (the flag wins), one with --jobs 1.
for name in p1 p2; do
  probe_hook "term-$name" | add_e2e_hook example-term "term-$name" main null true
  probe_hook "app-$name" | add_e2e_hook example-app "app-$name" main null true
  probe_hook "gamma-$name" | add_e2e_hook gamma "gamma-$name" main null true
done
order='term-p1 term-p2 app-p1 app-p2 gamma-p1 gamma-p2'

probe_reset
E2E_PROBE_TARGET=3 assert_exit 0 run_e2e --skip-repo-checks
assert_eq 3 "$(<"$probe/max")" "three hooks at a time by default"
assert_eq 6 "$(grep -c '^end ' "$probe/timeline")" "every hook ran"
probe_reset
E2E_PROBE_TARGET=2 assert_exit 0 run_e2e --skip-repo-checks --jobs=2
assert_eq 2 "$(<"$probe/max")" "--jobs=2"
probe_reset
E2E_PROBE_TARGET=4 assert_exit 0 run_e2e --skip-repo-checks --jobs 4
assert_eq 4 "$(<"$probe/max")" "--jobs 4"
probe_reset
E2E_PROBE_TARGET=2 assert_exit 0 env DOTSTEWARD_E2E_JOBS=2 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation --skip-repo-checks </dev/null
assert_eq 2 "$(<"$probe/max")" "DOTSTEWARD_E2E_JOBS=2"
probe_reset
E2E_PROBE_TARGET=2 assert_exit 0 env DOTSTEWARD_E2E_JOBS=4 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation --skip-repo-checks --jobs 2 </dev/null
assert_eq 2 "$(<"$probe/max")" "--jobs wins over DOTSTEWARD_E2E_JOBS"

# --jobs 1 starts the hooks one after another in plan order.
probe_reset
assert_exit 0 run_e2e --skip-repo-checks --jobs 1
assert_eq 1 "$(<"$probe/max")" "--jobs 1"
previous=''
for name in $order; do
  [[ -z $previous ]] || assert_before "$previous" "$name"
  previous=$name
done

# Not declared parallel (parallel: false, or no field in the manifest of an
# older framework): one at a time whatever --jobs allows.
manifest_edit '.checks.e2e |= map(if .component == "example-app" then del(.parallel) else .parallel = false end)'
probe_reset
E2E_PROBE_TARGET=1 assert_exit 0 run_e2e --skip-repo-checks --jobs 4
assert_eq 1 "$(<"$probe/max")" "hooks that are not parallel"

# --- Phases and hooks that are not parallel ---------------------------------------------

# Parallel hooks stop at a hook that is not parallel and at the end of their
# phase. Without the repository checks and a login shell, the plan holds the
# main hooks and then the late hooks.
reset_hooks
probe_hook term-early | add_e2e_hook example-term term-early early null true
probe_hook app-early | add_e2e_hook example-app app-early early null true
probe_hook term-m1 | add_e2e_hook example-term term-m1 main null true
probe_hook term-m2 | add_e2e_hook example-term term-m2 main null true
probe_hook term-serial | add_e2e_hook example-term term-serial main
probe_hook app-m3 | add_e2e_hook example-app app-m3 main null true
probe_hook app-serial | add_e2e_hook example-app app-serial main null false
probe_hook app-serial-2 | add_e2e_hook example-app app-serial-2 main
probe_hook gamma-m4 | add_e2e_hook gamma gamma-m4 main null true
probe_hook gamma-m5 | add_e2e_hook gamma gamma-m5 main null true
probe_hook term-late | add_e2e_hook example-term term-late late null true
probe_hook gamma-late | add_e2e_hook gamma gamma-late late null true
assert_exit 0 run_e2e --list --skip-repo-checks
assert_eq "example-term:term-early
example-app:app-early
core:agents
example-term:term-m1
example-term:term-m2
example-term:term-serial
example-app:app-m3
example-app:app-serial
example-app:app-serial-2
gamma:gamma-m4
gamma:gamma-m5
example-term:term-late
gamma:gamma-late
core:framework-skills" "$DS_STDOUT" "the late hooks follow the main hooks in the plan"
for jobs in 3 1; do
  probe_reset
  E2E_PROBE_TARGET=$((jobs > 1 ? 2 : 1)) assert_exit 0 run_e2e --skip-repo-checks --jobs "$jobs"
  for early in term-early app-early; do
    for main in term-m1 term-m2 term-serial app-m3 app-serial app-serial-2 gamma-m4 gamma-m5; do
      assert_before "$early" "$main"
    done
  done
  for main in term-m1 term-m2 term-serial app-m3 app-serial app-serial-2 gamma-m4 gamma-m5; do
    for late in term-late gamma-late; do
      assert_before "$main" "$late"
    done
  done
  for before in term-m1 term-m2; do
    assert_before "$before" term-serial
  done
  assert_before term-serial app-m3
  assert_before app-m3 app-serial
  assert_before app-serial app-serial-2
  for after in gamma-m4 gamma-m5; do
    assert_before app-serial-2 "$after"
  done
  assert_eq "$((jobs > 1 ? 2 : 1))" "$(<"$probe/max")" "--jobs $jobs: the parallel hooks next to each other run together"
done


# --- Output order ------------------------------------------------------------------------

# talk_hook NAME DELAY: two lines on standard output and two on standard
# error, alternating, DELAY seconds apart.
talk_hook() {
  printf 'name=%q\ndelay=%q\n' "$1" "$2"
  cat <<'SH'
printf '%s: out 1\n' "$name"
printf '%s: err 1\n' "$name" >&2
sleep "$delay"
printf '%s: out 2\n' "$name"
printf '%s: err 2\n' "$name" >&2
SH
}

# The first hook is the slowest: the others finish before it, and their
# output still follows its own.
reset_hooks
talk_hook term-t1 1 | add_e2e_hook example-term term-t1 main null true
talk_hook term-t2 0.3 | add_e2e_hook example-term term-t2 main null true
talk_hook app-t3 0.1 | add_e2e_hook example-app app-t3 main
talk_hook app-t4 0.4 | add_e2e_hook example-app app-t4 main null true
talk_hook gamma-t5 0.1 | add_e2e_hook gamma gamma-t5 main null true
talk_hook gamma-t6 0 | add_e2e_hook gamma gamma-t6 late null true
names='term-t1 term-t2 app-t3 app-t4 gamma-t5 gamma-t6'
expected_stdout=''
expected_stderr=''
for name in $names; do
  expected_stdout+="$name: out 1"$'\n'"$name: out 2"$'\n'
  expected_stderr+="$name: err 1"$'\n'"$name: err 2"$'\n'
done

assert_exit 0 run_e2e --skip-repo-checks --jobs 1
plain_stdout=$DS_STDOUT
plain_stderr=$DS_STDERR
assert_eq "${expected_stdout}[dotsteward] e2e checks passed (profile workstation)" "$plain_stdout"
assert_eq "${expected_stderr%$'\n'}" "$(grep -E '^[a-z]+-t[0-9]: ' <<<"$plain_stderr")"
assert_exit 0 run_e2e --skip-repo-checks
assert_eq "$plain_stdout" "$DS_STDOUT" "standard output of the parallel run"
assert_eq "$plain_stderr" "$DS_STDERR" "standard error of the parallel run"

# One stream for both (2>&1): every hook's lines in the order it wrote them.
together() {
  local file=$1
  shift
  run_e2e --skip-repo-checks "$@" >"$file" 2>&1
}
assert_exit 0 together "$DS_TEST_ROOT/serial.log" --jobs 1
assert_exit 0 together "$DS_TEST_ROOT/parallel.log"
assert_eq "$(<"$DS_TEST_ROOT/serial.log")" "$(<"$DS_TEST_ROOT/parallel.log")" "one stream for both"
assert_eq $'term-t1: out 1\nterm-t1: err 1\nterm-t1: out 2\nterm-t1: err 2\nterm-t2: out 1' \
  "$(grep -E '^[a-z]+-t[0-9]: ' "$DS_TEST_ROOT/parallel.log" | head -n 5)"

# --json: the logs go to standard error, the document is the same.
assert_exit 0 run_e2e --skip-repo-checks --json --jobs 1
json_stdout=$DS_STDOUT
json_stderr=$DS_STDERR
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$json_stdout")"
assert_exit 0 run_e2e --skip-repo-checks --json
assert_eq "$json_stdout" "$DS_STDOUT" "the --json document of the parallel run"
assert_eq "$json_stderr" "$DS_STDERR" "standard error of the parallel --json run"

# --jobs 1 runs as a manifest without parallel hooks does.
manifest_edit '.checks.e2e |= map(del(.parallel))'
assert_exit 0 run_e2e --skip-repo-checks
assert_eq "$plain_stdout" "$DS_STDOUT" "standard output without parallel hooks"
assert_eq "$plain_stderr" "$DS_STDERR" "standard error without parallel hooks"
assert_exit 0 run_e2e --skip-repo-checks --json
assert_eq "$json_stdout" "$DS_STDOUT" "the --json document without parallel hooks"
assert_eq "$json_stderr" "$DS_STDERR" "standard error of --json without parallel hooks"

# --- The hook's surroundings ----------------------------------------------------------

# whereabouts_hook NAME: records whether the hook runs in the session of
# the test (E2E_TEST_SESSION) or in another one, and the first line it
# reads on standard input.
whereabouts_hook() {
  printf 'name=%q\nprobe=%q\n' "$1" "$probe"
  cat <<'SH'
read -r line || line='(end of input)'
session=$(python3 -c 'import os, sys
print("test-session" if os.getsid(0) == int(sys.argv[1]) else "own-session")' "$E2E_TEST_SESSION")
printf '%s %s %s\n' "$name" "$session" "$line" >>"$probe/whereabouts"
SH
}
E2E_TEST_SESSION=$(python3 -c 'import os; print(os.getsid(0))')
export E2E_TEST_SESSION
reset_hooks
whereabouts_hook term-w1 | add_e2e_hook example-term term-w1 main null true
whereabouts_hook app-w2 | add_e2e_hook example-app app-w2 main
printf 'from the caller\n' >"$DS_TEST_ROOT/input"
run_with_input() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation --skip-repo-checks "$@" \
    <"$DS_TEST_ROOT/input"
}
probe_reset
assert_exit 0 run_with_input
assert_eq $'term-w1 own-session (end of input)\napp-w2 test-session from the caller' "$(<"$probe/whereabouts")"
probe_reset
assert_exit 0 run_with_input --jobs 1
assert_eq $'term-w1 test-session from the caller\napp-w2 test-session (end of input)' "$(<"$probe/whereabouts")"
assert_eq "" "$(temp_dirs)" "no temporary directory is left behind"
