# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of the fakes run later and are single-quoted on purpose
# After a publish the checkout follows when it can, and says why when it cannot. A dirty checkout
# behind what was published is `checkout-behind`, never a red E2E of a lock it does not have; a
# checkout with commits of its own is told to rebase; a checkout on another branch is never moved.
# The tracking ref follows the remote, a commit whose push already landed is said as such, and a
# last rebuild of the checkout that fails leaves the approved firmware waiting.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
answer='Update these too=n'

run_quiet() {
  on_terminal "$answer" -- --tracked >"$DS_TEST_ROOT/run.out" 2>&1 || true
}

behind_item() {
  jq -c '[.items[] | select(.code == "checkout-behind")][0] // {}' "$(newest_report)"
}

# during_latest SCRIPT: SCRIPT runs once while the writer looks for versions.
during_latest() {
  printf '%s\n' "$1" >"$UP_CONTROL/during-latest.sh"
  python3 - "$fw/cli/commands/pins.sh" "$UP_CONTROL/during-latest.sh" <<'PY'
import sys
path, script = sys.argv[1:]
text = open(path).read()
hook = f"  latest)\n    if [[ -f {script} ]]; then bash {script}; rm -f {script}; fi\n"
if hook not in text:
    text = text.replace("  latest)\n", hook, 1)
open(path, "w").write(text)
PY
}

# --- a dirty checkout behind what was published -----------------------------------------------
printf '# a note of the owner\n' >>"$up_inst/workstation.toml"
move example.one 2.0 pypi
run_quiet
assert_eq 2.0 "$(git -C "$up_bare" show refs/heads/main:versions.lock.json | jq -r '."example.one"')"
assert_contains "$(behind_item)" "uncommitted changes"
assert_contains "$(behind_item)" "stash"
# The next run: E2E of this checkout would read a lock the active generation does not have.
: >"$UP_CONTROL/e2e-red"
printf 'core:agents\n' >"$UP_CONTROL/e2e-red"
clear_log
assert_exit 3 upgrade --tracked
assert_no_step '^e2e '
last_report '[.items[] | select(.code == "e2e-red")] == []'
last_report '[.items[] | select(.code == "checkout-behind" and .pending)] | length == 1'
assert_eq pending "$(step_status e2e)"
rm -f "$UP_CONTROL/e2e-red"
git -C "$up_inst" checkout -q -- workstation.toml
run_quiet
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)" "a clean checkout follows"

# --- the tracking ref follows the remote -------------------------------------------------------
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse refs/remotes/origin/main)"

# --- a commit of the owner during the run: rebase, not pull --ff-only -------------------------
move example.two 2.0 pypi
during_latest "cd $up_inst && printf 'mine\n' >MINE.txt && git add MINE.txt && git -c user.name=owner -c user.email=owner@example.invalid commit -q -m 'feat: mine during the run'"
run_quiet
assert_contains "$(behind_item)" "pull --rebase"
assert_not_contains "$(behind_item)" "uncommitted"
git -C "$up_inst" reset -q --hard "$(remote_oid)"

# --- a switch to another branch during the run: that branch stays where it was ----------------
base=$(remote_oid)
move example.three 2.0 pypi
during_latest "cd $up_inst && git checkout -q -b feature"
run_quiet
assert_eq "$base" "$(git -C "$up_inst" rev-parse feature)" "the other branch is never moved"
assert_contains "$(behind_item)" "feature"
assert_contains "$(behind_item)" "git -C $up_inst switch main"
git -C "$up_inst" checkout -q main
git -C "$up_inst" branch -q -D feature
run_quiet

# --- the push of a waiting commit had landed ---------------------------------------------------
move example.four 2.0 pypi
: >"$UP_CONTROL/drop-network-after-e2e"
run_quiet
rm -f "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "a commit waits"
git -C "$up_inst" push -q origin "$waiting:refs/heads/main"
run_quiet
assert_contains "$(<"$DS_TEST_ROOT/run.out")" "the waiting commit is already published"
assert_not_contains "$(<"$DS_TEST_ROOT/run.out")" "another machine published first"
assert_eq "$waiting" "$(git -C "$up_inst" rev-parse HEAD)"

# --- the last rebuild of the checkout fails: the approved firmware waits ---------------------
cat >"$DS_TEST_ROOT/updates.json" <<'JSON'
{"Devices": [{"Name": "Dev One", "DeviceId": "aaaa1111", "Version": "1.0", "Flags": ["internal", "updatable"],
  "Releases": [{"Version": "2.0"}]}]}
JSON
tool_stub fwupdmgr "case \"\$1\" in get-updates) cat '$DS_TEST_ROOT/updates.json';; esac"
printf '[[ $DOTSTEWARD_INSTANCE == */upgrade/work ]] || exit 1\n' >"$UP_CONTROL/rebuild-status-hook"
move example.five 2.0 pypi
clear_log
on_terminal 'Dev One=y' "$answer" -- --tracked >"$DS_TEST_ROOT/run.out" 2>&1 || true
assert_eq failed "$(step_status checkout-rebuild)"
assert_no_step 'fwupdmgr update'
last_report '[.items[] | select(.code == "firmware-available")] | length == 1'
