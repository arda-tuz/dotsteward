# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# T19 on the producer: a consumer said in its state record that the shared lock of a commit went red
# there. While that lock is still the one of the tip, the producer puts the pins of the components
# that went red back to the values of the commit the consumer went back to, holds them locally so its
# writer does not move them there again, and publishes that through the gate, its own rebuild and E2E
# as any move of the lock. A pin of another component stays, and so does a value of a table that is
# no pin of a component. Once the lock moved, the record is answered and changes nothing more; the
# hold lasts while upstream calls the red version the latest.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

mkdir -p "$up_inst/hosts"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"example-host"'
set_lock() {
  jq --arg id "$1" --arg to "$2" '.[$id] = $to' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
  mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
}
set_lock agent_tools.codex.linux 1.0.0
set_lock agent_tools.other.linux 4
jq '.tables = {bundle_sha256: "a", nested: {version: "1"}}' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the lock of X"
x=$(git -C "$up_inst" rev-parse HEAD)
set_lock agent_tools.codex.linux 2.0.0
set_lock agent_tools.other.linux 5
jq '.tables.bundle_sha256 = "b"' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
git -C "$up_inst" commit -q -am "chore: update pinned tool versions"
y=$(git -C "$up_inst" rev-parse HEAD)
git -C "$up_inst" push -q origin HEAD:main

# What other-host recorded: held at X, the lock of Y red for codex. It runs a newer framework,
# whose record has fields this producer does not know: they do not hide the hold.
jq -n --arg x "$x" --arg y "$y" '{schema_version: 1, host: "other-host", machine_key: "ffeeddccbbaa99887766554433221100",
  recorded_at: "2026-01-02T00:00:00Z", recorded_by: "upgrade", components: {codex: {future_channel: "stable"}},
  future_summary: {count: 1},
  held: {commit: $x, lock_commit: $y, components: ["codex"], at: "2026-01-02T00:00:00Z", reason_code: "e2e"}}' \
  >"$DS_TEST_ROOT/other-state.json"
blob=$(git -C "$up_bare" hash-object -w "$DS_TEST_ROOT/other-state.json")
tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$up_bare" mktree)
commit=$(git -C "$up_bare" -c user.name=other -c user.email=other@example.invalid commit-tree "$tree" -m "state: other-host")
git -C "$up_bare" update-ref refs/heads/state/other-host "$commit"

# Upstream still calls the red version the latest, and the writer would move it there again.
latest_rows() {
  jq -n --arg latest "$1" '{schema_version: "1.0", researched_at: "2026-01-01T00:00:00Z",
    items: [{id: "agent_tools.codex.linux", latest: $latest}]}' >"$UP_CONTROL/latest-rows"
}
latest_rows 2.0.0
move agent_tools.codex.linux 2.0.0 download
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
# Published: codex back at the value of X, the other pin where Y put it.
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
[[ $(remote_oid) != "$y" ]] || ds_fail "nothing was published"
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "1.0.0" and ."agent_tools.other.linux" == "5"'
assert_json "$up_inst/versions.lock.json" '.tables == {bundle_sha256: "b", nested: {version: "1"}}'
assert_order '^static ' '^rebuild .*root=.*/upgrade/work$' '^e2e .*root=.*/upgrade/work$'
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" \
  '[.holds[] | select(.id == "agent_tools.codex.linux" and .version == "2.0.0" and .component == "codex")] | length == 1'
last_report '[.items[] | select(.code == "consumer-red" and .machine == "other-host" and (.ids == ["agent_tools.codex.linux"]))] | length == 1'
assert_contains "$DS_STDOUT" "other-host"

# The lock moved since: the record is answered, nothing more is put back.
tip=$(remote_oid)
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$tip" "$(remote_oid)"
last_report '[.items[] | select(.code == "consumer-red")] | length == 0'

# Upstream has something newer: the hold is over and the pin moves.
latest_rows 2.1.0
printf '[]\n' >"$UP_CONTROL/moves"
move agent_tools.codex.linux 2.1.0 download
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "2.1.0"'

# Checks that name no component: nothing is put back or held, the item names what moved.
before=$(git -C "$up_inst" rev-parse HEAD~1)
after=$(remote_oid)
jq --arg x "$before" --arg y "$after" '.recorded_at = "2026-01-03T00:00:00Z"
  | .held = {commit: $x, lock_commit: $y, components: [], at: "2026-01-03T00:00:00Z"}' \
  "$DS_TEST_ROOT/other-state.json" >"$DS_TEST_ROOT/other-state-2.json"
blob=$(git -C "$up_bare" hash-object -w "$DS_TEST_ROOT/other-state-2.json")
tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$up_bare" mktree)
commit=$(git -C "$up_bare" -c user.name=other -c user.email=other@example.invalid commit-tree "$tree" -p "$commit" \
  -m "state: other-host")
git -C "$up_bare" update-ref refs/heads/state/other-host "$commit"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$after" "$(remote_oid)"
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "2.1.0"'
last_report '[.items[] | select(.code == "consumer-red" and .machine == "other-host" and .ids == [] and
  (.moved | index("agent_tools.codex.linux")))] | length == 1'
