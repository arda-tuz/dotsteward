# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# T19 on the producer: a consumer said in its state record that the shared lock of a commit went red
# there. While that lock is still the one of the tip, the producer puts the pins of the components
# that went red back to the values of the commit the consumer went back to, holds them locally so its
# writer does not move them there again, and publishes that through the gate, its own rebuild and E2E
# as any move of the lock. A pin of another component stays. Once the lock moved, the record is
# answered and changes nothing more.
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
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the lock of X"
x=$(git -C "$up_inst" rev-parse HEAD)
set_lock agent_tools.codex.linux 2.0.0
set_lock agent_tools.other.linux 5
git -C "$up_inst" commit -q -am "chore: update pinned tool versions"
y=$(git -C "$up_inst" rev-parse HEAD)
git -C "$up_inst" push -q origin HEAD:main

# What other-host recorded: held at X, the lock of Y red for codex.
jq -n --arg x "$x" --arg y "$y" '{schema_version: 1, host: "other-host", machine_key: "ffeeddccbbaa99887766554433221100",
  recorded_at: "2026-01-02T00:00:00Z", recorded_by: "upgrade", components: {codex: {}},
  held: {commit: $x, lock_commit: $y, components: ["codex"], at: "2026-01-02T00:00:00Z"}}' >"$DS_TEST_ROOT/other-state.json"
blob=$(git -C "$up_bare" hash-object -w "$DS_TEST_ROOT/other-state.json")
tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$up_bare" mktree)
commit=$(git -C "$up_bare" -c user.name=other -c user.email=other@example.invalid commit-tree "$tree" -m "state: other-host")
git -C "$up_bare" update-ref refs/heads/state/other-host "$commit"

assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
# Published: codex back at the value of X, the other pin where Y put it.
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
[[ $(remote_oid) != "$y" ]] || ds_fail "nothing was published"
assert_json "$up_inst/versions.lock.json" '."agent_tools.codex.linux" == "1.0.0" and ."agent_tools.other.linux" == "5"'
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
