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
# The default without subprocess is the value of subprocess.
import subprocess

assert procs.DEVNULL == subprocess.DEVNULL
PY

# --- the terminal goes away ------------------------------------------------------------

# closed_terminal NAME CHILD ARG...: `internal ARG...` as the foreground job of a real
# terminal. Waits for NAME.started from the command it runs and for NAME.ready from
# this test, closes the terminal and then lets the command go on with NAME.closed.
# CHILD is the bash text of the command after that. Prints what happened.
closed_terminal() {
  core_python - "$work/$1" "$2" "${@:3}" <<'PY'
import json
import os
import pty
import sys
import time

base, child, *arguments = sys.argv[1:]
body = f': >"{base}.started"; until [[ -e "{base}.closed" ]]; do sleep 0.02; done; {child}'
argv = [sys.executable, "-s", "-P", "-m", "dotsteward_cli.internal", *arguments, "--", "bash", "-c", body]
pid, terminal = pty.fork()
if pid == 0:
    os.execv(sys.executable, argv)
deadline = time.monotonic() + 30
while not (os.path.exists(f"{base}.started") and os.path.exists(f"{base}.ready")):
    assert time.monotonic() < deadline, "the command did not start"
    time.sleep(0.01)
os.close(terminal)
open(f"{base}.closed", "w").close()
_, raw = os.waitpid(pid, 0)
print(json.dumps({"status": os.waitstatus_to_exitcode(raw), "finished": os.path.exists(f"{base}.finished")}))
PY
}
for name in tolerant strict logged; do
  : >"$work/$name.ready"
done

# The status of the child is the status, even though the warning about the signal
# has nowhere to go. A child that takes a failed write in its stride finishes.
result=$(closed_terminal tolerant "echo progress; printf '%s' \"\$?\" >\"$work/tolerant.write\"; : >\"$work/tolerant.finished\"; exit 5" run-protected)
assert_json - '.status == 5 and .finished == true' <<<"$result"
assert_eq 1 "$(<"$work/tolerant.write")" "the write to the closed terminal"

# The comparison that gives --log its teeth: a child that stops on a failed write
# stops half way when it writes to the terminal.
result=$(closed_terminal strict "set -e; echo progress; : >\"$work/strict.finished\"; exit 5" run-protected)
assert_json - '.status == 1 and .finished == false' <<<"$result"

# With its streams in a file it finishes. The file also says what the terminal
# could not, and it is private.
result=$(closed_terminal logged "set -e; echo progress; echo problem >&2; : >\"$work/logged.finished\"; exit 5" run-protected --log "$work/child.log")
assert_json - '.status == 5 and .finished == true' <<<"$result"
log=$(<"$work/child.log")
assert_contains "$log" "progress"
assert_contains "$log" "problem"
assert_contains "$log" "[dotsteward] WARNING: interrupted while a protected command ran; it finished: SIGHUP"
assert_file_mode "$work/child.log" 600

# The file grows: a second command with the same file keeps what is there.
assert_exit 0 internal run-protected --log "$work/child.log" -- bash -c 'echo second'
assert_eq '' "$DS_STDOUT"
assert_contains "$(<"$work/child.log")" "progress"
assert_contains "$(<"$work/child.log")" "second"
assert_exit 1 internal run-protected --log "$work/no-such-directory/child.log" -- touch "$work/log-refused"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot write $work/no-such-directory/child.log: "
[[ ! -e $work/log-refused ]] || ds_fail "a command ran without the file it was to write to"

# A command under a lock is not protected: it stays with the terminal and ends with it.
# Its status is the status all the same, while the message about the pending command
# it started has nowhere to go.
state=$work/state
closed_terminal locked "exit 5" lock run --holder upgrade --state-root "$state" >"$work/locked.result" &
driver=$!
core_wait "$work/locked.started"
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- touch "$work/after-closed"
: >"$work/locked.ready"
wait "$driver"
assert_json "$work/locked.result" '.status == 129'
core_wait "$work/after-closed"

# The Python interface takes the streams too.
core_python - "$work" <<'PY' || ds_fail "the streams of run_protected"
import sys

from dotsteward_cli import procs

work = sys.argv[1]
with open(f"{work}/out", "wb") as out, open(f"{work}/err", "wb") as err:
    result = procs.run_protected(["bash", "-c", "echo to-out; echo to-err >&2"], stdout=out, stderr=err)
assert result.returncode == 0, result
assert open(f"{work}/out").read() == "to-out\n"
assert open(f"{work}/err").read() == "to-err\n"
PY

# --- a signal before the child exists ------------------------------------------------------

# run_attached gives it to the child, which would otherwise never hear of it.
core_python - <<'PY' || ds_fail "a signal before the child of run_attached exists"
import os
import signal
import subprocess
import time

from dotsteward_cli import procs

real_popen = subprocess.Popen


def after_a_signal(*args, **kwargs):
    os.kill(os.getpid(), signal.SIGTERM)
    return real_popen(*args, **kwargs)


subprocess.Popen = after_a_signal
start = time.monotonic()
status = procs.run_attached(["sleep", "30"])
subprocess.Popen = real_popen
assert status == 128 + signal.SIGTERM, status
assert time.monotonic() - start < 20, "the child did not hear of the signal"
env_status = procs.run_attached(["bash", "-c", '[[ $ONLY == this ]]'], env={"ONLY": "this", "PATH": os.environ["PATH"]})
assert env_status == 0, env_status
PY
