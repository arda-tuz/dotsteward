# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# How the producer answers the records of consumers that hold a shared lock back (T19), whatever
# the order of their names:
# - a pin goes back only to a value every consumer that holds it back was green on, through the
#   writer (pins apply --restore), named in the commit message; two such consumers green on
#   different values, or another consumer whose last green run had another value, hold it where it
#   is and wait for a person;
# - a record is open while its red pin still has the value of its red lock, whatever else moved
#   since (a publish of another pin while the consumer went back answers nothing);
# - a record with nothing to put back (the red lock moved no pin of what went red) waits for a
#   person instead of passing as answered;
# - a record this producer cannot read, or a hold with fields it does not know, is said, never
#   acted on;
# - a put back the gate refuses, or that goes red in the E2E of the producer, waits for a person
#   and is not tried again for that lock.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

mkdir -p "$up_inst/hosts"
for host in other-a other-b other-c; do printf 'schema_version = 1\n' >"$up_inst/hosts/$host.toml"; done
set_toml hosts producer '"example-host"'
set_lock() {
  jq --arg id "$1" --arg to "$2" '.[$id] = $to' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
  mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
}
set_lock agent_tools.other.linux 1
set_lock agent_tools.codex.linux 1.0.0
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the lock of X1"
x1=$(git -C "$up_inst" rev-parse HEAD)
set_lock agent_tools.codex.linux 1.5.0
git -C "$up_inst" commit -q -am "chore: update pinned tool versions"
x2=$(git -C "$up_inst" rev-parse HEAD)
set_lock agent_tools.codex.linux 2.0.0
git -C "$up_inst" commit -q -am "chore: update pinned tool versions"
y=$(git -C "$up_inst" rev-parse HEAD)
git -C "$up_inst" push -q origin HEAD:main
start=$(git -C "$up_inst" rev-parse HEAD)

# record HOST JSON: the state record of HOST on the remote (a held object, or other fields).
record() {
  jq -n --arg host "$1" --argjson extra "$2" '{schema_version: 1, host: $host, machine_key: "ffeeddccbbaa99887766554433221100",
    recorded_at: "2026-01-02T00:00:00Z", recorded_by: "upgrade", components: {}} + $extra' >"$DS_TEST_ROOT/$1.json"
  local blob tree commit
  blob=$(git -C "$up_bare" hash-object -w "$DS_TEST_ROOT/$1.json")
  tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$up_bare" mktree)
  commit=$(git -C "$up_bare" -c user.name=o -c user.email=o@example.invalid commit-tree "$tree" -m "state: $1")
  git -C "$up_bare" update-ref "refs/heads/state/$1" "$commit"
}
held() { # X LOCK_COMMIT [COMPONENT]
  jq -cn --arg x "$1" --arg y "$2" --arg c "${3:-codex}" '{held: {commit: $x, lock_commit: $y, components: [$c], at: "2026-01-02T00:00:00Z"}}'
}
forget() {
  for host in "$@"; do git -C "$up_bare" update-ref -d "refs/heads/state/$host"; done
  git -C "$up_inst" for-each-ref --format='%(refname)' refs/remotes/origin/state | while read -r ref; do
    git -C "$up_inst" update-ref -d "$ref"
  done
}
published() {
  git -C "$up_bare" show "main:versions.lock.json" | jq -r --arg id "$1" '.[$id]'
}
reset_remote() {
  git -C "$up_bare" update-ref refs/heads/main "$start"
  git -C "$up_inst" fetch -q origin
  git -C "$up_inst" reset -q --hard "$start"
  rm -f -- "$DOTSTEWARD_STATE_ROOT/holds.json"
}
items() {
  jq -c '[.items[] | select(.code == "consumer-red" or .code == "consumer-unread") | {code, person: (.person // false), machines: (.machines // [.machine]), ids}]' "$(newest_report)"
}
jq -n '{schema_version: "1.0", researched_at: "2026-01-01T00:00:00Z", items: [{id: "agent_tools.codex.linux", latest: "2.0.0"}]}' \
  >"$UP_CONTROL/latest-rows"

# --- two consumers green on different values: nothing goes back, a person decides -----------------------
record other-a "$(held "$x1" "$y")"
record other-b "$(held "$x2" "$y")"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
assert_contains "$(items)" '"person":true'
assert_contains "$DS_STDOUT" "other-a, other-b"
reset_remote

# --- one consumer, and another whose last green run had 1.5.0: never back past it -------------------------
forget other-a other-b
record other-a "$(held "$x1" "$y")"
record other-b "$(jq -cn --arg c "$x2" '{intent_commit: $c, generation: {e2e: "pass", at: "2026-01-02T00:00:00Z"}}')"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
assert_contains "$DS_STDOUT" "other-b"
reset_remote

# --- the consumers that hold it back were green on one value: back to it, named in the message -----------
forget other-a other-b
record other-a "$(held "$x2" "$y")"
record other-c "$(held "$x2" "$y")"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq 1.5.0 "$(published agent_tools.codex.linux)"
assert_contains "$(git -C "$up_bare" log -1 --format=%B main)" "Put back for other-a, other-c: agent_tools.codex.linux 2.0.0 -> 1.5.0 (T19)"
assert_contains "$(<"$UP_LOG")" "--restore"
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[] | select(.id == "agent_tools.codex.linux" and .version == "2.0.0")] | length == 1'
reset_remote

# --- another pin moved since the red lock: the record is still open ---------------------------------------
forget other-a other-c
clone=$DS_TEST_ROOT/race
git clone -q "$up_bare" "$clone"
jq '.["agent_tools.other.linux"] = "2"' "$clone/versions.lock.json" >"$clone/v.json"
mv -- "$clone/v.json" "$clone/versions.lock.json"
git -C "$clone" commit -q -am "chore: update pinned tool versions"
git -C "$clone" push -q origin HEAD:main
rm -rf -- "$clone"
git -C "$up_inst" fetch -q origin
git -C "$up_inst" merge -q --ff-only origin/main
record other-a "$(held "$x2" "$y")"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq 1.5.0 "$(published agent_tools.codex.linux)"
assert_eq 2 "$(published agent_tools.other.linux)"
reset_remote

# --- nothing to put back: a person decides, the record is never answered by itself -------------------------
forget other-a
record other-a "$(held "$x2" "$y" claude-code)"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
assert_eq '[{"code":"consumer-red","person":true,"machines":["other-a"],"ids":[]}]' "$(items)"
reset_remote

# --- a record that cannot be read, a hold with fields this producer does not know ---------------------------
forget other-a
record other-a '{"schema_version": 2}'
record other-b "$(held "$x2" "$y" | jq -c '.held.revert = "all"')"
on_terminal 'Update these too=n' -- --tracked >/dev/null 2>&1 || true
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
assert_eq '[{"code":"consumer-unread","person":false,"machines":["other-a"],"ids":null},{"code":"consumer-unread","person":false,"machines":["other-b"],"ids":null}]' "$(items)"

# --- a put back the gate refuses waits for a person, and is not tried again for that lock ----------------
forget other-a other-b
reset_remote
record other-a "$(held "$x2" "$y")"
{
  printf 'if jq -e %q "$DOTSTEWARD_INSTANCE/versions.lock.json" >/dev/null; then : >%q; else rm -f -- %q; fi\n' \
    '.["agent_tools.codex.linux"] == "1.5.0"' "$UP_CONTROL/static-red" "$UP_CONTROL/static-red"
} >"$UP_CONTROL/during-gate"
on_terminal 'Update these too=n' -- --tracked >/dev/null 2>&1 || true
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
clear_log
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_not_contains "$(<"$UP_LOG")" "--restore"
assert_eq '[{"code":"consumer-red","person":true,"machines":["other-a"],"ids":[]}]' "$(items)"
rm -f -- "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"

# --- every consumer that reports a green run must be green on the value it goes back to -------------------
forget other-a other-b
reset_remote
rm -f -- "$DOTSTEWARD_STATE_ROOT/upgrade/refused-restores.json"
record other-a "$(held "$x2" "$y")"
record other-b "$(jq -cn --arg c "$x1" '{intent_commit: $c, generation: {e2e: "pass", at: "2026-01-02T00:00:00Z"}}')"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
reset_remote
record other-b "$(jq -cn --arg c "$x2" '{intent_commit: $c, generation: {e2e: "pass", at: "2026-01-02T00:00:00Z"}}')"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq 1.5.0 "$(published agent_tools.codex.linux)"
reset_remote

# --- a put back red in the E2E of the producer waits for a person too --------------------------------------
forget other-a other-b
record other-a "$(held "$x2" "$y")"
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
# The tree of the put back was green here before; this time E2E runs and is red.
rm -f -- "$DOTSTEWARD_STATE_ROOT/upgrade/e2e-key.json"
on_terminal 'Update these too=n' -- --tracked >/dev/null 2>&1 || true
assert_eq 2.0.0 "$(published agent_tools.codex.linux)"
clear_log
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_not_contains "$(<"$UP_LOG")" "--restore"
assert_contains "$(items)" '"person":true'
