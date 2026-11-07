# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# B6, M11: Ctrl-C stops the whole run from every phase: no later step starts, the status is 130, the
# report says so, and the next run finishes. dpkg is left to finish by the engine (tests/container).
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
move agent_tools.codex.linux 2.0.0 download

# The menu: the first thing a person sees. No traceback, nothing changed.
assert_exit 130 on_terminal 'Choice [1/2]=^C' --
assert_not_contains "$DS_STDOUT" "Traceback"
assert_contains "$DS_STDOUT" "nothing was changed"
assert_no_step '^(sudo|apt|pins)'

# The own updater.
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; update) printf "SELF-RUNS\n"; sleep 30;; esac'
assert_exit 130 on_terminal 'SELF-RUNS=^C' -- --tracked
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_no_step 'txn publish'
last_report '.interrupted == ["SIGINT"]'
assert_eq "failed" "$(jq -r '[.steps[] | select(.name == "interrupted") | .status] | first' "$(newest_report)")"
work_gone
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "the commit of the run goes out with the next one"

# The next run finishes.
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$waiting" "$(remote_oid)"
assert_eq "$waiting" "$(git -C "$up_inst" rev-parse HEAD)"

# A channel of the user: sampletool after rustup does not start.
tool_stub rustup 'case "$1" in check) printf "stable - Up to date\n";; update) printf "RUSTUP-RUNS\n"; sleep 30;; esac'
tool_stub sampletool
clear_log
assert_exit 130 on_terminal 'RUSTUP-RUNS=^C' -- --all
assert_no_step '^sampletool tool upgrade'
assert_no_step '^e2e '
last_report '.interrupted == ["SIGINT"]'
tool_stub rustup
tool_stub sampletool

# Firmware: the second device is not written, and the status is not 0.
cat >"$DS_TEST_ROOT/updates.json" <<'JSON'
{"Devices": [
  {"Name": "Dev One", "DeviceId": "aaaa1111", "Version": "1.0", "Flags": ["internal", "updatable"], "Releases": [{"Version": "2.0"}]},
  {"Name": "Dev Two", "DeviceId": "bbbb2222", "Version": "1.0", "Flags": ["internal", "updatable"], "Releases": [{"Version": "2.0"}]}
]}
JSON
tool_stub fwupdmgr "case \"\$1\" in get-updates) cat '$DS_TEST_ROOT/updates.json';; update) printf 'FLASHING %s\n' \"\$2\"; sleep 3;; esac"
clear_log
assert_exit 130 on_terminal 'Dev One=y' 'Dev Two=y' 'Update these too=n' 'FLASHING aaaa=^C' -- --tracked
assert_eq 1 "$(steps 'fwupdmgr update' | grep -c -v '^sudo')" "one device"
assert_not_contains "$(steps 'fwupdmgr update')" "bbbb2222"
review_json '[.items[] | select(.code == "firmware-available" and (.devices | map(.id) | index("bbbb2222") != null))] | length == 1'
last_report '.interrupted == ["SIGINT"]'

# The offer.
tool_stub fwupdmgr 'exit 2'
clear_log
assert_exit 130 on_terminal 'Update these too=^C' -- --tracked
assert_no_step '^sudo -n snap'
