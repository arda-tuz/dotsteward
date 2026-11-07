# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The red path of the first release: a red E2E after a move of this run goes back to the tree and the
# binary from before, writes a local hold and publishes nothing; the writer leaves the held row until
# upstream has something newer. Red without anything to go back to is exit 1 and names the checks.
# Nothing is written to the TOML, and the hold stays local.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
holds=$DOTSTEWARD_STATE_ROOT/holds.json
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho old\n' >"$HOME/.local/bin/codex"
printf '#!/bin/sh\necho old helper\n' >"$HOME/.local/bin/codex-helper"
chmod 0755 "$HOME/.local/bin/codex" "$HOME/.local/bin/codex-helper"

# The rebuild installs the new binary; the E2E of the codex component is red once.
fake=$fw/cli/commands/rebuild.sh
cat >>"$fake" <<'FAKE'
if [[ $(jq -r '."agent_tools.codex.linux" // ""' "$root/versions.lock.json") == 2.0.0 ]]; then
  printf '#!/bin/sh\necho new\n' >"$HOME/.local/bin/codex"
  printf '#!/bin/sh\necho new helper\n' >"$HOME/.local/bin/codex-helper"
fi
FAKE

move agent_tools.codex.linux 2.0.0 download
move example.other 3.0.0 pypi
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
output=$DS_STDOUT
remote=$(remote_oid)
assert_eq "$remote" "$(git -C "$up_inst" rev-parse HEAD)" "the checkout never had the commit"
assert_eq "" "$(waiting_commit)"
work_gone
assert_not_contains "$(git -C "$up_inst" log --format=%s -n 1)" "update pinned"
assert_eq "null" "$(jq -c '."agent_tools.codex.linux" // null' "$up_inst/versions.lock.json")"
assert_order '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' "^rebuild .*root=$up_inst\$" "^e2e .*root=$up_inst\$"
assert_eq 2 "$(steps '^rebuild ' | wc -l | tr -d ' ')" "the rebuild of the move and the rebuild back"
assert_eq 2 "$(steps '^e2e ' | wc -l | tr -d ' ')" "red, then the check of the way back"
assert_contains "$output" "agent_tools.codex.linux 2.0.0 stays back"
assert_no_step 'txn publish'
assert_eq "echo old" "$(tail -n 1 "$HOME/.local/bin/codex")" "the binary from before is back"
assert_eq "echo old helper" "$(tail -n 1 "$HOME/.local/bin/codex-helper")" "its companion too"
assert_file_mode "$HOME/.local/bin/codex" 755
[[ ! -e $DOTSTEWARD_STATE_ROOT/rollback/codex ]] || ds_fail "the saved binary stays only while it may be needed"

assert_file_mode "$holds" 600
assert_json "$holds" '.holds | length == 1'
assert_json "$holds" '.holds[0] | .id == "agent_tools.codex.linux" and .version == "2.0.0" and .component == "codex"'
assert_json "$holds" '.holds[0].reason | contains("codex:version")'
review_json '[.items[] | select(.code == "red-held" and .id == "agent_tools.codex.linux")] | length == 1'
assert_not_contains "$(git -C "$up_inst" log -p -n 1 --format=%s -- workstation.toml)" "agent_tools"

# The next run skips the held row, moves the other, and M8: says what is held.
clear_log
printf '{"items": [{"id": "agent_tools.codex.linux", "latest": "2.0.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
assert_eq 3.0.0 "$(jq -r '."example.other"' "$up_inst/versions.lock.json")"
assert_eq "null" "$(jq -c '."agent_tools.codex.linux" // null' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "held" and .id == "agent_tools.codex.linux")] | length == 1'
assert_contains "$DS_STDOUT" "agent_tools.codex.linux stays"

# Upstream has something newer: the hold is over.
clear_log
printf '{"items": [{"id": "agent_tools.codex.linux", "latest": "2.1.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
jq 'map(if .id == "agent_tools.codex.linux" then .to = "2.1.0" else . end)' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip agent_tools"
assert_eq 2.1.0 "$(jq -r '."agent_tools.codex.linux"' "$up_inst/versions.lock.json")"
assert_json "$holds" '.holds | length == 0'

# A rebuild that a signal ended is no red one: no hold, nothing goes back, the next run finishes.
clear_log
move example.interrupted 1.0 pypi
printf '130\n' >"$UP_CONTROL/rebuild-status"
holds_before=$(jq -c .holds "$holds")
assert_exit 130 upgrade --tracked
rm -f -- "$UP_CONTROL/rebuild-status"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "the commit is gone"
last_report ".data.own_commits == [\"$waiting\"] and .interrupted == [\"SIGINT\"]"
assert_eq "$holds_before" "$(jq -c .holds "$holds")"
assert_no_step '^e2e '
work_gone
clear_log
assert_exit 3 upgrade --tracked
assert_order '^rebuild ' '^e2e '
assert_eq "$waiting" "$(remote_oid)"

# A rebuild that fails is: the commit goes, the pin holds.
clear_log
move example.not-building 1.0 pypi
: >"$UP_CONTROL/rebuild-fails-in-work"
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/rebuild-fails-in-work"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_json "$holds" '[.holds[] | select(.id == "example.not-building" and (.reason | contains("rebuild")))] | length == 1'
review_json '[.items[] | select(.code == "red-held" and .id == "example.not-building")] | length == 1'

# M5: the way back is red too: the move is not what broke the machine, so no hold; exit 1, the
# checks named.
clear_log
move example.third 1.0 pypi
holds_before=$(jq -c .holds "$holds")
printf 'core:managed-links\n' >"$UP_CONTROL/e2e-red"
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDOUT" "core:managed-links"
review_json '[.items[] | select(.code == "e2e-red" and (.findings | index("core:managed-links") != null))] | length == 1'
assert_eq "$holds_before" "$(jq -c .holds "$holds")"
assert_no_step 'txn publish'
assert_eq "" "$(waiting_commit)"
rm -f -- "$UP_CONTROL/e2e-red"

# The machine is right again: the innocent pin moves.
clear_log
assert_exit 3 upgrade --tracked
assert_eq 1.0 "$(jq -r '."example.third"' "$up_inst/versions.lock.json")"

# Red with nothing of this run to go back to: exit 1, the way for a package is named; no hold, since
# nothing would read it. M7: the terminal says what is red and what to do.
clear_log
ds_dpkg_installed example-tracked 8.8
printf 'example-app:hook\n' >"$UP_CONTROL/e2e-red"
holds_before=$(jq -c .holds "$holds")
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDOUT" "example-app:hook"
assert_contains "$DS_STDOUT" "sudo apt-mark hold example-tracked"
review_json '[.items[] | select(.code == "e2e-red" and (.findings | index("example-app:hook") != null))] | length == 1'
assert_eq "$holds_before" "$(jq -c .holds "$holds")"
review_json '[.items[] | select(.code == "e2e-red") | .hint] | first | contains("apt-mark hold example-tracked")'

# m3: no offer on a red machine.
clear_log
assert_exit 1 on_terminal -- --tracked
assert_not_contains "$DS_STDOUT" "Update these too"
rm -f -- "$UP_CONTROL/e2e-red"
