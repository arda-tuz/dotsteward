# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A hold ends only when upstream really calls a newer version the latest, or with --retry-held: a
# row the research could not read (an error row, `pins latest` exits 1) keeps it, so the known red
# version is not tried again. While a commit of the pins waits for the remote, no publish of the host
# file takes the holds with it, not even a plain `dotsteward host publish`: the next run publishes
# that same commit and does not write it again.
# shellcheck source=tests/upgrade/holds-helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/holds-helpers.sh"

# --- an error row keeps the hold ------------------------------------------------------------------
move agent_tools.codex.linux 2.0.0 download
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - 'has("pin:agent_tools.codex.linux")'

clear_log
printf '{"items": [{"id": "agent_tools.codex.linux", "current": "0", "latest": null, "status": "error", "details": {"error": "HTTP 403 rate limit"}}]}\n' \
  >"$UP_CONTROL/latest-rows"
printf '1\n' >"$UP_CONTROL/latest-status"
assert_exit 3 upgrade --tracked
rm -f -- "$UP_CONTROL/latest-status"
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
remote_holds example-host | assert_json - 'has("pin:agent_tools.codex.linux")'

clear_log
printf '{"items": [{"id": "agent_tools.codex.linux", "current": "0", "latest": "2.0.0", "status": "update"}]}\n' \
  >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
assert_no_step '^rebuild .*root=.*/upgrade/work'
assert_eq "null" "$(git -C "$up_bare" show main:versions.lock.json | jq -c '."agent_tools.codex.linux" // null')"

# --- a plain host publish while a commit of the pins waits keeps the holds back ----------------------
clear_log
rm -f -- "$UP_CONTROL/moves" "$UP_CONTROL/latest-rows"
move example.broken3 2.0 pypi:broken3
move example.fine3 1.1 npm:fine3
gate_red_when '."example.broken3" == "2.0"'
printf '137\n' >"$UP_CONTROL/rebuild-status"
before=$(remote_oid)
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/rebuild-status" "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "no commit waits"
assert_exit 0 "$fw/cli/dotsteward" --instance "$up_inst" host publish
assert_eq "$before" "$(remote_oid)" "the hold waits for the commit of the pins"
clear_log
assert_exit 3 upgrade --tracked
assert_eq "" "$(steps '^pins .*apply')" "the waiting commit goes out as it is"
assert_not_contains "$DS_STDOUT" "another machine published first"
assert_eq "$(git -C "$up_inst" rev-parse "$waiting^{tree}")" "$(git -C "$up_bare" rev-parse "main^^{tree}")"
assert_eq "hosts/example-host.toml" "$(files_of main)"
remote_holds example-host | assert_json - 'has("pin:example.broken3")'
