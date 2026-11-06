# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Firmware only on the owner's word: the list comes first, a terminal asks device by device,
# without a terminal nothing is ever applied, `--accept` answers but does not replace the
# terminal, mains power only, locked devices are named and left alone, nothing reboots.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

ds_use_stubs sudo
bin=$DS_TEST_ROOT/firmware-bin
mkdir -p "$bin"
export PATH=$bin:$PATH
review=$DOTSTEWARD_STATE_ROOT/review.json
log=$DS_TEST_ROOT/fwupdmgr.log
power=$DS_SYSTEM_ROOT/sys/class/power_supply

# The tool as a machine has it: one JSON document, a device per entry with its flags.
updates=$DS_TEST_ROOT/updates.json
cat >"$updates" <<'JSON'
{
  "Devices": [
    {"Name": "Example SSD", "DeviceId": "aaaa1111", "Version": "1.0", "Flags": ["internal", "updatable", "require-ac", "needs-reboot"],
     "Releases": [{"Version": "2.0"}, {"Version": "1.5"}]},
    {"Name": "Example Dock", "DeviceId": "bbbb2222", "Version": "3.0", "Flags": ["updatable"], "Releases": [{"Version": "3.1"}]},
    {"Name": "Locked BIOS", "DeviceId": "cccc3333", "Version": "4.0", "Flags": ["internal", "updatable", "locked"], "Releases": [{"Version": "4.1"}]},
    {"Name": "Hidden BIOS", "DeviceId": "dddd4444", "Version": "5.0", "Flags": ["internal", "updatable-hidden", "needs-reboot"], "Problems": ["firmware-locked"], "Releases": [{"Version": "5.1"}]},
    {"Name": "Problem Flash", "DeviceId": "eeee5555", "Version": "6.0", "Flags": ["updatable"], "Problems": ["firmware-locked"], "Releases": [{"Version": "6.1"}]}
  ]
}
JSON
cat >"$bin/fwupdmgr" <<SH_STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
case "\$1" in
  get-updates) cat "$updates" ;;
  update) [ "\$2" != "fail-me" ] ;;
esac
SH_STUB
chmod +x "$bin/fwupdmgr"

mains() {
  mkdir -p "$power/ADP1" "$power/BAT1"
  printf 'Mains\n' >"$power/ADP1/type"
  printf '%s\n' "$1" >"$power/ADP1/online"
  printf 'Battery\n' >"$power/BAT1/type"
}

firmware() {
  status=0
  core_python -m dotsteward_cli.firmware "$@" --report firmware-test >"$DS_TEST_ROOT/out" 2>"$DS_TEST_ROOT/err" || status=$?
}

# on_terminal ANSWERS ARG...: the same on a terminal, answering each question with a line of
# ANSWERS (y, n); the text of the terminal lands in TERMINAL.
on_terminal() {
  local answers=$1
  shift
  TERMINAL=$DS_TEST_ROOT/terminal
  status=0
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "$answers" "$TERMINAL" "$@" <<'PY' || status=$?
import os
import pty
import select
import sys
import time

answers, log_path, *arguments = sys.argv[1:]
argv = [sys.executable, "-s", "-P", "-m", "dotsteward_cli.firmware", *arguments, "--report", "firmware-test"]
pid, master = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
text = bytearray()
pending = list(answers)
asked = 0
deadline = time.monotonic() + 60
code = None
while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.05)
    if ready:
        try:
            data = os.read(master, 4096)
        except OSError:
            data = b""
        text += data
    if text.count(b"[y/N]") > asked and pending:
        asked += 1
        os.write(master, pending.pop(0).encode() + b"\n")
    finished, wait_status = os.waitpid(pid, os.WNOHANG)
    if finished:
        code = os.waitstatus_to_exitcode(wait_status)
        break
with open(log_path, "wb") as handle:
    handle.write(text)
sys.exit(code if code is not None else 99)
PY
}

fresh() {
  : >"$log"
  : >"$DS_CALL_LOG"
  rm -f "$review"
}

# --- the list: read only, installable and locked apart

mains 1
fresh
firmware list
assert_eq 3 "$status" "installable firmware waits for a person"
assert_json "$DS_TEST_ROOT/out" '[.installable[].device_id] == ["aaaa1111", "bbbb2222"]'
assert_json "$DS_TEST_ROOT/out" '[.locked[].device_id] == ["cccc3333", "dddd4444", "eeee5555"]'
assert_json "$DS_TEST_ROOT/out" '.installable[0] == {"device_id": "aaaa1111", "name": "Example SSD", "current": "1.0", "new": "2.0", "needs_reboot": true}'
assert_eq "get-updates --json" "$(<"$log")" "the list changes nothing"
assert_call_count 0 sudo

# --- no terminal: never, also with --accept. The report names the devices and the command

fresh
firmware run --accept
assert_eq 3 "$status"
assert_json "$review" '.items[] | select(.code == "firmware-available") | ([.devices[].id] == ["aaaa1111", "bbbb2222"]) and .run == "dotsteward upgrade --accept firmware"'
assert_json "$review" '.items[] | select(.code == "firmware-locked") | [.devices[].id] == ["cccc3333", "dddd4444", "eeee5555"]'
assert_not_contains "$(<"$log")" "update "
assert_call_count 0 sudo

# --- a terminal: device, current and new version, a question for each; only what is approved

fresh
on_terminal yn run
assert_eq 0 "$status"
text=$(<"$TERMINAL")
assert_contains "$text" "Firmware Example SSD: 1.0 -> 2.0. Apply? [y/N]"
assert_contains "$text" "Firmware Example Dock: 3.0 -> 3.1. Apply? [y/N]"
assert_not_contains "$text" "Locked BIOS"
assert_not_contains "$text" "Hidden BIOS"
assert_contains "$(<"$log")" "update aaaa1111 --assume-yes --no-reboot-check"
assert_not_contains "$(<"$log")" "update bbbb2222"
assert_not_contains "$(<"$log")" "update cccc3333"
assert_not_contains "$(<"$log")" "update dddd4444"
assert_not_contains "$(<"$log")" "update eeee5555"
# A short window: sudo opens it and closes it again.
assert_call_count 1 sudo '*-v*'
assert_call_count 1 sudo '*-k*'
# A needed reboot is reported; nothing reboots. A locked device is named. No is no decision.
assert_json "$review" '.items[] | select(.code == "firmware-needs-reboot") | [.devices[].id] == ["aaaa1111"]'
assert_json "$review" '.items[] | select(.code == "firmware-available") | .declined == true and ([.devices[].id] == ["bbbb2222"])'

# Enter is no.
fresh
on_terminal nn run
assert_eq 0 "$status"
assert_not_contains "$(<"$log")" "update "
assert_call_count 0 sudo

# --accept answers the question, on the terminal.
fresh
on_terminal '' run --accept
assert_eq 0 "$status"
assert_not_contains "$(<"$TERMINAL")" "[y/N]"
assert_contains "$(<"$log")" "update aaaa1111 --assume-yes --no-reboot-check"
assert_contains "$(<"$log")" "update bbbb2222 --assume-yes --no-reboot-check"

# --- on battery: approved and not applied, and said why

mains 0
fresh
on_terminal yy run
assert_eq 3 "$status"
assert_not_contains "$(<"$log")" "update "
assert_call_count 0 sudo
assert_json "$review" '.items[] | select(.code == "firmware-needs-ac") | [.devices[].id] == ["aaaa1111", "bbbb2222"]'

# No battery at all counts as mains, also without a mains supply.
rm -rf "$power"
mkdir -p "$power/USB1"
printf 'USB\n' >"$power/USB1/type"
fresh
on_terminal '' run --accept
assert_eq 0 "$status"
assert_contains "$(<"$log")" "update aaaa1111"
rm -rf "$power"
fresh
on_terminal '' run --accept
assert_eq 0 "$status"
assert_contains "$(<"$log")" "update aaaa1111"

# --- a device that fails is a failure of the run; the others are still tried

mains 1
jq '.Devices[0].DeviceId = "fail-me"' "$updates" >"$updates.new"
mv "$updates.new" "$updates"
fresh
on_terminal '' run --accept
assert_eq 1 "$status"
assert_contains "$(<"$log")" "update fail-me"
assert_contains "$(<"$log")" "update bbbb2222"
assert_call_count 1 sudo '*-k*'

# --- the tool answers nothing to do, or nothing at all: no decision, no fall over

printf '#!/bin/sh\necho "No updatable devices" >&2\nexit 2\n' >"$bin/fwupdmgr"
fresh
firmware run --accept
assert_eq 0 "$status"
printf '#!/bin/sh\necho "{\\"Devices\\": []}"\n' >"$bin/fwupdmgr"
fresh
firmware list
assert_eq 0 "$status"
assert_json "$DS_TEST_ROOT/out" '.available == true and .installable == []'
printf '#!/bin/sh\necho "daemon not running" >&2\nexit 1\n' >"$bin/fwupdmgr"
fresh
firmware list
assert_eq 6 "$status" "an answer that did not come is a partial run"
assert_json "$DS_TEST_ROOT/out" '.available == false and (.error | test("daemon not running"))'
# No such tool, wherever PATH looks on this machine.
rm -f "$bin/fwupdmgr"
interpreter=$(python3 -c 'import sys; print(sys.executable)')
no_tool=$(
  IFS=:
  for directory in $PATH; do
    [[ -x $directory/fwupdmgr ]] || printf '%s:' "$directory"
  done
)
fresh
PATH=$no_tool PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 "$interpreter" -s -P -m dotsteward_cli.firmware list \
  --report firmware-test >"$DS_TEST_ROOT/out"
assert_json "$DS_TEST_ROOT/out" '.available == false and .error == null'
