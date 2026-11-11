# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the gate hooks run later and are single-quoted on purpose
# The red path as a transaction: a hold goes to the machine layer, hosts/<name>.toml, in a commit of
# its own that `upgrade` publishes apart from the commit of the pins, after it, so the publish of
# the pins never races its own hold. Another machine pulls it and its run says what is held, where
# and why. `upgrade --retry-held` takes the holds of this machine back in a publish of its own before
# the writer runs, so the held pins move again in the same run. A hold of an older release, kept
# only in <state>/holds.json, reaches the host file with the next run.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho old\n' >"$HOME/.local/bin/codex"
printf '#!/bin/sh\necho old helper\n' >"$HOME/.local/bin/codex-helper"
chmod 0755 "$HOME/.local/bin/codex" "$HOME/.local/bin/codex-helper"

# Two machines, so the producer is named.
set_toml hosts producer '"example-host"'
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): example-host produces the pins"
git -C "$up_inst" push -q origin HEAD:main

# remote_holds: the holds of a host file on the remote, as JSON.
remote_holds() {
  git -C "$up_bare" show "main:hosts/$1.toml" |
    python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read()).get("holds", {}), sort_keys=True))'
}
# first_since COMMIT: the oldest commit of main after COMMIT (the whole list is read: no SIGPIPE).
first_since() {
  git -C "$up_bare" rev-list --reverse "$1..main" | sed -n 1p
}
# files_of COMMIT: the paths a commit of the remote changed.
files_of() {
  git -C "$up_bare" show --format= --name-only "$1"
}
gate_red_when() {
  printf 'if jq -e %q "$DOTSTEWARD_INSTANCE/versions.lock.json" >/dev/null; then : >%q; else rm -f -- %q; fi\n' \
    "$1" "$UP_CONTROL/static-red" "$UP_CONTROL/static-red" >"$UP_CONTROL/during-gate"
}

# --- E2E is red after a move: the hold is published alone, in the host file ---------------------
move agent_tools.codex.linux 2.0.0 download
move example.other 3.0.0 pypi
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - '."agent_tools.codex.linux" | .version == "2.0.0" and (.reason | contains("codex:version")) and (.since | test("^2[0-9-]+T[0-9:]+Z$"))'
remote_holds example-host | assert_json - 'keys == ["agent_tools.codex.linux"]'
assert_eq "chore(hosts): holds on example-host" "$(git -C "$up_bare" log -1 --format=%s main)"
assert_eq "hosts/example-host.toml" "$(files_of main)" "the hold commit holds the host file alone"
assert_contains "$(git -C "$up_bare" log -1 --format=%B main)" "Dotsteward-Machine: example-host"
assert_eq "null" "$(git -C "$up_bare" show main:versions.lock.json | jq -c '."agent_tools.codex.linux" // null')"
assert_eq "null" "$(git -C "$up_bare" show main:versions.lock.json | jq -c '."example.other" // null')"
assert_eq "$(git -C "$up_bare" rev-parse main^)" "$(git -C "$up_inst" rev-parse HEAD)" \
  "the checkout stays on the tree it rebuilt; the next run takes the hold commit"
review_json '[.items[] | select(.code == "red-held" and .id == "agent_tools.codex.linux")] | length == 1'
last_report '[.steps[] | select(.name == "hold-publish")] | last | .status == "ok"'
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[] | select(.published == true) | .id] == ["agent_tools.codex.linux"]'

# --- another machine pulls it and says what is held, where and why --------------------------------
other=$DS_TEST_ROOT/machine-b
other_state=$DS_TEST_ROOT/state-b
git clone -q "$up_bare" "$other"
git -C "$other" remote set-url origin "$UP_REMOTE"
git -C "$other" config user.name dotsteward-test
git -C "$other" config user.email dotsteward-test@example.invalid
DOTSTEWARD_STATE_ROOT=$other_state name_machine laptop-b
clear_log
assert_exit 3 env DOTSTEWARD_STATE_ROOT="$other_state" "$fw/cli/dotsteward" --instance "$other" upgrade --tracked </dev/null
assert_contains "$DS_STDOUT" "agent_tools.codex.linux"
assert_contains "$DS_STDOUT" "example-host"
assert_contains "$DS_STDOUT" "codex:version"
assert_json "$other_state/review.json" '[.items[] | select(.code == "held" and .id == "agent_tools.codex.linux" and .machine == "example-host" and .version == "2.0.0" and (.reason | contains("codex:version")))] | length == 1'
assert_no_step '^pins .*apply'
[[ ! -e $other_state/holds.json ]] || assert_json "$other_state/holds.json" '.holds | length == 0'
remote_holds laptop-b | assert_json - '. == {}'

# --- the producer once more: the writer leaves the held pin, the other one moves -------------------
clear_log
printf '{"items": [{"id": "agent_tools.codex.linux", "latest": "2.0.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
assert_eq 3.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '."example.other"')"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
remote_holds example-host | assert_json - 'keys == ["agent_tools.codex.linux"]'

# --- --retry-held: the release goes out alone, before the writer, and the pin moves ---------------
clear_log
before=$(remote_oid)
assert_exit 3 upgrade --tracked --retry-held
assert_not_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"
assert_eq 2.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '."agent_tools.codex.linux"')"
remote_holds example-host | assert_json - '. == {}'
release=$(first_since "$before")
assert_eq "chore(hosts): holds on example-host" "$(git -C "$up_bare" log -1 --format=%s "$release")"
assert_eq "hosts/example-host.toml" "$(files_of "$release")"
assert_contains "$(files_of main)" "versions.lock.json"
assert_not_contains "$(files_of main)" "hosts/"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "held")] | length == 0'

# The other machine sees it is over.
clear_log
assert_exit 3 env DOTSTEWARD_STATE_ROOT="$other_state" "$fw/cli/dotsteward" --instance "$other" upgrade --tracked </dev/null
assert_json "$other_state/review.json" '[.items[] | select(.code == "held")] | length == 0'

# --- a red gate holds one group: the pins go out, the hold after them, in two commits -------------
clear_log
rm -f -- "$UP_CONTROL/moves" "$UP_CONTROL/latest-rows"
move example.broken 2.0 pypi:broken
move example.fine 1.1 npm:fine
gate_red_when '."example.broken" == "2.0"'
before=$(remote_oid)
assert_exit 3 upgrade --tracked
rm -f -- "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"
pins_commit=$(first_since "$before")
assert_eq 2 "$(git -C "$up_bare" rev-list --count "$before..main")" "the pins and the hold, one commit each"
assert_contains "$(files_of "$pins_commit")" "versions.lock.json"
assert_not_contains "$(files_of "$pins_commit")" "hosts/"
assert_eq "hosts/example-host.toml" "$(files_of main)"
assert_eq "1.1 null" "$(git -C "$up_bare" show main:versions.lock.json | jq -r '[."example.fine", ."example.broken"] | map(. // "null") | join(" ")')"
remote_holds example-host | assert_json - '."example.broken" | .version == "2.0" and (.reason | contains("pypi:broken"))'
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)" "the checkout follows both"

# --- while the commit of the pins waits, its hold waits too: that commit goes out as it is ---------
clear_log
rm -f -- "$UP_CONTROL/moves"
move example.broken3 2.0 pypi:broken3
move example.fine3 1.1 npm:fine3
gate_red_when '."example.broken3" == "2.0"'
printf '137\n' >"$UP_CONTROL/rebuild-status"
before=$(remote_oid)
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/rebuild-status" "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"
waiting=$(waiting_commit)
[[ -n $waiting ]] || ds_fail "no commit waits"
assert_eq "$before" "$(remote_oid)" "nothing went out, the hold neither"
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[] | select(.id == "example.broken3") | .published != true] == [true]'
clear_log
assert_exit 3 upgrade --tracked
assert_eq "" "$(steps '^pins .*apply')" "the waiting commit goes out as it is: the writer does not run again"
assert_eq 2 "$(git -C "$up_bare" rev-list --count "$before..main")" "the pins, then the hold"
assert_eq "$(git -C "$up_inst" rev-parse "$waiting^{tree}")" "$(git -C "$up_bare" rev-parse "main^^{tree}")"
assert_eq "hosts/example-host.toml" "$(files_of main)"
remote_holds example-host | assert_json - '."example.broken3".version == "2.0"'
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# --- a hold of an older release, only in holds.json, reaches the host file -------------------------
clear_log
rm -f -- "$UP_CONTROL/moves"
jq -n '{schema_version: 1, holds: [{component: "example", id: "example.legacy", version: "9.0", reason: "E2E red: example:legacy", since: "2026-01-01T00:00:00Z"}]}' \
  >"$DOTSTEWARD_STATE_ROOT/holds.json"
chmod 0600 "$DOTSTEWARD_STATE_ROOT/holds.json"
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - '."example.legacy" | .version == "9.0" and .reason == "E2E red: example:legacy"'
remote_holds example-host | assert_json - 'has("example.broken")'
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[] | select(.id == "example.legacy") | .published] == [true]'

# --- a hold the owner takes out of the host file by hand stays out ---------------------------------
git -C "$up_inst" pull -q --ff-only origin main
host_file=$up_inst/hosts/example-host.toml
awk '/^\[/ { skip = ($0 == "[holds.\"example.legacy\"]") } !skip' "$host_file" >"$host_file.new"
mv -- "$host_file.new" "$host_file"
assert_not_contains "$(<"$host_file")" "example.legacy"
git -C "$up_inst" commit -q -am "chore(hosts): the legacy hold is over"
git -C "$up_inst" push -q origin HEAD:main
clear_log
assert_exit 3 upgrade --tracked
remote_holds example-host | assert_json - 'has("example.legacy") | not'
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[] | select(.id == "example.legacy")] | length == 0'
