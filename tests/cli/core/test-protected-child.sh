# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # child scripts are single-quoted on purpose
# A child that must not be interrupted half way, such as a package manager
# (dotsteward_cli.procs.run_protected): it runs in a process group of its own,
# so Ctrl-C at the terminal does not reach it, and the parent keeps SIGINT,
# SIGTERM and SIGHUP until the child has ended, then reports them.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

work=$DS_TEST_ROOT/protected
mkdir -p "$work"

# scenario MODE: starts `internal run-protected` (or, with MODE plain, a child
# without protection) as its own process group, as a terminal does, sends the
# group SIGINT and the parent SIGTERM while the child runs, and prints what
# happened.
scenario() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "$1" "$work" <<'PY'
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# A background job of a shell starts with SIGINT ignored, which a child inherits.
signal.signal(signal.SIGINT, signal.SIG_DFL)
mode, work = sys.argv[1], Path(sys.argv[2])
started, finished = work / f"{mode}.started", work / f"{mode}.finished"
script = f': >"{started}"; sleep 1; : >"{finished}"; exit 5'
if mode == "protected":
    argv = [sys.executable, "-s", "-P", "-m", "dotsteward_cli.internal", "run-protected", "--", "bash", "-c", script]
else:
    argv = ["bash", "-c", script]
parent = subprocess.Popen(argv, start_new_session=True, stderr=subprocess.PIPE, text=True)
deadline = time.monotonic() + 30
while not started.exists():
    assert time.monotonic() < deadline, "the child did not start"
    time.sleep(0.01)
os.killpg(parent.pid, signal.SIGINT)
if mode == "protected":
    parent.send_signal(signal.SIGTERM)
_, stderr = parent.communicate(timeout=30)
print(json.dumps({"status": parent.returncode, "finished": finished.exists(), "stderr": stderr}))
PY
}

# The comparison that gives the test its teeth: without protection SIGINT stops
# the child half way.
assert_json - '.finished == false and .status != 5' <<<"$(scenario plain)"

result=$(scenario protected)
assert_json - '.finished == true and .status == 5' <<<"$result"
warning=$(jq -r .stderr <<<"$result")
assert_contains "$warning" "[dotsteward] WARNING: interrupted while a protected command ran; it finished: "
assert_contains "$warning" "SIGINT"
assert_contains "$warning" "SIGTERM"

# The status of the child, and no warning without a signal.
assert_exit 3 internal run-protected -- bash -c 'exit 3'
assert_eq '' "$DS_STDERR"
assert_exit 0 internal run-protected -- bash -c 'printf out'
assert_eq 'out' "$DS_STDOUT"
assert_exit 2 internal run-protected
assert_exit 127 internal run-protected -- "$work/no-such-command"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot run $work/no-such-command: "

# The standard streams: a child in the background of the terminal must not stop on
# a read of the terminal, so its standard input is empty by default.
assert_exit 0 internal run-protected -- bash -c '[[ -z $(cat) ]]'

# The interface for Python: the result names the signals, and the handlers of
# the caller are back afterwards.
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - <<'PY' || ds_fail "run_protected"
import signal

from dotsteward_cli import procs


def mine(signum, frame):
    raise AssertionError("the caller's handler ran while the child ran")


signal.signal(signal.SIGINT, mine)
result = procs.run_protected(["bash", "-c", 'kill -INT "$PPID"; sleep 0.2; exit 4'])
assert result.returncode == 4 and result.interrupted == ("SIGINT",), result
assert signal.getsignal(signal.SIGINT) is mine, "the handler is not restored"
result = procs.run_protected(["true"])
assert result.returncode == 0 and result.interrupted == (), result
PY
