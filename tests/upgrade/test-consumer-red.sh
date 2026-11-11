# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# T19 on a machine that is not the producer: it follows the remote, and the shared lock the
# producer published goes red here. It goes back to the generation of the commit before, which is
# green again, leaves the marker "held at commit X", and says so in its state record, which the
# producer reads. No commit with that shared lock becomes active here, whatever else the remote
# brings; a commit whose shared lock is another one is tried. Red on the way back holds nothing.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
marker=$DOTSTEWARD_STATE_ROOT/upgrade/held-at.json
state_ref=refs/heads/state/example-host

# Another machine is the producer.
mkdir -p "$up_inst/hosts"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"other-host"'
jq '. + {"agent_tools.codex.linux": "1.0.0"}' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): make other-host the producer"
git -C "$up_inst" push -q origin HEAD:main

# The producer publishes: PIN TO moves the shared lock, anything else is intent.
publish_lock() {
  local clone=$DS_TEST_ROOT/producer-clone
  rm -rf -- "$clone"
  git clone -q "$up_bare" "$clone"
  jq --arg id "$1" --arg to "$2" '.[$id] = $to' "$clone/versions.lock.json" >"$clone/versions.lock.json.new"
  mv -- "$clone/versions.lock.json.new" "$clone/versions.lock.json"
  git -C "$clone" commit -q -am "chore: update pinned tool versions"
  git -C "$clone" push -q origin HEAD:main
  rm -rf -- "$clone"
}
remote_state_json() {
  git -C "$up_bare" cat-file blob "$state_ref:state.json" >"$DS_TEST_ROOT/remote-state.json"
  assert_json "$DS_TEST_ROOT/remote-state.json" "$1"
}

# --- a green start: the generation of X ---------------------------------------------------------------
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
x=$(git -C "$up_inst" rev-parse HEAD)
remote_state_json 'has("held") | not'

# --- the shared lock of Y goes red here: back to X, held there ------------------------------------------
publish_lock agent_tools.codex.linux 2.0.0
y=$(remote_oid)
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
clear_log
assert_exit 3 on_terminal -- --tracked
assert_eq "$y" "$(git -C "$up_inst" rev-parse HEAD)" "the checkout follows the remote as always"
assert_order "^rebuild .*root=$up_inst\$" "^e2e .*root=$up_inst\$" '^rebuild .*root=.*/upgrade/work$' \
  '^e2e .*root=.*/upgrade/work$'
work_gone
assert_eq "$(git -C "$up_inst" rev-parse "$x^{tree}")" "$(jq -r .tree_oid "$DOTSTEWARD_STATE_ROOT/current/activation.json")" \
  "the generation of X is active"
assert_json "$marker" ".commit == \"$x\" and .lock_commit == \"$y\" and .components == [\"codex\"]"
assert_file_mode "$marker" 600
review_json "[.items[] | select(.code == \"consumer-held\" and .commit == \"$x\" and .lock_commit == \"$y\")] | length == 1"
assert_contains "$DS_STDOUT" "other-host"
remote_state_json ".held.commit == \"$x\" and .held.lock_commit == \"$y\" and .held.components == [\"codex\"]"
# Nothing of the lock is written here: only the producer writes it.
assert_eq "$y" "$(remote_oid)"
assert_no_step '^pins '

# --- the remote brings intent on the same lock: nothing of it becomes active ---------------------------
push_from_elsewhere "docs: a line"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "$(git -C "$up_inst" rev-parse "$x^{tree}")" "$(jq -r .tree_oid "$DOTSTEWARD_STATE_ROOT/current/activation.json")"
assert_contains "$DS_STDOUT" "$(git -C "$up_inst" rev-parse --short=12 "$x")"
remote_state_json ".held.lock_commit == \"$y\""

# --- the producer moved that lock: the marker goes and the new lock is tried -----------------------------
publish_lock agent_tools.codex.linux 1.0.0
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order "^rebuild .*root=$up_inst\$" "^e2e .*root=$up_inst\$"
[[ ! -e $marker ]] || ds_fail "the marker stays after the lock moved"
remote_state_json 'has("held") | not'

# --- red on the way back too: nothing is held, the next run tries again ----------------------------------
publish_lock agent_tools.codex.linux 3.0.0
printf 'codex:version\n' >"$UP_CONTROL/e2e-red"
clear_log
assert_exit 1 on_terminal -- --tracked
assert_order "^e2e .*root=$up_inst\$" '^rebuild .*root=.*/upgrade/work$' '^e2e .*root=.*/upgrade/work$'
[[ ! -e $marker ]] || ds_fail "a way back that is red too holds something"
remote_state_json 'has("held") | not'
review_json '[.items[] | select(.code == "e2e-red")] | length == 1'
