# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The producer loses the race of its push: another machine published while the gate proved the new
# pins. No text is merged: the writer runs again on the new tip with the rows it researched, which
# it does not research again, the gate proves the new tree, the clone is rebuilt, E2E checks it
# against the new base, and the commit goes out without force. A remote that keeps moving ends the
# run after three pushes with publish-race: nothing of this machine is published and the next run
# makes the commit again.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

# other_machine once|always: another machine pushes a page while the gate of this one runs.
other_machine() {
  cat >"$UP_CONTROL/during-gate" <<HOOK
set -euo pipefail
clone=$DS_TEST_ROOT/other-machine
rm -rf -- "\$clone"
git clone -q "$up_bare" "\$clone"
printf 'a line of the other machine\n' >>"\$clone/docs/other-page.md"
git -C "\$clone" add -A
git -C "\$clone" -c user.name=other -c user.email=other@example.invalid commit -q \\
  -m "docs: a change of the other machine" -m "Dotsteward-Machine: other-host"
git -C "\$clone" push -q origin HEAD:main
rm -rf -- "\$clone"
HOOK
  if [[ $1 == once ]]; then
    printf 'rm -f -- "%s"\n' "$UP_CONTROL/during-gate" >>"$UP_CONTROL/during-gate"
  fi
}

# --- one lost race: the writer runs again on the new tip ------------------------------------------

move agent_tools.codex.linux 2.0.0 download
other_machine once
upgrade --tracked >/dev/null 2>&1 || true
head=$(remote_oid)
other=$(git -C "$up_bare" rev-parse main^)
assert_eq "chore: update pinned tool versions" "$(git -C "$up_bare" log -1 --format=%s main)"
assert_eq "docs: a change of the other machine" "$(git -C "$up_bare" log -1 --format=%s "$other")"
assert_eq 2.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '."agent_tools.codex.linux"')"
assert_contains "$(git -C "$up_bare" show main:docs/other-page.md)" "a line of the other machine"
assert_eq "example-host" "$(git -C "$up_bare" log -1 --format='%(trailers:key=Dotsteward-Machine,valueonly)' main | sed '/^$/d')"
assert_eq 1 "$(steps '^pins latest' | wc -l)" "the rows are researched once"
assert_eq 2 "$(steps '^pins .*apply' | wc -l)" "the writer runs again on the new tip"
assert_order '^pins .*apply' '^static ' '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' \
  '^pins .*apply' '^static ' '^rebuild .*root=.*/upgrade/work' "^e2e .*--expected-remote-base $other.*root=.*/upgrade/work"
assert_eq "$head" "$(git -C "$up_inst" rev-parse HEAD)" "the checkout follows"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
work_gone
assert_eq "" "$(waiting_commit)"
last_report '[.steps[] | select(.name == "replay")] | length == 1'
last_report '[.steps[] | select(.name == "publish")] | last | .status == "ok"'
review_json '[.items[] | select(.code == "publish-race")] == []'

# --- a remote that keeps moving: three pushes, then publish-race ----------------------------------

clear_log
start=$(remote_oid)
move agent_tools.codex.linux 3.0.0 download
jq 'map(select(.to != "2.0.0"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
other_machine always
upgrade --tracked >/dev/null 2>&1 || true
last_report '.exit_code == 3'
assert_eq 3 "$(git -C "$up_bare" rev-list --count "$start..main")" "the other machine published three times"
assert_eq "" "$(git -C "$up_bare" log --format=%s "$start..main" | grep -v 'other machine' || true)" \
  "nothing of this machine is on the remote"
assert_eq 3 "$(steps '^pins .*apply' | wc -l)"
assert_eq 1 "$(steps '^pins latest' | wc -l)"
last_report '[.steps[] | select(.name == "replay")] | length == 2'
last_report '[.steps[] | select(.name == "publish")] | last | .status == "pending"'
review_json '[.items[] | select(.code == "publish-race")] | length == 1'
work_gone
assert_eq "" "$(waiting_commit)" "the next run makes the commit again on its tip"

# The other machine stops: the next run publishes.
rm -f -- "$UP_CONTROL/during-gate"
clear_log
upgrade --tracked >/dev/null 2>&1 || true
assert_eq 3.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '."agent_tools.codex.linux"')"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "publish-race")] == []'
