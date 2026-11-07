# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: Ctrl-C and kill -9 at the steps of a real commit. Ctrl-C does not reach
# dpkg and the report says it came; after kill -9 the next run recovers dpkg and converges,
# and at no point does a target stand in the pin file.
# shellcheck source=tests/container/scenarios/lib.sh
source "$DS_REPO_ROOT/tests/container/scenarios/lib.sh"
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"

apt --version | head -n 1
sudo_open
world_modinfo
IMAGE=linux-image-7.0.0-44-generic
MODULE=linux-modules-nvidia-595-open

# kill -9 of the helper and of dpkg, and of nothing else: the patterns do not match the sudo
# that runs pkill.
kill_commit() {
  kill -9 "$1"
  sudo -n pkill -9 -f 'apt_helpe[r].py' || true
  sudo -n pkill -9 -x dpkg || true
}

wait_for() {
  local tries=0
  until [[ -e $1 ]]; do
    tries=$((tries + 1))
    ((tries < 1500)) || ds_fail "$1 did not appear: $(tail -n 5 "$out_dir"/run.* 2>/dev/null)"
    sleep 0.1
  done
}

converged() {
  audit_clean
  assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
  assert_eq "$K44" "$(version_of "$IMAGE")"
  assert_eq "$K44" "$(version_of "$MODULE-7.0.0-44-generic")"
  assert_eq "$D106" "$(version_of nvidia-driver-595-open)"
  pin_matches_dpkg
  candidates_stay
}

# commit_behind REQUEST: a commit in the background, killed by the test; PARENT is the process.
commit_behind() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan commit \
    --request - <<<"$1" >"$out_dir/run.behind" 2>&1 &
  PARENT=$!
}

# at_terminal EVENT: one commit of the world on a terminal of its own, the answer in a file.
# When dpkg has come to the hook: EVENT happens, a moment passes and the hook goes on, printing
# as it does. ctrl-c: the key goes to the terminal. hangup: the terminal goes away, as when its
# window closes or the connection drops.
at_terminal() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python python3 -s -P - "$1" "$DS_REPO_ROOT" "$STATE" "$out_dir" <<'PY'
import json
import os
import pty
import select
import sys
import time

event, repo, state, out = sys.argv[1:5]
request_path = os.path.join(out, "terminal-request.json")
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump({"mode": "all"}, handle)
answer_path = os.path.join(out, "terminal-answer.json")
pid, master = pty.fork()
if pid == 0:
    os.environ["PYTHONPATH"] = os.path.join(repo, "cli/python")
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    fd = os.open(answer_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(fd, 1)
    os.execvp("python3", ["python3", "-s", "-P", "-m", "dotsteward_cli.apt_plan", "commit", "--request", request_path, "--report", "apt-test"])
terminal = bytearray()
marker = os.path.join(state, "in-postinst")
deadline = time.monotonic() + 180
sent = False
done = None
while time.monotonic() < deadline:
    if master is not None:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                terminal += os.read(master, 4096)
            except OSError:
                pass
    else:
        time.sleep(0.1)
    if not sent and os.path.exists(marker):
        if event == "ctrl-c":
            os.write(master, b"\x03")
        else:
            os.close(master)
            master = None
        sent = True
        time.sleep(1)
        os.unlink(os.path.join(state, "hang-postinst"))
    finished, code = os.waitpid(pid, os.WNOHANG)
    if finished:
        done = code
        break
said = terminal.decode(errors="replace")[-2000:]
with open(os.path.join(out, "terminal.log"), "wb") as handle:
    handle.write(terminal)
if done is None:
    raise SystemExit(f"the commit did not end; the terminal says: {said}")
if not sent:
    raise SystemExit(f"the commit ended before dpkg came to the hook: {said}")
sys.exit(0)
PY
}

newest_report() {
  find "$DOTSTEWARD_STATE_ROOT/runs/apt-test" -name '*.json' -newer "$out_dir/terminal-request.json" | LC_ALL=C sort | tail -n 1
}

# --- Ctrl-C at the terminal, with sudo asking nothing: the keystroke does not reach dpkg

world_install bind
engine_ok policy
: >"$STATE/hang-postinst"
at_terminal ctrl-c
assert_json "$out_dir/terminal-answer.json" '.status == "committed" and .committed == true and .interrupted == ["SIGINT"]'
assert_json "$(newest_report)" '.interrupted == ["SIGINT"]'
converged
# dpkg printed on the terminal, through sudo, while the answer went to its own stream.
assert_contains "$(<"$out_dir/terminal.log")" "Setting up $IMAGE"

# --- the terminal goes away while dpkg works, and dpkg still has lines to print: it finishes

world_install bind
engine_ok policy
: >"$STATE/hang-postinst"
at_terminal hangup
assert_json "$out_dir/terminal-answer.json" '.status == "committed" and .committed == true and (.interrupted | index("SIGHUP") != null)'
assert_json "$(newest_report)" '.interrupted | index("SIGHUP") != null'
converged
# What dpkg printed after that is in the file the answer names, and the report names it too.
log_file=$(jq -r .log "$out_dir/terminal-answer.json")
assert_contains "$(<"$log_file")" "example hook: postinst goes on"
assert_contains "$(<"$log_file")" "Setting up nvidia-driver-595-open"
assert_file_mode "$log_file" 600
assert_eq "$log_file" "$(jq -r '.steps[] | select(.name == "commit") | .log' "$(newest_report)")"

# --- SIGTERM and SIGHUP reach the parent: it stays until dpkg is done, and says so

world_install bind
engine_ok policy
pairs_before=$(dpkg_pairs)
: >"$STATE/hang-postinst"
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan commit \
  --request - --report apt-test <<<'{"mode": "all"}' >"$out_dir/run.signals" 2>&1 &
parent=$!
wait_for "$STATE/in-postinst"
# During the commit the pin file names what dpkg has, not the target.
pin_holds_no_target "$pairs_before"
kill -TERM "$parent"
kill -HUP "$parent"
sleep 1
kill -0 "$parent" || ds_fail "the parent went away while dpkg ran"
rm -f "$STATE/hang-postinst"
status=0
wait "$parent" || status=$?
assert_eq 0 "$status" "$(tail -n 5 "$out_dir/run.signals")"
converged

# --- kill -9 in a maintainer script: dpkg is left half way, the next run finishes it

world_install bind
engine_ok policy
pairs_before=$(dpkg_pairs)
: >"$STATE/hang-postinst"
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan commit \
  --request - <<<'{"mode": "all"}' >"$out_dir/run.postinst" 2>&1 &
parent=$!
wait_for "$STATE/in-postinst"
kill_commit "$parent"
rm -f "$STATE/hang-postinst"
wait "$parent" 2>/dev/null || true
assert_contains "$(audit)" "$IMAGE"
pin_holds_no_target "$pairs_before"
# Nobody moves anything meanwhile: the pin tells the old state, no candidate is above it.
assert_not_contains "$(apt-get -s full-upgrade 2>/dev/null)" "Inst nvidia-"
engine_ok recover
assert_json "$ENGINE" '.recovery.ran == true and .recovery.clean == true and .status == "done"'
audit_clean
# What dpkg had already unpacked is configured now; the next run finishes what is left, if anything.
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.status == "committed" or .status == "nothing"'
converged

# --- kill -9 while a package is half unpacked: the same run recovers and reinstalls

world_install bind
engine_ok policy
: >"$STATE/hang-preinst"
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan commit \
  --request - <<<'{"mode": "all"}' >"$out_dir/run.preinst" 2>&1 &
parent=$!
wait_for "$STATE/in-preinst"
kill_commit "$parent"
rm -f "$STATE/hang-preinst"
wait "$parent" 2>/dev/null || true
[[ -n $(audit) ]] || ds_fail "dpkg was killed during an unpack and has nothing to say"
# commit itself recovers first: one run converges.
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.recovery.ran == true'
assert_json "$ENGINE" '.status == "committed"'
converged

# --- kill -9 right after dpkg, before the engine writes the pin: the hook of dpkg has done it: no
# candidate, no move, no downgrade, and the next run has nothing to repair

world_install bind
engine_ok policy
printf 'DPkg::Post-Invoke { "pkill -9 -f apt_helpe[r].py || true"; };\n' | sudo -n tee /etc/apt/apt.conf.d/99test-kill >/dev/null
engine commit '{"mode": "all"}'
sudo -n rm -f /etc/apt/apt.conf.d/99test-kill
assert_eq 1 "$ENGINE_STATUS" "the helper died without an answer: $(tail -n 3 "$ENGINE.err")"
audit_clean
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
pin_matches_dpkg
simulation=$(apt-get -s full-upgrade 2>&1)
assert_not_contains "$simulation" "Inst linux-"
assert_not_contains "$simulation" "Inst nvidia-"
assert_not_contains "$simulation" "Remv "
assert_not_contains "$simulation" "Downgrad"
engine_ok policy
assert_json "$ENGINE" '.pin.changed == false'
converged

# --- kill -9 in the prerm of the old driver of a series change: dpkg left deinstall selections that
# a later dselect, aptitude or `dpkg --remove --pending` would act on. The next run takes them back.

world_install series-hooked-old
engine_ok policy
: >"$STATE/hang-prerm"
commit_behind '{"mode": "all", "accept": ["series:nvidia=615-open"]}'
wait_for "$STATE/in-prerm"
kill_commit "$PARENT"
rm -f "$STATE/hang-prerm"
wait "$PARENT" 2>/dev/null || true
assert_contains "$(sudo -n dpkg --get-selections)" "deinstall"
engine_ok recover
assert_json "$ENGINE" '.recovery.ran == true and .recovery.clean == true'
assert_json "$ENGINE" '.items[] | select(.code == "dpkg-selection-restored") | (.packages | index("nvidia-driver-595-open")) != null'
assert_not_contains "$(sudo -n dpkg --get-selections)" "deinstall"
assert_not_contains "$(apt-get -s dselect-upgrade 2>/dev/null)" "Remv "

# The same through a commit, without the word for the new series: nothing of the set stays behind.
world_install series-hooked-old
engine_ok policy
: >"$STATE/hang-prerm"
commit_behind '{"mode": "all", "accept": ["series:nvidia=615-open"]}'
wait_for "$STATE/in-prerm"
kill_commit "$PARENT"
rm -f "$STATE/hang-prerm"
wait "$PARENT" 2>/dev/null || true
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.status == "committed" and .recovery.ran == true'
assert_json "$ENGINE" '[.items[].code] | index("dpkg-selection-restored") != null'
audit_clean
assert_not_contains "$(sudo -n dpkg --get-selections)" "deinstall"
assert_not_contains "$(apt-get -s dselect-upgrade 2>/dev/null)" "Remv "
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K44" "$(version_of "$MODULE-generic-hwe-24.04")"
assert_eq "$D99" "$(version_of nvidia-driver-595-open)"
pin_matches_dpkg

# --- kill -9 in the preinst of the new driver: apt sees half a transaction. The plan says so and
# decides nothing; the pin step recovers first and keeps the class of the driver.

world_install series-hooked-new
engine_ok policy
: >"$STATE/hang-preinst"
commit_behind '{"mode": "all", "accept": ["series:nvidia=615-open"]}'
wait_for "$STATE/in-preinst"
kill_commit "$PARENT"
rm -f "$STATE/hang-preinst"
wait "$PARENT" 2>/dev/null || true
engine plan '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.applicable == false and .gated.decision == "waiting"'
assert_json "$ENGINE" '[.items[].code] | index("dpkg-interrupted") != null'
engine_ok policy
assert_json "$ENGINE" '.status == "done" and .recovery.ran == true'
assert_contains "$(<"$PIN")" 'src:nvidia-graphics-drivers-*:any'
pin_matches_dpkg
candidates_stay
engine_ok commit '{"mode": "all"}'
audit_clean
pin_matches_dpkg

# --- the lock is taken: the pin step leaves the file alone and says so

world_install bind
engine_ok policy
printf 'Package: *\nPin: version *\nPin-Priority: 100\n' | sudo -n tee "$PIN" >/dev/null
sudo -n /usr/bin/python3 -I -c '
import os, sys, time
import apt_pkg
apt_pkg.init_config()
apt_pkg.init_system()
apt_pkg.pkgsystem_lock()
open(sys.argv[1], "w").close()
while not os.path.exists(sys.argv[2]):
    time.sleep(0.1)
' "$STATE/locked" "$STATE/unlock" &
holder=$!
wait_for "$STATE/locked"
engine policy '{"lock_timeout": 1}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "blocked" and ([.items[].code] | index("dpkg-lock-busy") != null)'
assert_contains "$(<"$PIN")" "Package: *"
: >"$STATE/unlock"
wait "$holder"
rm -f "$STATE/locked" "$STATE/unlock"

# --- an unrelated package dpkg cannot configure: the run stops for a person and moves no class; the
# temporary pins of a run that was killed long ago go away

world_install broken-other
engine_ok policy
: >"$STATE/fail-unrelated"
apt_root dpkg -i /srv/world/repo/pool/example-broken_1.0-1_amd64.deb >/dev/null 2>&1 || true
before=$(gated_state)
sudo -n mkdir -p /tmp/dotsteward-apt-pins-old
sudo -n touch -d '2 days ago' /tmp/dotsteward-apt-pins-old
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "refused" and .committed == false'
assert_json "$ENGINE" '.items[] | select(.code == "dpkg-broken") | (.packages | index("example-broken")) != null'
assert_eq "$before" "$(gated_state)"
[[ ! -e /tmp/dotsteward-apt-pins-old ]] || ds_fail "old temporary pins stay"
rm -f "$STATE/fail-unrelated"
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.status == "committed"'
converged

# --- a maintainer script fails: the run says so, the pin tells what dpkg has, the next run finishes

world_install bind
engine_ok policy
: >"$STATE/fail-postinst"
engine commit '{"mode": "all"}'
assert_eq 1 "$ENGINE_STATUS" "a failed maintainer script fails the run"
assert_json "$ENGINE" '.status == "dpkg-failed" and .committed == false'
[[ -n $(audit) ]] || ds_fail "dpkg stopped at a failed script and has nothing to say"
pin_matches_dpkg
rm -f "$STATE/fail-postinst"
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.recovery.ran == true'
converged

# --- the lock of dpkg is taken: the wait is bounded, the step says who blocks it, nothing moved

world_install bind
engine_ok policy
before=$(gated_state)
sudo -n /usr/bin/python3 -I -c '
import os, sys, time
import apt_pkg
apt_pkg.init_config()
apt_pkg.init_system()
apt_pkg.pkgsystem_lock()
open(sys.argv[1], "w").close()
while not os.path.exists(sys.argv[2]):
    time.sleep(0.1)
' "$STATE/locked" "$STATE/unlock" &
holder=$!
wait_for "$STATE/locked"
engine commit '{"mode": "all", "lock_timeout": 1}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "blocked" and .committed == false'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.items[] | select(.code == "dpkg-lock-busy") | (.message | test("lock"))'
assert_eq "$before" "$(gated_state)"
: >"$STATE/unlock"
wait "$holder"
engine_ok commit '{"mode": "all", "lock_timeout": 30}'
converged

# --- without an open sudo window the step says so instead of hanging on a prompt

sudo -k
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.items[] | select(.code == "sudo-required") | .run == "dotsteward upgrade"'
