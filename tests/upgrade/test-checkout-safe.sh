# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The checkout belongs to its owner. Whatever a run does and however it ends, it never removes,
# resets or commits what it did not make there: the writer has a clone of its own, and the clone is
# all a failed or interrupted run throws away.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

# The code has no way to do it.
for word in '"reset"' '"clean"' 'reset --' 'clean -'; do
  if grep -n -F -- "$word" "$DS_REPO_ROOT/cli/python/dotsteward_cli/upgrade/"*.py; then
    ds_fail "upgrade must not $word anything"
  fi
done

# --- a file written while the gate runs, and the gate says no ---------------------------------------
move example.one 1.0 pypi
: >"$UP_CONTROL/static-red"
printf 'printf "in progress\\n" >%q/NOTES-IN-PROGRESS.md\n' "$up_inst" >"$UP_CONTROL/during-gate"
assert_exit 1 upgrade --tracked
assert_eq "in progress" "$(<"$up_inst/NOTES-IN-PROGRESS.md")" "somebody's file stays"
assert_eq "?? NOTES-IN-PROGRESS.md" "$(git -C "$up_inst" status --porcelain)"
rm -f -- "$UP_CONTROL/static-red" "$UP_CONTROL/during-gate" "$up_inst/NOTES-IN-PROGRESS.md"
rm -f -- "$DOTSTEWARD_STATE_ROOT/holds.json"
work_gone

# --- an edit of the very file the writer moves, while the gate runs, and the gate says yes ----------
clear_log
printf 'jq %q %q >%q.new\nmv %q.new %q\n' '.by_hand = true' "$up_inst/versions.lock.json" "$up_inst/versions.lock.json" \
  "$up_inst/versions.lock.json" "$up_inst/versions.lock.json" >"$UP_CONTROL/during-gate"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
rm -f -- "$UP_CONTROL/during-gate"
assert_json "$up_inst/versions.lock.json" '.by_hand == true and (."example.one" // null) == null'
assert_eq " M versions.lock.json" "$(git -C "$up_inst" status --porcelain)"
published=$(git -C "$up_bare" show main:versions.lock.json)
assert_contains "$published" "example.one"
assert_not_contains "$published" "by_hand"
review_json '[.items[] | select(.code == "checkout-behind")] | length == 1'
git -C "$up_inst" checkout -q -- versions.lock.json

# --- Ctrl-C in the gate and in the writer: nothing stays, the next run is a normal one --------------
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

clear_log
move example.two 1.0 pypi
printf 'printf "GATE-RUNS\\n" >/dev/tty\nsleep 30\n' >"$UP_CONTROL/during-gate"
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 130 on_terminal 'GATE-RUNS=^C' -- --tracked
rm -f -- "$UP_CONTROL/during-gate"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "" "$(waiting_commit)"
work_gone
assert_no_step '^rebuild '
last_report '.interrupted == ["SIGINT"]'

clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
review_json '[.items[] | select(.code == "checkout-dirty")] | length == 0'
assert_eq 1.0 "$(jq -r '."example.two"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# --- a commit of the owner on top, offline, and red: the commit stays (B2) --------------------------
clear_log
move example.three 1.0 pypi
: >"$UP_CONTROL/drop-network-after-e2e"
assert_exit 6 on_terminal -- --tracked
rm -f -- "$UP_CONTROL/drop-network-after-e2e"
[[ -n $(waiting_commit) ]] || ds_fail "no commit waits"
printf 'my work\n' >"$up_inst/MY-WORK.txt"
git -C "$up_inst" add MY-WORK.txt
git -C "$up_inst" commit -q -m "feat: my local work"
mine=$(git -C "$up_inst" rev-parse HEAD)
clear_log
printf 'example-app:hook\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 on_terminal -- --tracked
assert_eq "$mine" "$(git -C "$up_inst" rev-parse HEAD)"
[[ -e $up_inst/MY-WORK.txt ]] || ds_fail "the work of the owner is gone"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
assert_eq "" "$(waiting_commit)"
work_gone
rm -f -- "$UP_CONTROL/network-down"
# Online, that commit is not upgrade's to publish: a refusal that says so, and it stays.
clear_log
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDERR" "not published"
assert_eq "$mine" "$(git -C "$up_inst" rev-parse HEAD)"
git -C "$up_inst" push -q origin HEAD:main

# --- red with a dirty checkout: the way back works, nothing is orphaned (M9) --------------------------
clear_log
jq 'map(select(.id != "example.three"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
move example.four 1.0 pypi
jq '.mine = 1' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
printf 'example-app:hook\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_json "$up_inst/versions.lock.json" '.mine == 1'
assert_eq " M versions.lock.json" "$(git -C "$up_inst" status --porcelain)"
assert_eq "" "$(waiting_commit)"
assert_order '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' '^rebuild .*root=.*/upgrade/work'
git -C "$up_inst" checkout -q -- versions.lock.json
clear_log
assert_exit 3 upgrade --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
work_gone
