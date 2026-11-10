# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The floor of a deb package moves only in a run whose sudo window installed what apt has: without
# a terminal the window waits, and a floor above the installed version would turn the E2E of the
# package red and send the whole run back. The writer leaves those pins, the run says so, and every
# other pin still moves; a run on a terminal that committed the apt plan moves them.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

# The deb component has the floor pin of its package.
jq '(.components[] | select(.name == "example-app")).install.pin = "desktop_packages.example-app"' "$mirror" >"$mirror.new"
mv -- "$mirror.new" "$mirror"
git -C "$up_inst" commit -q -am "chore: the floor of example-app"
git -C "$up_inst" push -q origin HEAD:main

move desktop_packages.example-app 2.0 download
move agent_tools.codex.linux 2.0.0 download

# No terminal: the sudo window waits, so the floor waits too.
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
assert_eq null "$(jq -c '."desktop_packages.example-app" // null' "$up_inst/versions.lock.json")"
assert_eq 2.0.0 "$(jq -r '."agent_tools.codex.linux"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "deb-floors-wait") | .ids] == [["desktop_packages.example-app"]]'
assert_contains "$DS_STDOUT" "deb-floors-wait"
[[ ! -e $DOTSTEWARD_STATE_ROOT/holds.json ]] || assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '.holds | length == 0'

# A terminal whose sudo window committed the apt plan: the floor moves.
clear_log
apt_answer commit-tracked '{"status": "committed", "committed": true, "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1.0", "to": "2.0"}], "remove": [], "downgrade": []}, "items": [], "gated": {"decision": "no-move"}, "applicable": true}'
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order '^apt commit' '^pins .*apply'
assert_not_contains "$(steps '^pins .*apply')" "--skip desktop_packages"
assert_eq 2.0 "$(jq -r '."desktop_packages.example-app"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "deb-floors-wait")] | length == 0'
