#!/usr/bin/env bash
# Runs dotsteward test files.
#
# Usage: tests/run.sh [PATH...] [--only PATTERN] [--jobs N]
#
# Discovers files named test-*.sh recursively under each PATH (a directory or
# a single test file). Without PATH it searches tests/ and skips tests/vm,
# tests/ci, tests/host and tests/channels, which run only when named
# explicitly. Directories named "fixtures" hold data and are never searched.
# --only keeps the files whose repository-relative path matches the shell
# glob *PATTERN*.
#
# Each file runs in a fresh bash process with tests/lib/harness.sh and
# tests/lib/assert.sh loaded (see harness.sh for the environment). Up to N
# files run at once: --jobs N, else DS_TEST_JOBS, else the number of CPUs;
# 1 runs them one after another. Whatever N, the runner prints, in file
# order, "PASS <file>" or "FAIL <file>: <message>" followed by the indented
# test output, then a summary, and exits 1 when any test failed or no test
# was found. DS_TEST_TIMEOUT (seconds, default 900) bounds each test file.
set -Eeuo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(dirname "$tests_dir")
timeout_seconds=${DS_TEST_TIMEOUT:-900}

usage() {
  sed -n '3,19s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

die() {
  printf 'run.sh: %s\n' "$*" >&2
  exit 1
}

# The number of CPUs of this machine, 1 when it cannot be read.
cpu_count() {
  local count
  count=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)
  [[ $count =~ ^[1-9][0-9]*$ ]] || count=1
  printf '%s' "$count"
}

only=""
jobs=""
jobs_given=0
paths=()
while (($#)); do
  case $1 in
    --only)
      (($# >= 2)) || die "--only requires a pattern"
      only=$2
      shift 2
      ;;
    --only=*)
      only=${1#--only=}
      shift
      ;;
    --jobs)
      (($# >= 2)) || die "--jobs requires a number"
      jobs=$2
      jobs_given=1
      shift 2
      ;;
    --jobs=*)
      jobs=${1#--jobs=}
      jobs_given=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      paths+=("$@")
      break
      ;;
    -*) die "unknown option: $1" ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || die "DS_TEST_TIMEOUT must be a positive integer"
if ((jobs_given)); then
  [[ $jobs =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
elif [[ -n ${DS_TEST_JOBS:-} ]]; then
  jobs=$DS_TEST_JOBS
  [[ $jobs =~ ^[1-9][0-9]*$ ]] || die "DS_TEST_JOBS must be a positive integer"
else
  jobs=$(cpu_count)
fi

# find(1) arguments that prune excluded directories under ROOT.
prune_args() {
  local root=$1 default_mode=$2
  printf '%s\0' '(' -type d -name fixtures
  if [[ $default_mode == 1 ]]; then
    local dir
    for dir in vm ci host channels; do
      printf '%s\0' -o -path "$root/$dir"
    done
  fi
  printf '%s\0' ')' -prune -o -type f -name 'test-*.sh' -print0
}

discover() {
  local path=$1 default_mode=$2 absolute
  if [[ -f $path ]]; then
    absolute=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
    printf '%s\0' "$absolute"
  elif [[ -d $path ]]; then
    absolute=$(cd "$path" && pwd -P)
    local args=()
    mapfile -d '' args < <(prune_args "$absolute" "$default_mode")
    find "$absolute" "${args[@]}"
  fi
}

found=()
if ((${#paths[@]})); then
  for path in "${paths[@]}"; do
    [[ -f $path || -d $path ]] || die "no such test path: $path"
    mapfile -d '' -O "${#found[@]}" found < <(discover "$path" 0)
  done
else
  mapfile -d '' found < <(discover "$tests_dir" 1)
fi

files=()
if ((${#found[@]})); then
  mapfile -d '' files < <(printf '%s\0' "${found[@]}" | LC_ALL=C sort -z -u)
fi

display_name() {
  if [[ $1 == "$repo_root"/* ]]; then
    printf '%s' "${1#"$repo_root"/}"
  else
    printf '%s' "$1"
  fi
}

selected=()
for file in "${files[@]}"; do
  # Unquoted on purpose: PATTERN is a shell glob.
  # shellcheck disable=SC2053 # glob match against the user's pattern
  if [[ -z $only || $(display_name "$file") == *$only* ]]; then
    selected+=("$file")
  fi
done
((${#selected[@]})) || die "no tests found"
((jobs <= ${#selected[@]})) || jobs=${#selected[@]}

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-run.XXXXXX")
trap 'rm -rf -- "$run_dir"' EXIT

timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout --kill-after=10 "$timeout_seconds")
fi

# shellcheck disable=SC2016 # the script is expanded by the child bash
runner_script='source "$1"; source "$2"; ds_harness_init "$3"; source "$3"'

# test_command INDEX: sets test_cmd to the command line that runs the
# selected file INDEX in a fresh bash process.
test_command() {
  test_cmd=("${timeout_cmd[@]}" bash --noprofile --norc -c "$runner_script" bash
    "$tests_dir/lib/harness.sh" "$tests_dir/lib/assert.sh" "${selected[$1]}")
}

passed=0
failed=0

# report INDEX STATUS: prints the result of the selected file INDEX, which
# exited with STATUS and wrote its output to run_dir/INDEX.log.
report() {
  local index=$1 status=$2 name message log=$run_dir/$1.log
  name=$(display_name "${selected[index]}")
  if ((status == 0)); then
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
  else
    failed=$((failed + 1))
    if ((status == 124 || status == 137)) && ((${#timeout_cmd[@]})); then
      message="timed out after ${timeout_seconds}s"
    else
      message=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1 || true)
      [[ -n $message ]] || message="exit $status"
    fi
    printf 'FAIL %s: %s\n' "$name" "$message"
    sed 's/^/    /' "$log"
  fi
  rm -f -- "$log"
}

# Several files at once need `wait -n -p` (bash 5.1).
if ((jobs > 1 && (BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1)))); then
  printf 'run.sh: running one file at a time: --jobs needs bash 5.1 or newer (found %s)\n' "$BASH_VERSION" >&2
  jobs=1
fi

if ((jobs == 1)); then
  # One file after another, each in the foreground.
  for index in "${!selected[@]}"; do
    test_command "$index"
    status=0
    "${test_cmd[@]}" </dev/null >"$run_dir/$index.log" 2>&1 || status=$?
    report "$index" "$status"
  done
else
  # Up to $jobs files run as background jobs of this shell; each result
  # prints, in file order, once every earlier file has finished. Job control
  # gives each job the signal dispositions of a foreground run (without it
  # a background job starts with SIGINT ignored). An interrupted run stops
  # the test processes still running (each test's own EXIT trap cleans up
  # after it) and waits for them before the run directory goes.
  set -m
  stop_jobs() {
    local pids
    pids=$(jobs -p) || true
    if [[ -n $pids ]]; then
      # shellcheck disable=SC2086 # one PID per word
      kill -TERM $pids 2>/dev/null || true
    fi
    wait || true
  }
  trap 'stop_jobs; rm -rf -- "$run_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  declare -A index_of=()
  results=()
  total=${#selected[@]}
  next=0
  printed=0
  running=0
  while ((printed < total)); do
    while ((running < jobs && next < total)); do
      test_command "$next"
      "${test_cmd[@]}" </dev/null >"$run_dir/$next.log" 2>&1 &
      index_of[$!]=$next
      next=$((next + 1))
      running=$((running + 1))
    done
    while ((printed < total)) && [[ -n ${results[printed]:-} ]]; do
      report "$printed" "${results[printed]}"
      printed=$((printed + 1))
    done
    ((printed < total)) || break
    finished=""
    status=0
    wait -n -p finished || status=$?
    [[ -n ${finished:-} ]] || die "lost track of the running tests (wait exit $status)"
    index=${index_of[$finished]}
    results[index]=$status
    running=$((running - 1))
  done
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
