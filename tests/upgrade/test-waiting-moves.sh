# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# What a waiting commit moved is kept next to the commit, not in the last report: a run refused in
# between does not erase it, so a later red still goes back with its hold. A waiting commit that goes
# because another machine came first takes the saved binaries of its move along.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
answer='Update these too=n'
holds=$DOTSTEWARD_STATE_ROOT/holds.json

# Run 1: a commit waits, the network went after its E2E.
move agent_tools.codex.linux 2.0.0 download
: >"$UP_CONTROL/drop-network-after-e2e"
on_terminal "$answer" -- --tracked >/dev/null 2>&1 || true
rm -f "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "a commit waits"

# Run 2: the checkout is on another branch, the run is refused.
git -C "$up_inst" checkout -q -b aside
assert_exit 1 upgrade --tracked
last_report '.data.moved | map(.id) == ["agent_tools.codex.linux"]'
git -C "$up_inst" checkout -q main
assert_eq "$waiting" "$(waiting_commit)"

# Run 3: E2E is red: back, with the hold.
rm -f "$DOTSTEWARD_STATE_ROOT/upgrade/e2e-key.json"
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_eq '["agent_tools.codex.linux"]' "$(jq -c '[.holds[].id]' "$holds")"
last_report '[.items[] | select(.code == "red-held")] | length == 1'
assert_eq "" "$(waiting_commit)"

# --- another machine came first: the saved copy of the move goes with the commit ----------------
rm -f "$holds"
move example.later 3.0.0 pypi
: >"$UP_CONTROL/drop-network-after-e2e"
on_terminal "$answer" -- --tracked >/dev/null 2>&1 || true
rm -f "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
[[ -n $(waiting_commit) ]] || ds_fail "a commit waits"
# A copy an interrupted run left behind.
mkdir -p "$DOTSTEWARD_STATE_ROOT/rollback/codex"
printf 'old copy\n' >"$DOTSTEWARD_STATE_ROOT/rollback/codex/codex"
other=$DS_TEST_ROOT/other-machine
git clone -q "$up_bare" "$other"
printf 'other\n' >"$other/OTHER.txt"
git -C "$other" add OTHER.txt
git -C "$other" -c user.name=other -c user.email=other@example.invalid commit -q -m "feat: from another machine"
git -C "$other" push -q origin HEAD:main
rm -f "$UP_CONTROL/moves"
assert_exit 0 on_terminal "$answer" -- --tracked
assert_contains "$DS_STDOUT" "another machine published first"
[[ ! -e $DOTSTEWARD_STATE_ROOT/rollback ]] || ds_fail "the saved copy of a commit that went stays behind"
