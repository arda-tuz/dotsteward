# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# B3: without a machine name or a profile nothing on this machine can prove new pins or firmware:
# no pin moves, nothing is published, no firmware is written, and the report says what to run.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub claude
cat >"$DS_TEST_ROOT/updates.json" <<'JSON'
{"Devices": [{"Name": "Example SSD", "DeviceId": "aaaa1111", "Version": "1.0", "Flags": ["internal", "updatable"], "Releases": [{"Version": "2.0"}]}]}
JSON
tool_stub fwupdmgr "case \"\$1\" in get-updates) cat '$DS_TEST_ROOT/updates.json';; esac"
tool_stub hostname 'printf "example-host\n"'
move agent_tools.codex.linux 2.0.0 download

# No name, no terminal.
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine.json"
tip=$(remote_oid)
assert_exit 3 upgrade --tracked
assert_no_step '^pins '
assert_no_step 'txn publish'
assert_eq "$tip" "$(remote_oid)"
review_json '[.items[] | select(.code == "machine-name-required" and .run == "dotsteward host init")] | length == 1'
last_report '.data.producer == "unnamed"'
assert_contains "$DS_STDOUT" "dotsteward host init"

# A name without a profile.
jq -n '{schema_version: 1, name: "example-host", machine_key: "00112233445566778899aabbccddeeff",
  named_at: "2026-01-01T00:00:00Z", host: {system: "x86_64-linux", tags: []}}' >"$DOTSTEWARD_STATE_ROOT/machine.json"
clear_log
assert_exit 3 upgrade --tracked
assert_no_step '^pins .*apply'
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_no_step 'txn publish'
review_json '[.items[] | select(.code == "profile-required" and (.run | contains("--profile")))] | length == 1'

# Firmware approved on a terminal: without a green E2E on this machine it waits, and says why.
clear_log
assert_exit 3 on_terminal 'Example SSD=y' 'Update these too=n' -- --tracked
assert_no_step 'fwupdmgr update'
review_json '[.items[] | select(.code == "firmware-available" and (.message | contains("green E2E")))] | length == 1'
