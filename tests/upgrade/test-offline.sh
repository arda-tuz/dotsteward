# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E8, no network: network steps are skipped, the checks run, the exit status is 6, nothing fails
# and nothing is lost. A commit whose push lost the network stays and the next online run publishes
# it, without doing the work again.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub fwupdmgr 'exit 2'
tool_stub snap
move agent_tools.codex.linux 2.0.0 download

# The network ends after E2E: the commit waits, next to the checkout.
: >"$UP_CONTROL/drop-network-after-e2e"
assert_exit 6 on_terminal -- --tracked
assert_eq partial "$(step_status publish)"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "the commit is gone"
[[ $waiting != "$(remote_oid)" ]] || ds_fail "the commit reached the remote"
assert_eq "chore: update pinned tool versions" "$(git -C "$up_inst" log -1 --format=%s "$waiting")"
checkout=$(git -C "$up_inst" rev-parse HEAD)
assert_eq "$(remote_oid)" "$checkout" "the checkout has only what the remote has"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
last_report ".data.own_commits == [\"$waiting\"]"
work_gone

# A whole run offline: the network steps are skipped, E2E runs without the repository checks.
clear_log
rm -f -- "$UP_CONTROL/drop-network-after-e2e"
: >"$UP_CONTROL/network-down"
assert_exit 6 on_terminal -- --tracked
assert_order '^apt recover' '^apt policy' '^sudo -k' '^e2e .*--skip-repo-checks'
assert_no_step '^sudo -n apt-get .*update'
assert_no_step '^apt commit'
assert_no_step '^pins '
assert_no_step '^claude update'
assert_no_step '^rebuild '
assert_eq partial "$(step_status fetch)"
assert_eq "$waiting" "$(waiting_commit)"
last_report ".data.own_commits == [\"$waiting\"]"
assert_json "$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json" '.channels.snap.skipped == "offline"'

# M6: without a network a rebuild that cannot work is no red: no hold, the commit stays.
clear_log
printf '{"generation": "/nix/store/other", "profile": "workstation", "tree_oid": "0", "root": "/elsewhere"}\n' >"$DOTSTEWARD_STATE_ROOT/current/activation.json"
printf '1\n' >"$UP_CONTROL/rebuild-status"
assert_exit 6 on_terminal -- --tracked
assert_no_step '^rebuild '
assert_eq "$waiting" "$(waiting_commit)"
[[ ! -e $DOTSTEWARD_STATE_ROOT/holds.json ]] || ds_fail "no pin is guilty of a network"
review_json '[.items[] | select(.code == "red-held")] | length == 0'

# Online, but the network ends during the rebuild: the same.
clear_log
rm -f -- "$UP_CONTROL/network-down"
cat >"$UP_CONTROL/rebuild-status-hook" <<HOOK
: >"$UP_CONTROL/network-down"
HOOK
# The hook runs in the fake rebuild before it reports its status.
assert_exit 6 on_terminal -- --tracked
assert_eq "$waiting" "$(waiting_commit)"
[[ ! -e $DOTSTEWARD_STATE_ROOT/holds.json ]] || ds_fail "no pin is guilty of a network"
rm -f -- "$UP_CONTROL/rebuild-status" "$UP_CONTROL/network-down" "$UP_CONTROL/rebuild-status-hook"

# Online again: the same commit goes out, the checkout follows. The writer waits for the next run,
# the checks that ran without repository checks run again.
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
# `txn publish` names the machine in it: the tree is what stays.
assert_eq "$(git -C "$up_inst" rev-parse "$waiting^{tree}")" "$(git -C "$up_bare" rev-parse "refs/heads/main^{tree}")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "" "$(waiting_commit)"
assert_no_step '^pins .*apply'
assert_order '^e2e .*root=.*/upgrade/work'
last_report '.data.own_commits == []'
work_gone

# Another machine published while a commit waited: the commit is dropped and made again on the new tip.
clear_log
move agent_tools.codex.linux 3.0.0 download
: >"$UP_CONTROL/drop-network-after-e2e"
assert_exit 6 on_terminal -- --tracked
old_waiting=$(waiting_commit)
[[ -n $old_waiting ]] || ds_fail "the commit is gone"
rm -f -- "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
push_from_elsewhere "feat: a change of another machine"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_contains "$(git -C "$up_inst" log --format=%s -n 3)" "a change of another machine"
if git -C "$up_inst" merge-base --is-ancestor "$old_waiting" HEAD; then
  ds_fail "the old commit is still in the history"
fi
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "3.0.0"'
