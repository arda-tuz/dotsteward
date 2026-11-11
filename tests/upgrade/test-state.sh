# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# upgrade records what this machine observes on its own branch state/<name> and pushes it, so the
# versions it moved reach the remote next to the shared lock it published: once before the offer
# of tracked mode, which may wait for hours, and once more after the extra pass. What the run
# updated outside what is tracked never enters the record, the intent or the shared lock. Without
# a network the record waits on this machine and the next run lands it. A machine without a name
# and --plan record nothing.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
: >"$UP_CONTROL/apt-installs"
ds_dpkg_installed example-tracked 1.0
ds_dpkg_installed example-tracked-lib 1.0
ds_dpkg_installed example-untracked 1

state_ref=refs/heads/state/example-host
remote_state() {
  git -C "$up_bare" cat-file blob "$state_ref:state.json"
}
remote_state_json() {
  remote_state >"$DS_TEST_ROOT/remote-state.json"
  assert_json "$DS_TEST_ROOT/remote-state.json" "$1"
}

lock_before=$(sha256sum "$up_inst/versions.lock.json")
toml_before=$(sha256sum "$up_inst/workstation.toml")

# --- tracked, the offer declined: the moved version is on the remote --------------------------------
apt_answer commit-tracked '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1.0", "to": "1.1"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true, "log": null}'
apt_answer commit-all '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-untracked", "from": "1", "to": "2"},
    {"name": "example-tracked-lib", "from": "1.0", "to": "2.0"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true, "log": null}'
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
git -C "$up_bare" rev-parse --verify --quiet "$state_ref" >/dev/null || ds_fail "no state branch on the remote"
remote_state_json '.recorded_by == "upgrade" and .host == "example-host"'
remote_state_json '.components["example-app"].packages["example-tracked"] == "1.1"'
remote_state_json '.components["example-app"].packages["example-tracked-lib"] == "1.0"'
remote_state_json '.intent_commit == "'"$(git -C "$up_inst" rev-parse HEAD)"'"'
assert_eq ok "$(step_status state)"
# Only the state branch and main: the checkout never moves for it.
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout stays clean"
assert_eq main "$(git -C "$up_inst" symbolic-ref --short HEAD)"
# The record was made before the offer: it is on the remote while the question is open.
assert_order '^e2e ' '^apt analysis'

# --- the offer accepted: the extra pass is in a second record, the untracked package never ------------
first=$(git -C "$up_bare" rev-parse "$state_ref")
apt_answer commit-tracked "$NOTHING_CHANGED"
assert_exit 0 on_terminal 'Update these too=y' -- --tracked
assert_contains "$(steps '^apt commit')" '"mode":"all"'
[[ $(git -C "$up_bare" rev-parse "$state_ref") != "$first" ]] || ds_fail "the extra pass recorded nothing"
remote_state_json '.components["example-app"].packages["example-tracked-lib"] == "2.0"'
assert_not_contains "$(remote_state)" "example-untracked"
assert_not_contains "$(git -C "$up_bare" log -p --all --format=%s | cat)" "example-untracked"
assert_eq "$toml_before" "$(sha256sum "$up_inst/workstation.toml")"
assert_eq "$lock_before" "$(sha256sum "$up_inst/versions.lock.json")"

# --- everything, no terminal: the same --------------------------------------------------------------
apt_answer commit-all '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-untracked", "from": "2", "to": "3"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true, "log": null}'
ds_dpkg_installed example-untracked 2
assert_exit 0 on_terminal -- --all
assert_not_contains "$(remote_state)" "example-untracked"
assert_eq "$toml_before" "$(sha256sum "$up_inst/workstation.toml")"

# --- offline: the record waits here, the next run lands it -------------------------------------------
apt_answer commit-all "$NOTHING_CHANGED"
before=$(git -C "$up_bare" rev-parse "$state_ref")
ds_dpkg_installed example-tracked 1.2
: >"$UP_CONTROL/network-down"
assert_exit 6 on_terminal -- --tracked
assert_contains "$(git -C "$up_inst" cat-file blob "$state_ref:state.json")" '"example-tracked": "1.2"'
assert_eq "$before" "$(git -C "$up_bare" rev-parse "$state_ref")" "nothing reached the remote offline"
assert_eq partial "$(step_status state)"
rm -f -- "$UP_CONTROL/network-down"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
remote_state_json '.components["example-app"].packages["example-tracked"] == "1.2"'

# --- --plan and a machine without a name record nothing ------------------------------------------------
before=$(git -C "$up_bare" rev-parse "$state_ref")
local_before=$(git -C "$up_inst" rev-parse "$state_ref")
ds_dpkg_installed example-tracked 1.3
assert_exit 0 upgrade --plan
assert_eq "$local_before" "$(git -C "$up_inst" rev-parse "$state_ref")" "--plan recorded the state"
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine.json"
assert_exit 3 upgrade --tracked
assert_eq "$local_before" "$(git -C "$up_inst" rev-parse "$state_ref")" "a machine without a name recorded the state"
assert_eq "$before" "$(git -C "$up_bare" rev-parse "$state_ref")"
