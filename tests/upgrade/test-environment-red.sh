# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of the fakes run later and are single-quoted on purpose
# A red that says nothing about the pins holds nothing. Another gate holding the lock, the network
# going away during the gate, a full disk in its log, an E2E without a result and a rebuild killed
# from outside (137, out of memory) leave no hold: the gate keeps nothing and says why, an E2E or a
# rebuild keeps its commit, and the next run tries again. A gate that judges the tree still holds
# the pins it was given, and `upgrade --retry-held` takes every hold back.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
answer='Update these too=n'
holds=$DOTSTEWARD_STATE_ROOT/holds.json

held() {
  jq -c '[.holds[]? | .id]' "$holds" 2>/dev/null || printf '[]\n'
}

# A run whose status is not the point: what it leaves is.
run_quiet() {
  on_terminal "$answer" -- --tracked >"$DS_TEST_ROOT/run.out" 2>&1 || true
}

published() {
  git -C "$up_bare" show refs/heads/main:versions.lock.json | jq -r --arg id "$1" '.[$id] // "none"'
}

move agent_tools.codex.linux 2.0.0 download

# --- another gate holds its lock ----------------------------------------------------------------
lock=$DOTSTEWARD_STATE_ROOT/update/validate.lock
mkdir -p "$(dirname "$lock")"
: >>"$lock"
# One process holds it, so that ending it frees the lock.
python3 -c 'import fcntl, sys, time
handle = open(sys.argv[1], "a")
fcntl.flock(handle, fcntl.LOCK_EX)
time.sleep(120)' "$lock" &
holder=$!
until ! flock -n "$lock" true; do sleep 0.05; done
run_quiet
kill "$holder"
wait "$holder" 2>/dev/null || true
assert_contains "$(<"$DS_TEST_ROOT/run.out")" "another gate is running"
assert_eq "[]" "$(held)"
last_report '[.items[] | select(.code == "red-held")] == []'
last_report '[.items[] | select(.code == "gate-failed")][0].environment | contains("another gate is running")'
assert_eq "" "$(waiting_commit)"
assert_eq none "$(published agent_tools.codex.linux)"

# --- the network goes away during the gate ------------------------------------------------------
static=$fw/cli/commands/static.sh
sed -i "2a [[ ! -e $UP_CONTROL/net-at-gate ]] || { rm -f $UP_CONTROL/net-at-gate; : >$UP_CONTROL/network-down; echo 'error: unable to download: could not resolve host' >&2; exit 1; }" "$static"
: >"$UP_CONTROL/net-at-gate"
run_quiet
rm -f "$UP_CONTROL/network-down"
assert_eq "[]" "$(held)"
last_report '[.items[] | select(.code == "gate-failed")][0].environment | contains("network")'
assert_eq partial "$(step_status gate)"

# --- the disk is full ---------------------------------------------------------------------------
sed -i "2a [[ ! -e $UP_CONTROL/disk-at-gate ]] || { rm -f $UP_CONTROL/disk-at-gate; echo 'error: writing to file: No space left on device' >&2; exit 1; }" "$static"
: >"$UP_CONTROL/disk-at-gate"
run_quiet
assert_eq "[]" "$(held)"
last_report '[.items[] | select(.code == "gate-failed")][0].environment | contains("No space left on device")'

# --- E2E without a result: the commit waits, nothing is held ----------------------------------
sed -i "2a [[ ! -e $UP_CONTROL/e2e-killed ]] || { rm -f $UP_CONTROL/e2e-killed; exit 137; }" "$fw/cli/commands/e2e.sh"
: >"$UP_CONTROL/e2e-killed"
run_quiet
assert_eq "[]" "$(held)"
[[ -n $(waiting_commit) ]] || ds_fail "the commit of the move waits"
last_report '[.items[] | select(.code == "e2e-no-result")] | length == 1'
last_report '[.items[] | select(.code == "red-held")] == []'
assert_eq none "$(published agent_tools.codex.linux)"
# The next run publishes it.
assert_exit 0 on_terminal "$answer" -- --tracked
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
assert_eq "" "$(waiting_commit)"

# --- a rebuild killed from outside: the commit waits, nothing is held ------------------------
move example.rebuilt 3.0.0 pypi
printf '[[ $DOTSTEWARD_INSTANCE != */upgrade/work || ! -e %s/rebuild-killed ]] || { rm -f %s/rebuild-killed; exit 137; }\n' \
  "$UP_CONTROL" "$UP_CONTROL" >"$UP_CONTROL/rebuild-status-hook"
: >"$UP_CONTROL/rebuild-killed"
clear_log
run_quiet
assert_eq "[]" "$(held)"
[[ -n $(waiting_commit) ]] || ds_fail "the commit of the move waits"
assert_no_step "^rebuild .*root=$up_inst\$"
last_report '[.items[] | select(.code == "red-held")] == []'
assert_exit 0 on_terminal "$answer" -- --tracked
assert_eq 3.0.0 "$(published example.rebuilt)"

# --- a gate that judges the tree holds, and --retry-held takes it back ------------------------
move example.judged 4.0.0 pypi
sed -i "2a [[ ! -e $UP_CONTROL/static-red ]] || { echo 'static: a check failed' >&2; exit 1; }" "$static"
: >"$UP_CONTROL/static-red"
run_quiet
assert_eq '["example.judged"]' "$(held)"
rm -f "$UP_CONTROL/static-red"
assert_exit 0 on_terminal "$answer" -- --tracked
last_report '[.items[] | select(.code == "held")][0].run == "dotsteward upgrade --retry-held"'
assert_eq none "$(published example.judged)"
assert_exit 2 upgrade --plan --retry-held
assert_exit 0 on_terminal "$answer" -- --tracked --retry-held
assert_eq "[]" "$(held)"
assert_eq 4.0.0 "$(published example.judged)"
