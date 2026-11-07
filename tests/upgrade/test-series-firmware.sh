# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The word of the owner: a new series is said and waited on, without a question; firmware is listed
# at the start, asked about on a terminal and applied last, in a sudo window of its own, after a
# green E2E; without a terminal never. Same-series moves need no question at all.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
cat >"$DS_TEST_ROOT/updates.json" <<'JSON'
{"Devices": [
  {"Name": "Example SSD", "DeviceId": "aaaa1111", "Version": "1.0", "Flags": ["internal", "updatable"], "Releases": [{"Version": "2.0"}]},
  {"Name": "Locked BIOS", "DeviceId": "cccc3333", "Version": "4.0", "Flags": ["internal", "updatable", "locked"], "Releases": [{"Version": "4.1"}]}
]}
JSON
tool_stub fwupdmgr "case \"\$1\" in get-updates) cat '$DS_TEST_ROOT/updates.json';; esac"

# Same series: moves with no question, the module check is the engine's. New series: an item, no question.
apt_answer commit '{"status": "committed", "committed": true,
  "changes": {"install": [{"name": "linux-image-7.0.0-44-generic", "to": "7.0.0-44.44"}], "upgrade": [{"name": "linux-generic-hwe-24.04", "from": "7.0.0-42.42", "to": "7.0.0-44.44"}], "remove": [], "downgrade": []},
  "gated": {"decision": "move"}, "applicable": true,
  "items": [{"code": "series-available", "pending": false, "class": "nvidia", "series": "615-open", "recommended": "595-open", "accept": "dotsteward upgrade --accept series:nvidia=615-open", "message": "NVIDIA 615-open is available; recommended 595-open"}]}'

# Firmware declined.
assert_exit 0 on_terminal 'Example SSD=n' 'Update these too=n' -- --tracked
output=$DS_STDOUT
assert_contains "$output" "615-open"
assert_contains "$output" "dotsteward upgrade --accept series:nvidia=615-open"
review_json '[.items[] | select(.code == "series-available")] | length == 1'
assert_no_step 'fwupdmgr update'
review_json '[.items[] | select(.code == "firmware-locked")] | length == 1'

# Firmware approved on a terminal: last, in its own window, after E2E; a green run.
clear_log
assert_exit 0 on_terminal 'Example SSD=y' 'Update these too=n' -- --tracked
assert_order '^sudo -k' '^e2e ' '^sudo -v' '^sudo -n fwupdmgr update aaaa1111 --assume-yes --no-reboot-check' '^sudo -k'
assert_no_step 'fwupdmgr update cccc3333'
# The question comes before the sudo window.
[[ $(grep -n -m 1 'Example SSD' <<<"$DS_STDOUT" | cut -d: -f1) -lt $(grep -n -m 1 'Update these too' <<<"$DS_STDOUT" | cut -d: -f1) ]] ||
  ds_fail "the firmware question comes after the offer"

# A red E2E: no firmware.
clear_log
ds_dpkg_installed example-tracked 9.9
printf 'core:example\n' >"$UP_CONTROL/e2e-red"
assert_exit 1 on_terminal 'Example SSD=y' 'Update these too=n' -- --tracked
assert_no_step 'fwupdmgr update'
rm -f -- "$UP_CONTROL/e2e-red"

# On battery the approved firmware waits.
clear_log
power=$DS_SYSTEM_ROOT/sys/class/power_supply
mkdir -p "$power/ADP1" "$power/BAT1"
printf 'Mains\n' >"$power/ADP1/type"
printf '0\n' >"$power/ADP1/online"
printf 'Battery\n' >"$power/BAT1/type"
assert_exit 3 on_terminal 'Example SSD=y' 'Update these too=n' -- --tracked
assert_no_step 'fwupdmgr update'
review_json '[.items[] | select(.code == "firmware-needs-ac")] | length == 1'

# --accept firmware answers the question, a terminal is still needed.
printf '1\n' >"$power/ADP1/online"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked --accept firmware
assert_order '^sudo -n fwupdmgr update aaaa1111'
clear_log
assert_exit 3 upgrade --tracked --accept firmware
assert_no_step 'fwupdmgr update'
review_json '[.items[] | select(.code == "firmware-available")] | length == 1'
