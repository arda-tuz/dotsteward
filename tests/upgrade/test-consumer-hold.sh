# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The hold of a consumer (T19) holds wherever the red lock could become active, and never looks
# green:
# - a held run says "held, unverified" and waits (exit 3): nothing of this run is checked;
# - when the red lock became active outside upgrade (a rebuild by hand), the next run checks it
#   with E2E and goes back again, never "held" over an active red lock;
# - a lock that moves only what did not go red here is not tried again: no rebuild and no E2E
#   until something it watches moves (the pins of what went red, or every moved path when the
#   producer has no pin to put back);
# - the whole shared lock counts: a move of the skills lock alone that goes red sends it back
#   too;
# - a machine that becomes the producer drops its marker.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
marker=$DOTSTEWARD_STATE_ROOT/upgrade/held-at.json
activation=$DOTSTEWARD_STATE_ROOT/current/activation.json

mkdir -p "$up_inst/hosts"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"other-host"'
jq '. + {"agent_tools.codex.linux": "1.0.0", "agent_tools.other.linux": "1"}' "$up_inst/versions.lock.json" \
  >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): make other-host the producer"
git -C "$up_inst" push -q origin HEAD:main

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
active() {
  jq -r .revision "$activation"
}
step_of() {
  jq -c --arg name "$1" '[.steps[] | select(.name == $name) | {status, said}]' "$(newest_report)"
}

assert_exit 0 on_terminal 'Update these too=n' -- --tracked
x=$(git -C "$up_inst" rev-parse HEAD)

# --- held: the run waits and says it checked nothing --------------------------------------------------
publish_lock agent_tools.codex.linux 2.0.0
y=$(remote_oid)
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 on_terminal -- --tracked
assert_json "$marker" ".commit == \"$x\" and .lock_commit == \"$y\""
assert_eq "$x" "$(active)"
clear_log
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq '[{"status":"pending","said":"held, unverified"}]' "$(step_of e2e)"
assert_contains "$DS_STDOUT" "e2e: held, unverified"

# --- the red lock activated by hand: the next run checks it and goes back -----------------------------
"$fw/cli/dotsteward" --instance "$up_inst" rebuild --profile workstation --switch </dev/null >/dev/null 2>&1 ||
  ds_fail "the rebuild by hand failed"
assert_eq "$y" "$(active)"
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
clear_log
assert_exit 3 on_terminal -- --tracked
assert_order "^e2e .*root=$up_inst\$" '^rebuild .*root=.*/upgrade/work$' '^e2e .*root=.*/upgrade/work$'
assert_eq "$x" "$(active)" "the generation of X is active again"
assert_json "$marker" ".commit == \"$x\" and .lock_commit == \"$y\""
assert_not_contains "$(jq -c '[.steps[] | select(.name == "e2e") | .status]' "$(newest_report)")" '"ok"'

# --- a lock that moves only what did not go red here is not tried --------------------------------------
publish_lock agent_tools.other.linux 2
clear_log
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_json "$marker" ".lock_commit == \"$y\""
assert_eq "$x" "$(active)"
# The red pin moves: the new lock is tried.
publish_lock agent_tools.codex.linux 2.1.0
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order "^rebuild .*root=$up_inst\$" "^e2e .*root=$up_inst\$"
[[ ! -e $marker ]] || ds_fail "the marker stays after the red pin moved"

# --- nothing to put back (an unpinned component): only a moved path that it watches is tried -----------
publish_lock agent_tools.other.linux 3
y2=$(remote_oid)
printf 'claude-code:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 on_terminal -- --tracked
assert_json "$marker" ".lock_commit == \"$y2\" and (.watch | keys) == [\"agent_tools.other.linux\"]"
publish_lock agent_tools.codex.linux 2.2.0
clear_log
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^rebuild '
assert_no_step '^e2e '
publish_lock agent_tools.other.linux 4
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order "^rebuild .*root=$up_inst\$" "^e2e .*root=$up_inst\$"
[[ ! -e $marker ]] || ds_fail "the marker stays after a watched path moved"

# --- the skills lock is part of the shared lock -------------------------------------------------------
clone=$DS_TEST_ROOT/producer-clone
rm -rf -- "$clone"
git clone -q "$up_bare" "$clone"
mkdir -p "$clone/agent"
jq -n '{schema_version: 1, skills: {"example-skill": {rev: "2222222222222222222222222222222222222222"}}}' \
  >"$clone/agent/skills.lock.json"
git -C "$clone" add -A
git -C "$clone" commit -q -m "chore: update vendored skills"
git -C "$clone" push -q origin HEAD:main
rm -rf -- "$clone"
y3=$(remote_oid)
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
clear_log
assert_exit 3 on_terminal -- --tracked
assert_order "^e2e .*root=$up_inst\$" '^rebuild .*root=.*/upgrade/work$' '^e2e .*root=.*/upgrade/work$'
assert_json "$marker" ".lock_commit == \"$y3\" and (.watch | keys) == [\"agent/skills.lock.json\"]"

# --- this machine becomes the producer: the marker goes -------------------------------------------------
set_toml hosts producer '"example-host"'
git -C "$up_inst" commit -q -am "chore(hosts): this machine is the producer"
git -C "$up_inst" push -q origin HEAD:main
rm -f -- "$UP_CONTROL/e2e-red-once"
on_terminal 'Update these too=n' -- --tracked >/dev/null 2>&1 || true
[[ ! -e $marker ]] || ds_fail "the producer keeps the marker of a consumer"
