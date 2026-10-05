#!/usr/bin/env bash
# Runs dotsteward test files.
#
# Usage: tests/run.sh [PATH...] [--only PATTERN]
#
# Discovers files named test-*.sh recursively under each PATH (a directory or
# a single test file). Without PATH it searches tests/ and skips tests/vm,
# tests/ci, tests/host and tests/channels, which run only when named
# explicitly. Directories named "fixtures" hold data and are never searched.
# --only keeps the files whose repository-relative path matches the shell
# glob *PATTERN*.
#
# Each file runs in a fresh bash process with tests/lib/harness.sh and
# tests/lib/assert.sh loaded (see harness.sh for the environment). The runner
# prints "PASS <file>" or "FAIL <file>: <message>" followed by the indented
# test output, then a summary, and exits 1 when any test failed or no test
# was found. DS_TEST_TIMEOUT (seconds, default 900) bounds each test file.
set -Eeuo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(dirname "$tests_dir")
timeout_seconds=${DS_TEST_TIMEOUT:-900}

usage() {
  sed -n '3,17s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

die() {
  printf 'run.sh: %s\n' "$*" >&2
  exit 1
}

only=""
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

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-run.XXXXXX")
trap 'rm -rf -- "$run_dir"' EXIT
log=$run_dir/output

timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout --kill-after=10 "$timeout_seconds")
fi

# shellcheck disable=SC2016 # the script is expanded by the child bash
runner_script='source "$1"; source "$2"; ds_harness_init "$3"; source "$3"'

passed=0
failed=0
for file in "${selected[@]}"; do
  name=$(display_name "$file")
  status=0
  "${timeout_cmd[@]}" bash --noprofile --norc -c "$runner_script" bash \
    "$tests_dir/lib/harness.sh" "$tests_dir/lib/assert.sh" "$file" \
    </dev/null >"$log" 2>&1 || status=$?
  if ((status == 0)); then
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name"
    continue
  fi
  failed=$((failed + 1))
  if ((status == 124 || status == 137)) && ((${#timeout_cmd[@]})); then
    message="timed out after ${timeout_seconds}s"
  else
    message=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1 || true)
    [[ -n $message ]] || message="exit $status"
  fi
  printf 'FAIL %s: %s\n' "$name" "$message"
  sed 's/^/    /' "$log"
done

printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
