# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The floor of a deb package moves only to a version dpkg has installed: a floor above the installed
# version would turn the E2E of the package red and send the whole run back. Whether a sudo window
# ran says nothing (dpkg's lock may have been busy, the bridge paused, the vendor repository behind):
# what counts is the version of every package of the component that dpkg-query reads after it. A
# floor that waits is named with the version it wants and what is installed; every other pin still
# moves; once the owner's apt, or a window, installed the version, the floor moves without one.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

# The deb component has the floor pin of its package.
jq '(.components[] | select(.name == "example-app")).install.pin = "desktop_packages.example-app"' "$mirror" >"$mirror.new"
mv -- "$mirror.new" "$mirror"
git -C "$up_inst" commit -q -am "chore: the floor of example-app"
git -C "$up_inst" push -q origin HEAD:main

move desktop_packages.example-app 2.0-1 download
move agent_tools.codex.linux 2.0.0 download
printf '{"items": [{"id": "desktop_packages.example-app", "latest": "2.0-1", "status": "update"},
  {"id": "agent_tools.codex.linux", "latest": "2.0.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
ds_dpkg_installed example-tracked 1.0-1
floor() {
  jq -r '."desktop_packages.example-app" // "none"' "$up_inst/versions.lock.json"
}

# No terminal: nothing installed the new version, so the floor waits.
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
assert_eq none "$(floor)"
assert_eq 2.0.0 "$(jq -r '."agent_tools.codex.linux"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "deb-floors-wait") | .floors] == [[{"id": "desktop_packages.example-app", "wanted": "2.0-1", "installed": {"example-tracked": "1.0-1"}}]]'
assert_contains "$DS_STDOUT" "deb-floors-wait"
[[ ! -e $DOTSTEWARD_STATE_ROOT/holds.json ]] || assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '.holds | length == 0'

# A terminal whose window ran without installing it: dpkg's lock was busy, then apt did not bring
# the version. The floor still waits.
for answer in \
  '{"status": "blocked", "committed": false, "changes": {"install": [], "upgrade": [], "remove": [], "downgrade": []}, "items": [{"code": "dpkg-lock-busy", "pending": true, "message": "another apt holds the lock"}], "gated": {"decision": "no-move"}, "applicable": true}' \
  '{"status": "committed", "committed": true, "changes": {"install": [], "upgrade": [{"name": "example-tracked-lib", "from": "1.0", "to": "2.0"}], "remove": [], "downgrade": []}, "items": [], "gated": {"decision": "no-move"}, "applicable": true}'; do
  clear_log
  apt_answer commit-tracked "$answer"
  on_terminal 'Update these too=n' -- --tracked >/dev/null || true
  assert_order '^apt commit' '^pins .*apply'
  assert_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
  assert_eq none "$(floor)"
done

# The version is installed (here by the owner's own apt): the floor moves, with or without a window.
clear_log
apt_answer commit-tracked "$NOTHING_CHANGED"
ds_dpkg_installed example-tracked 2.0-1
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip desktop_packages"
assert_eq 2.0-1 "$(floor)"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "deb-floors-wait")] | length == 0'
