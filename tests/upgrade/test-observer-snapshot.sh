# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# design-v2 6.4 (M12): an E2E that upgrade ran green in this run checked every tracked component as
# dpkg has it, the change of this run and the owner's own alike, so the last observation of the
# observer becomes what is installed and the observer it woke has nothing to do. The result of that
# E2E is the check of each tracked deb component that has checks, so the state record says verified
# or red with the version. A red E2E, or one skipped because its key did not change, leaves the
# observation alone: what the owner changed outside the key is still the observer's to check.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
: >"$UP_CONTROL/apt-installs"
printf 'example-app:installed\n' >"$UP_CONTROL/e2e-checks"
ds_dpkg_installed example-tracked 1.0
ds_dpkg_installed example-tracked-lib 1.0
ds_dpkg_installed example-dependency 1
snapshot=$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json
state_ref=refs/heads/state/example-host
remote_state_json() {
  git -C "$up_bare" cat-file blob "$state_ref:state.json" >"$DS_TEST_ROOT/remote-state.json"
  assert_json "$DS_TEST_ROOT/remote-state.json" "$1"
}
seen() {
  jq -r --arg name "$1" '[.packages | to_entries[] | select(.key | test("^" + $name + "(:|$)")) | .value] | join(" ")' \
    "$snapshot"
}

# --- green: the observation is what is installed, the component verified --------------------------------
apt_answer commit-tracked '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1.0", "to": "1.1"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true, "log": null}'
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_file_mode "$snapshot" 600
assert_eq 1.1 "$(seen example-tracked)"
assert_eq 1 "$(seen example-dependency)"
remote_state_json '.components["example-app"].status == "verified" and .components["example-app"].last_verified.version == "1.1"'
assert_json "$DOTSTEWARD_STATE_ROOT/state/checks.json" '.components["example-app"].result == "pass"'

# --- the owner moves a tracked package, E2E is red: the observation stays, the component is red --------
apt_answer commit-tracked "$NOTHING_CHANGED"
ds_dpkg_installed example-tracked 1.2
printf 'example-app:installed\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 1 on_terminal -- --tracked
assert_eq 1.1 "$(seen example-tracked)"
remote_state_json '.components["example-app"].status == "red" and .components["example-app"].last_verified.version == "1.1"'

# --- green again: now it is the observation ---------------------------------------------------------------
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq 1.2 "$(seen example-tracked)"
remote_state_json '.components["example-app"].status == "verified" and .components["example-app"].last_verified.version == "1.2"'

# --- E2E skipped, its key unchanged: a dependency the owner moved stays the observer's ---------------------
ds_dpkg_installed example-dependency 2
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^e2e '
assert_eq 1 "$(seen example-dependency)"
