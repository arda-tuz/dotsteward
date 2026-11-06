# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # child scripts are single-quoted on purpose
# The instance lock, <state>/instance.lock (dotsteward_cli.locks): one command at
# a time among apply, upgrade, bootstrap and observe, with fcntl.flock, so it
# needs no flock binary and works on Linux and macOS. A second command fails
# at once and names the holder, or leaves a pending marker that the holder
# honours when it lets go. The kernel drops the lock of a dead holder, children
# of the holder do not keep it, and a command under the lock can run another
# one that asks for it. Other locks (the gate's) nest inside.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

state=$DS_TEST_ROOT/state-under-test
work=$DS_TEST_ROOT/lock-work
mkdir -p "$work"
# Children of the holder call the internal command by itself.
export PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1
inner=(python3 -s -P -m dotsteward_cli.internal)

status_of() {
  internal lock status --state-root "$state"
}

# wait_free: the lock is free within 30 seconds.
wait_free() {
  local tries=0
  until [[ $(status_of | jq -r .held) == false ]]; do
    tries=$((tries + 1))
    ((tries < 1500)) || ds_fail "the lock stays held: $(status_of)"
    sleep 0.02
  done
}

# hold NAME: `lock run` as NAME in the background until release_holder; its
# child has started when this returns.
hold() {
  rm -f -- "$work/started" "$work/release"
  internal lock run --holder "$1" --state-root "$state" -- bash -c '
    : >"$1"
    until [[ -e $2 ]]; do
      sleep 0.02
    done' bash "$work/started" "$work/release" &
  holder_pid=$!
  core_wait "$work/started"
}

release_holder() {
  : >"$work/release"
  wait "$holder_pid"
}

# kill_holder: the process that holds the lock dies by SIGKILL; its child ends.
kill_holder() {
  kill -KILL "$(status_of | jq -r .holder.pid)"
  : >"$work/release"
  wait "$holder_pid" 2>/dev/null || true
}

# --- free: the child runs under the lock, its status is the status ------------------

assert_eq 'false' "$(internal lock status --state-root "$state" | jq -r .held)" "a state root that does not exist yet is free"
assert_exit 0 internal lock run --holder upgrade --state-root "$state" -- bash -c 'printf "%s\n" "$*" >"$0"' "$work/ran" one two
assert_eq 'one two' "$(<"$work/ran")"
assert_file_mode "$state" 700
assert_file_mode "$state/instance.lock" 600
# A state root that exists stays as it is. A new one is private and what it needs
# above it follows the umask: a first command must not close ~/.local to everyone.
mkdir -p "$work/existing-state"
chmod 750 "$work/existing-state"
assert_exit 0 internal lock run --holder upgrade --state-root "$work/existing-state" -- true
assert_file_mode "$work/existing-state" 750
deep_root() {
  umask 022
  internal lock run --holder upgrade --state-root "$work/new-parent/deep/er" -- true
}
assert_exit 0 deep_root
assert_file_mode "$work/new-parent" 755
assert_file_mode "$work/new-parent/deep" 755
assert_file_mode "$work/new-parent/deep/er" 700
assert_exit 7 internal lock run --holder upgrade --state-root "$state" -- bash -c 'exit 7'
killed() {
  internal lock run --holder upgrade --state-root "$state" -- bash -c 'kill -TERM $$'
}
assert_exit 143 killed
# A command that cannot start is an error of its own, and the lock goes.
assert_exit 127 internal lock run --holder upgrade --state-root "$state" -- "$work/no-such-command"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot run $work/no-such-command: "
assert_eq 'false' "$(status_of | jq -r .held)"
assert_exit 2 internal lock run --holder upgrade --state-root "$state"
assert_exit 1 internal lock run --holder 'bad name/' --state-root "$state" -- true
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid lock holder name: "

# --- no state root, no lock -------------------------------------------------------------

# Without an instance and without DOTSTEWARD_STATE_ROOT there is nothing to agree
# on: a default here and an instance's state.root there would be two locks, and two
# commands that both believe they hold the only one.
no_root() (
  unset DOTSTEWARD_STATE_ROOT XDG_STATE_HOME
  cd "$work" || exit 1
  "$@"
)
assert_exit 1 no_root internal lock run --holder upgrade -- touch "$work/no-root-ran"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no instance found, so no state root: "
[[ ! -e $work/no-root-ran ]] || ds_fail "a command ran under a lock nobody else would find"
[[ ! -e $HOME/.local/state/dotsteward ]] || ds_fail "a lock appeared at the default state root"
assert_exit 1 no_root internal lock status
assert_contains "$DS_STDERR" "no instance found, so no state root"
assert_exit 7 no_root core_python -c '
from dotsteward_cli import config, locks

try:
    with locks.instance_lock("upgrade"):
        raise SystemExit("a lock without a state root")
except config.DotstewardError:
    raise SystemExit(7) from None
'
[[ ! -e $HOME/.local/state/dotsteward ]] || ds_fail "the Python interface made a lock at the default state root"
# Printing what the default would be is another matter.
assert_eq "$HOME/.local/state/dotsteward" "$(no_root internal state-root)" "state-root"
[[ ! -e $HOME/.local/state/dotsteward ]] || ds_fail "state-root created something"

# An instance, however it is found, and the override all name one lock.
inst=$DS_TEST_ROOT/lock-instance
core_instance "$inst" "[state]
root = \"$work/instance-state\""
in_instance() (
  unset DOTSTEWARD_STATE_ROOT XDG_STATE_HOME
  cd "$inst" || exit 1
  internal lock run --holder upgrade -- bash -c '
    python3 -s -P -m dotsteward_cli.internal lock status' bash
)
assert_exit 0 in_instance
assert_json - '.held == true and .holder.name == "upgrade"' <<<"$DS_STDOUT"
named_instance() (
  unset DOTSTEWARD_STATE_ROOT XDG_STATE_HOME
  DOTSTEWARD_INSTANCE=$inst
  export DOTSTEWARD_INSTANCE
  internal lock status
)
assert_exit 0 named_instance
assert_json - '.held == false' <<<"$DS_STDOUT"
overridden() (
  unset XDG_STATE_HOME
  cd "$work" || exit 1
  DOTSTEWARD_STATE_ROOT=$work/override-state internal lock run --holder upgrade -- true
)
assert_exit 0 overridden
[[ -e $work/override-state/instance.lock ]] || ds_fail "the override names no lock"

# --- busy: refused at once, and the holder is named -------------------------------------

hold upgrade
assert_exit 1 internal lock run --holder apply --state-root "$state" -- touch "$work/never"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: another command holds the instance lock: upgrade (pid "
assert_eq '' "$DS_STDOUT"
[[ ! -e $work/never ]] || ds_fail "the second command ran"
assert_json - '.held == true and .holder.name == "upgrade" and .holder.pid > 0 and (.holder.since | test("Z$")) and .pending == []' \
  <<<"$(status_of)"

# The lock is flock(2) on the file, as flock(1) and the gate's lock are: another
# lock file does not block, this one does.
if command -v flock >/dev/null 2>&1; then
  ! flock -n "$state/instance.lock" true || ds_fail "flock(1) got a held instance lock"
  flock -n "$work/validate.lock" true || ds_fail "another lock file is blocked"
fi

# With a wait the second command runs once the holder lets go.
(sleep 0.3 && : >"$work/release") &
assert_exit 0 internal lock run --holder apply --wait 20 --state-root "$state" -- touch "$work/after-wait"
[[ -e $work/after-wait ]] || ds_fail "the waiting command did not run"
wait "$holder_pid"

hold upgrade
assert_exit 1 internal lock run --holder apply --wait 0.1 --state-root "$state" -- touch "$work/never"
assert_contains "$DS_STDERR" "another command holds the instance lock: upgrade"
release_holder
wait_free

# --- pending: the holder starts it when it lets go -----------------------------------

pending_script='
  printf "ran\n" >>"$1"
  python3 -s -P -m dotsteward_cli.internal lock status --state-root "$2" >"$3"
  : >"$4"'
pending_child=(bash -c "$pending_script" bash "$work/pending-runs" "$state" "$work/pending-status" "$work/pending-done")
hold upgrade
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- "${pending_child[@]}"
assert_contains "$DS_STDERR" "[dotsteward] the instance lock is held by upgrade; observe runs when it is free"
[[ ! -e $work/pending-runs ]] || ds_fail "the pending command ran at once"
assert_json "$state/instance.pending/observe.json" '.schema_version == 1 and .name == "observe" and (.created_at | test("Z$"))'
assert_json - '(.pending_since.observe | test("Z$"))' <<<"$(status_of)"
# A second request of the same name is one request; another name is another.
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- "${pending_child[@]}"
assert_exit 3 internal lock run --holder capture --pending --state-root "$state" -- touch "$work/capture-ran"
assert_json - '.pending == ["capture", "observe"]' <<<"$(status_of)"
assert_file_mode "$state/instance.pending" 700
assert_file_mode "$state/instance.pending/observe.json" 600
release_holder
core_wait "$work/pending-done"
core_wait "$work/capture-ran"
wait_free
assert_eq 'ran' "$(<"$work/pending-runs")" "one request, one run"
assert_json "$work/pending-status" '.held == true and .holder.name == "observe"'
assert_json - '.pending == []' <<<"$(status_of)"

# The holder's own status stays what it was when a pending command fails, cannot
# start or the marker is damaged.
hold upgrade
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- \
  bash -c ': >"$1"; exit 9' bash "$work/failing-done"
python3 -s -P - "$state/instance.pending" "$work" <<'PY'
import json
import sys

pending, work = sys.argv[1:]
with open(f"{pending}/missing.json", "w", encoding="utf-8") as handle:
    json.dump({"schema_version": 1, "name": "missing", "argv": [f"{work}/no-such-command"]}, handle)
with open(f"{pending}/damaged.json", "w", encoding="utf-8") as handle:
    handle.write("{ not json")
PY
: >"$work/release"
holder_status=0
wait "$holder_pid" || holder_status=$?
assert_eq 0 "$holder_status" "the holder's status"
core_wait "$work/failing-done"
wait_free
assert_json - '.pending == []' <<<"$(status_of)"

# A holder says which pending commands it started.
rm -f -- "$work/started" "$work/release"
internal lock run --holder upgrade --state-root "$state" -- bash -c '
  : >"$1"
  until [[ -e $2 ]]; do
    sleep 0.02
  done' bash "$work/started" "$work/release" 2>"$work/holder-stderr" &
holder_pid=$!
core_wait "$work/started"
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- touch "$work/reported-pending"
release_holder
core_wait "$work/reported-pending"
wait_free
assert_contains "$(<"$work/holder-stderr")" "[dotsteward] started the pending command observe"

# The environment of a pending command is a small fixed set from the command that
# asked. Nothing of the holder's reaches it, and the same call sees the same names
# whether the lock is free or busy.
env_child=(bash -c 'env | LC_ALL=C sort >"$1"; : >"$1.done"' bash)
rm -f -- "$work/started" "$work/release"
DOTSTEWARD_ASSUME_YES=1 HOLDER_ONLY=from-holder LANG=POSIX internal lock run --holder upgrade --state-root "$state" -- bash -c '
  : >"$1"
  until [[ -e $2 ]]; do
    sleep 0.02
  done' bash "$work/started" "$work/release" &
holder_pid=$!
core_wait "$work/started"
ask_pending() {
  ASKER_ONLY=from-asker DOTSTEWARD_HOOKS_OFF=1 LANG=C internal lock run --holder observe --pending \
    --state-root "$state" -- "${env_child[@]}" "$1"
}
assert_exit 3 ask_pending "$work/env-busy"
assert_not_contains "$(<"$state/instance.pending/observe.json")" "from-asker"
release_holder
core_wait "$work/env-busy.done"
wait_free
ask_pending "$work/env-free"
[[ -e $work/env-free.done ]] || ds_fail "the pending command did not run on a free lock"
for file in "$work/env-busy" "$work/env-free"; do
  for leak in HOLDER_ONLY= ASKER_ONLY= DOTSTEWARD_ASSUME_YES= DOTSTEWARD_HOOKS_OFF=; do
    assert_not_contains "$(<"$file")" "$leak" "$file"
  done
  assert_eq 'LANG=C' "$(grep '^LANG=' "$file")" "$file"
  assert_contains "$(<"$file")" "HOME=$HOME" "$file"
done
assert_eq "$(cut -d= -f1 "$work/env-free")" "$(cut -d= -f1 "$work/env-busy")" "the names of the variables, free and busy"

# A transient failure keeps the request for the next holder; a marker a dead holder
# had claimed goes back to the queue; a command that is gone is dropped.
core_python - "$state" "$work" <<'PY' || ds_fail "a pending command that could not start"
import errno
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from dotsteward_cli import locks

state, work = sys.argv[1:]
pending = Path(state) / locks.PENDING_DIRECTORY
pending.mkdir(mode=0o700, exist_ok=True)


def request(name, argv):
    return json.dumps({"schema_version": 1, "name": name, "argv": argv, "cwd": work, "env": dict(os.environ)})


(pending / "busy.json").write_text(request("busy", ["touch", f"{work}/after-emfile"]), encoding="utf-8")
real_popen = subprocess.Popen


def no_descriptors(*args, **kwargs):
    raise OSError(errno.EMFILE, "Too many open files")


subprocess.Popen = no_descriptors
lock = locks.InstanceLock(state, "upgrade")
lock.acquire()
assert lock.release() == [], "nothing started"
subprocess.Popen = real_popen
assert (pending / "busy.json").is_file(), "the request went with the failure"
assert not list(pending.glob(".*.claimed")), "a claimed marker stayed behind"

# A marker claimed by a process that is gone.
dead = subprocess.Popen(["true"])
dead.wait()
(pending / f".crashed.json.{dead.pid}.claimed").write_text(
    request("crashed", ["touch", f"{work}/after-crash-claimed"]), encoding="utf-8"
)
lock = locks.InstanceLock(state, "upgrade")
lock.acquire()
assert sorted(lock.release()) == ["busy", "crashed"]
assert not list(pending.glob(".*.claimed")), "a claimed marker stayed behind"
deadline = time.monotonic() + 30
while not (os.path.exists(f"{work}/after-emfile") and os.path.exists(f"{work}/after-crash-claimed")):
    assert time.monotonic() < deadline, "the kept requests did not run"
    time.sleep(0.01)
PY

# A request that arrives while the lock goes free is not lost: the marker is
# written after the failed try, then the lock is tried again.
python3 -s -P - "$state" <<'PY' || ds_fail "the lock released between the try and the marker"
import os
import sys

from dotsteward_cli import atomic, locks

state = sys.argv[1]
real_write = atomic.atomic_write_json
holder = locks.InstanceLock(state, "upgrade")
holder.acquire()
# The contender stands for another process: it is no child of the holder.
del os.environ[locks.HELD_VARIABLE]


def released_meanwhile(*args, **kwargs):
    holder.release()
    real_write(*args, **kwargs)


atomic.atomic_write_json = released_meanwhile
contender = locks.InstanceLock(state, "observe")
contender.acquire(pending=["true"])
assert contender.held and not contender.nested
assert locks.lock_status(state).pending == [], "the contender took over and removed its own marker"
contender.release()
PY

# A holder that lets go just after the marker is written starts the request. The
# contender, which then gets the lock, stands aside: one request, one run.
python3 -s -P - "$state" "$work/one-run" <<'PY' || ds_fail "the lock released just after the marker"
import os
import sys

from dotsteward_cli import atomic, locks

state, log = sys.argv[1:]
real_write = atomic.atomic_write_json
holder = locks.InstanceLock(state, "upgrade")
holder.acquire()
del os.environ[locks.HELD_VARIABLE]


def released_after(*args, **kwargs):
    real_write(*args, **kwargs)
    holder.release()


atomic.atomic_write_json = released_after
contender = locks.InstanceLock(state, "observe")
try:
    contender.acquire(pending=["bash", "-c", f'printf "ran\\n" >>"{log}"'])
except locks.LockBusy as busy:
    assert busy.pending_recorded, busy
else:
    raise AssertionError("the contender ran as well as the started request")
assert not contender.held
PY
core_wait "$work/one-run"
wait_free
assert_eq 'ran' "$(<"$work/one-run")" "a request started by the holder that let go runs once"
assert_json - '.pending == []' <<<"$(status_of)"

# --- a dead holder -------------------------------------------------------------------

python3 -s -P -c '
import os
import signal
import sys

from dotsteward_cli import locks

lock = locks.InstanceLock(sys.argv[1], "upgrade")
lock.acquire()
os.kill(os.getpid(), signal.SIGKILL)
' "$state" || assert_eq 137 "$?" "the holder died by SIGKILL"
assert_eq 'false' "$(status_of | jq -r .held)" "the kernel dropped the lock"
assert_exit 0 internal lock run --holder upgrade --state-root "$state" -- touch "$work/after-crash"
[[ -e $work/after-crash ]] || ds_fail "the lock of a dead holder blocks"

# A marker the dead holder never honoured goes with the next holder.
hold upgrade
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- touch "$work/late-pending"
kill_holder
wait_free
[[ ! -e $work/late-pending ]] || ds_fail "nobody should have honoured the marker yet"
assert_json - '.pending == ["observe"]' <<<"$(status_of)"
assert_exit 0 internal lock run --holder apply --state-root "$state" -- true
core_wait "$work/late-pending"
wait_free

# A new run of the same name answers an old request of that name.
hold upgrade
assert_exit 3 internal lock run --holder observe --pending --state-root "$state" -- touch "$work/superseded"
kill_holder
wait_free
assert_exit 0 internal lock run --holder observe --state-root "$state" -- true
wait_free
[[ ! -e $work/superseded ]] || ds_fail "the old request of the name ran as well"
assert_json - '.pending == []' <<<"$(status_of)"

# --- a lock file or a holder that are not what they should be -----------------------------

# A failure while the holder names itself does not leave the lock taken.
core_python - "$state" <<'PY' || ds_fail "a failure while taking the lock"
import errno
import os
import sys

from dotsteward_cli import locks

state = sys.argv[1]
real_pwrite = os.pwrite


def disk_full(*args):
    raise OSError(errno.ENOSPC, "No space left on device")


os.pwrite = disk_full
lock = locks.InstanceLock(state, "upgrade")
try:
    lock.acquire()
except OSError:
    pass
else:
    raise AssertionError("the failure was swallowed")
os.pwrite = real_pwrite
assert not lock.held, "the lock stayed taken"
other = locks.InstanceLock(state, "apply")
other.acquire()
other.release()
PY

# An absurd process id in the file is a holder that does not exist, not a crash.
printf '{"name": "x", "pid": %s, "since": "s", "token": "t"}\n' "$(printf '9%.0s' {1..40})" >"$state/instance.lock"
assert_exit 0 internal lock status --state-root "$state"
assert_json - '.held == false' <<<"$DS_STDOUT"
assert_not_contains "$DS_STDERR" "Traceback"
assert_exit 0 internal lock run --holder upgrade --state-root "$state" -- true

# A lock file nobody can open is an error, not a free lock.
chmod 000 "$state/instance.lock"
ds_defer chmod 600 "$state/instance.lock"
if [[ ! -r $state/instance.lock ]]; then
  assert_exit 1 internal lock status --state-root "$state"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
  assert_exit 1 internal lock run --holder upgrade --state-root "$state" -- true
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot take the instance lock in $state: "
fi
chmod 600 "$state/instance.lock"

# A child that was forked and never exec'ed shares the open file: release lets go
# all the same.
core_python - "$state" <<'PY' || ds_fail "a forked child kept the lock"
import os
import signal
import sys
import time

from dotsteward_cli import locks

state = sys.argv[1]
lock = locks.InstanceLock(state, "upgrade")
lock.acquire()
child = os.fork()
if child == 0:
    time.sleep(60)
    os._exit(0)
try:
    lock.release()
    other = locks.FileLock(os.path.join(state, locks.INSTANCE_LOCK_FILE))
    assert other.try_acquire(), "the lock stayed with the forked child"
    other.release()
finally:
    os.kill(child, signal.SIGKILL)
    os.waitpid(child, 0)
PY

# --- children ---------------------------------------------------------------------------

# A process that a command leaves behind does not keep the lock.
assert_exit 0 internal lock run --holder upgrade --state-root "$state" -- bash -c '
  sleep 300 >/dev/null 2>&1 &
  printf "%s" "$!" >"$1"' bash "$work/lingering-pid"
ds_defer kill "$(<"$work/lingering-pid")"
kill -0 "$(<"$work/lingering-pid")" || ds_fail "the lingering process is gone: the test proves nothing"
assert_eq 'false' "$(status_of | jq -r .held)" "a lingering child keeps the lock"

# A command under the lock can run another that asks for it, and the lock stays
# with the outer one; a token that is not the holder's opens nothing.
hold upgrade
with_token() {
  DOTSTEWARD_INSTANCE_LOCK_HELD=$1 internal "${@:2}"
}
assert_exit 1 with_token not-the-holders lock run --holder apply --state-root "$state" -- true
release_holder
wait_free
nested_script='
  "$@" lock run --holder inner --state-root "$STATE" -- bash -c "printf inner >\"\$LOG\""
  "$@" lock status --state-root "$STATE" >"$AFTER"
'
assert_exit 0 env STATE="$state" LOG="$work/inner" AFTER="$work/after-inner" \
  bash -c 'source "$1"; shift; ds_internal lock run --holder outer --state-root "$STATE" -- bash -c "$0" bash "$@"' \
  "$nested_script" "$DS_REPO_ROOT/cli/lib/python.sh" "${inner[@]}"
assert_eq 'inner' "$(<"$work/inner")"
assert_json "$work/after-inner" '.held == true and .holder.name == "outer"'
wait_free

# A stale token in the environment of a free lock does not stop it being taken.
assert_exit 0 with_token stale lock run --holder upgrade --state-root "$state" -- \
  "${inner[@]}" lock status --state-root "$state"
assert_json - '.held == true and .holder.name == "upgrade"' <<<"$DS_STDOUT"

# --- signals -----------------------------------------------------------------------------

# SIGTERM reaches the child, which stops, and the lock goes with a status of its own.
internal lock run --holder upgrade --state-root "$state" -- bash -c '
  trap "exit 42" TERM
  : >"$1"
  while :; do sleep 0.02; done' bash "$work/term-started" &
term_pid=$!
core_wait "$work/term-started"
kill -TERM "$(status_of | jq -r .holder.pid)"
term_status=0
wait "$term_pid" || term_status=$?
assert_eq 42 "$term_status" "the child's status after SIGTERM"
wait_free

# --- many contenders -----------------------------------------------------------------------

# One holder at a time: a counter that is read and written under the lock adds up.
printf '0\n' >"$work/counter"
contender='
import sys

from dotsteward_cli import locks

state, counter = sys.argv[1:]
for _ in range(25):
    with locks.instance_lock("contender", state_root=state, wait=120):
        with open(counter, encoding="utf-8") as handle:
            value = int(handle.read())
        with open(counter, "w", encoding="utf-8") as handle:
            handle.write(f"{value + 1}\n")
'
pids=()
for _ in 1 2 3 4; do
  python3 -s -P -c "$contender" "$state" "$work/counter" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || ds_fail "a contender failed"
done
assert_eq 100 "$(<"$work/counter")" "the lock let two holders in"

# Asking who holds the lock does not make a free lock look busy.
watcher='
import sys
import time

from dotsteward_cli import locks

state = sys.argv[1]
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    locks.lock_status(state)
'
python3 -s -P -c "$watcher" "$state" &
watcher_pid=$!
ds_defer kill "$watcher_pid"
python3 -s -P -c '
import sys

from dotsteward_cli import locks

for _ in range(300):
    with locks.instance_lock("upgrade", state_root=sys.argv[1]):
        pass
' "$state" || ds_fail "a watcher made a free lock look busy"
kill "$watcher_pid"
wait "$watcher_pid" 2>/dev/null || true

# --- the interface for Python ---------------------------------------------------------------

python3 -s -P - "$state" "$work" <<'PY' || ds_fail "the Python interface"
import os
import subprocess
import sys
from pathlib import Path

from dotsteward_cli import locks

state, work = sys.argv[1:]

# The context manager, the busy error and the status.
with locks.instance_lock("upgrade", state_root=state) as lock:
    assert lock.held and not lock.nested
    status = locks.lock_status(state)
    assert status.held and status.holder is not None and status.holder.name == "upgrade", status
    assert status.holder.pid == os.getpid()
    # A process that is not a child: no token in its environment.
    env = {key: value for key, value in os.environ.items() if key != locks.HELD_VARIABLE}
    code = subprocess.run(
        [sys.executable, "-s", "-P", "-c", """
import sys
from dotsteward_cli import locks
try:
    with locks.instance_lock("apply", state_root=sys.argv[1]):
        raise SystemExit("got a held lock")
except locks.LockBusy as busy:
    assert busy.holder.name == "upgrade", busy
    assert "upgrade" in str(busy) and busy.pending_recorded is False
try:
    with locks.instance_lock("observe", state_root=sys.argv[1], pending=["true"]):
        raise SystemExit("got a held lock")
except locks.LockBusy as busy:
    assert busy.pending_recorded is True
""", state],
        env=env,
    ).returncode
    assert code == 0, code
    # A child inherits the token and runs nested.
    code = subprocess.run(
        [sys.executable, "-s", "-P", "-c", """
import sys
from dotsteward_cli import locks
with locks.instance_lock("inner", state_root=sys.argv[1]) as lock:
    assert lock.nested and lock.held
""", state],
    ).returncode
    assert code == 0, code
    # Other locks nest inside, the generic lock of a file is the same primitive.
    other = locks.FileLock(Path(work) / "gate.lock")
    assert other.try_acquire() is True
    second = locks.FileLock(Path(work) / "gate.lock")
    assert second.try_acquire() is False
    other.release()
    assert second.try_acquire() is True
    second.release()
assert locks.HELD_VARIABLE not in os.environ, "the token left the holder's environment"
assert not locks.lock_status(state).held
PY
wait_free

# --- no second lock implementation in the package -----------------------------------------------

others=$(grep -rnE 'fcntl\.flock' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' |
  grep -v 'cli/python/dotsteward_cli/locks.py' || true)
assert_eq "" "$others" "another use of fcntl.flock"
