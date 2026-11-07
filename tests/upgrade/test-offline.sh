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

# The network ends after E2E: the commit waits.
: >"$UP_CONTROL/drop-network-after-e2e"
assert_exit 6 on_terminal -- --tracked
assert_eq partial "$(step_status publish)"
local_head=$(git -C "$up_inst" rev-parse HEAD)
[[ $local_head != "$(remote_oid)" ]] || ds_fail "the commit reached the remote"
assert_eq "chore: update pinned tool versions" "$(git -C "$up_inst" log -1 --format=%s)"
last_report ".data.own_commits == [\"$local_head\"]"

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
assert_eq partial "$(step_status fetch)"
assert_eq "$local_head" "$(git -C "$up_inst" rev-parse HEAD)"
last_report ".data.own_commits == [\"$local_head\"]"
assert_json "$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json" '.channels.snap.skipped == "offline"'

# Online again: the same commit goes out. The writer waits for the next run, the checks that ran
# without repository checks run again.
clear_log
rm -f -- "$UP_CONTROL/network-down"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$local_head" "$(remote_oid)"
assert_no_step '^pins .*apply'
assert_no_step '^rebuild '
assert_order '^e2e '
last_report '.data.own_commits == []'

# Another machine published while a commit waited: the commit is dropped and made again on the new tip.
clear_log
move agent_tools.codex.linux 3.0.0 download
: >"$UP_CONTROL/drop-network-after-e2e"
assert_exit 6 on_terminal -- --tracked
waiting=$(git -C "$up_inst" rev-parse HEAD)
rm -f -- "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
push_from_elsewhere "feat: a change of another machine"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_contains "$(git -C "$up_inst" log --format=%s -n 3)" "a change of another machine"
if git -C "$up_inst" merge-base --is-ancestor "$waiting" HEAD; then
  ds_fail "the old commit is still in the history"
fi
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "3.0.0"'
