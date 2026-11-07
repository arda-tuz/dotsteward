# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Firmware is a Linux matter (fwupd), and the platform is the one the CLI sees: DOTSTEWARD_PLATFORM
# first, as everywhere else. On darwin `firmware list` asks no tool and leaves nothing to decide; on
# linux it lists, also when the machine under the test is a Mac.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

bin=$DS_TEST_ROOT/firmware-bin
mkdir -p "$bin"
export PATH=$bin:$PATH
review=$DOTSTEWARD_STATE_ROOT/review.json
log=$DS_TEST_ROOT/fwupdmgr.log
cat >"$bin/fwupdmgr" <<SH_STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
printf '%s\n' '{"Devices": [{"Name": "Example Dock", "DeviceId": "bbbb2222", "Version": "3.0", "Flags": ["updatable"], "Releases": [{"Version": "3.1"}]}]}'
SH_STUB
chmod +x "$bin/fwupdmgr"

firmware_list() {
  status=0
  core_python -m dotsteward_cli.firmware list --report firmware-test >"$DS_TEST_ROOT/out" 2>"$DS_TEST_ROOT/err" || status=$?
}

: >"$log"
DOTSTEWARD_PLATFORM=darwin firmware_list
assert_eq 0 "$status" "nothing waits on darwin"
assert_eq "" "$(<"$log")" "no tool is asked on darwin"
[[ ! -e $review ]] || assert_eq 0 "$(jq '[.items[]? | select(.code | startswith("firmware"))] | length' "$review")"

DOTSTEWARD_PLATFORM=linux firmware_list
assert_eq 3 "$status" "on linux the dock waits for a person"
assert_contains "$(<"$log")" "get-updates --json"
