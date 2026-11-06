# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The apt engine runs under the system's python with python3-apt. On a machine without
# them the plan does not fall over: the report names the missing piece and the command
# that brings it. tests/apt-worlds has the engine itself, on a real apt.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

work=$DS_TEST_ROOT/apt
mkdir -p "$work"
review=$DOTSTEWARD_STATE_ROOT/review.json

# No such interpreter: without a report an error, with one a decision for a person.
export DOTSTEWARD_APT_PYTHON=$work/no-such-python
status=0
core_python -m dotsteward_cli.apt_plan plan >"$work/out" 2>"$work/err" || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "python3-apt-missing"

status=0
core_python -m dotsteward_cli.apt_plan plan --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 3 "$status"
assert_json "$review" '.items[] | select(.code == "python3-apt-missing") | .run == "sudo apt-get install python3-apt"'

# A system python without the binding: the same answer, from the helper itself.
# python3 -S has no site packages, whatever the machine has installed.
printf '#!/bin/sh\nexec python3 -S "$@"\n' >"$work/python-without-apt"
chmod +x "$work/python-without-apt"
export DOTSTEWARD_APT_PYTHON=$work/python-without-apt
status=0
core_python -m dotsteward_cli.apt_plan analysis --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 3 "$status"
assert_contains "$(<"$work/err")" "python3-apt-missing"
assert_json "$review" '[.items[].code] == ["python3-apt-missing"]'

# A helper that dies without an answer is a failure, not a plan with nothing to do.
printf '#!/bin/sh\necho "Traceback" >&2\nexit 9\n' >"$work/python-broken"
chmod +x "$work/python-broken"
export DOTSTEWARD_APT_PYTHON=$work/python-broken
status=0
core_python -m dotsteward_cli.apt_plan plan --report apt-test >"$work/out" 2>"$work/err" || status=$?
assert_eq 1 "$status"
assert_contains "$(<"$work/err")" "Traceback"

# A request that cannot be meant is a usage error before anything starts.
assert_usage() {
  status=0
  core_python -m dotsteward_cli.apt_plan plan --request - <<<"$1" >"$work/out" 2>"$work/err" || status=$?
  assert_eq 2 "$status" "the request $1"
}
assert_usage '{"mode": "everything"}'
assert_usage '{"accept": ["series:kernel"]}'
assert_usage '{"accept": ["series:gpu=1"]}'
assert_usage 'not json'
