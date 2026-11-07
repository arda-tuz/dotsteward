# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The producer steps: who runs them, the week of the flake inputs (N14), Codex and other pins every
# run, the second run of a moved framework with its own CLI, the gate that says no, and a dirty or
# foreign checkout.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
week=$DOTSTEWARD_STATE_ROOT/upgrade/nix-week.json

# --- the week -------------------------------------------------------------------------------------
move flake_inputs.nixpkgs a channel
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip"
[[ -e $week ]] || ds_fail "a moved flake input starts the week"
assert_eq a "$(jq -r '."flake_inputs.nixpkgs"' "$up_inst/versions.lock.json")"

# Inside the week: flake inputs wait, a Codex release does not.
clear_log
move flake_inputs.nixpkgs b channel
jq 'map(if .id == "flake_inputs.nixpkgs" then .to = "b" else . end) | unique_by(.id)' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
move agent_tools.codex.linux 2.0.0 download
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip flake_inputs.*"
assert_eq a "$(jq -r '."flake_inputs.nixpkgs"' "$up_inst/versions.lock.json")"
assert_eq 2.0.0 "$(jq -r '."agent_tools.codex.linux"' "$up_inst/versions.lock.json")"
assert_order '^pins .*apply' '^rebuild ' '^e2e '
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# The week is over.
clear_log
jq '.moved_at = 1' "$week" >"$week.new"
mv -- "$week.new" "$week"
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip"
assert_eq b "$(jq -r '."flake_inputs.nixpkgs"' "$up_inst/versions.lock.json")"

# --- an upstream without an answer holds back only its own rows ---------------------------------------
clear_log
printf '1\n' >"$UP_CONTROL/latest-status"
assert_exit 3 upgrade --tracked
assert_order '^pins latest' '^pins .*apply'
printf '2\n' >"$UP_CONTROL/latest-status"
clear_log
assert_exit 1 upgrade --tracked
assert_no_step '^pins .*apply'
assert_eq failed "$(step_status pins-latest)"
rm -f -- "$UP_CONTROL/latest-status"

# --- nothing moved: no gate, no commit ---------------------------------------------------------------
clear_log
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 3 upgrade --tracked
assert_no_step '^static '
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"

# --- review items of the writer wait with their own command -------------------------------------------
printf '3\n' >"$UP_CONTROL/pins-status"
assert_exit 3 upgrade --tracked
rm -f -- "$UP_CONTROL/pins-status"

# --- M3: a group that failed: named, the others go on ------------------------------------------------
clear_log
move example.failing 1.0 npm
printf '1\n' >"$UP_CONTROL/pins-status"
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/pins-status"
assert_eq failed "$(step_status pins-apply)"
review_json '[.items[] | select(.code == "pins-group-failed" and .ids == ["example.broken"])] | length == 1'
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq 1.0 "$(jq -r '."example.failing"' "$up_inst/versions.lock.json")"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
work_gone

# A writer that gives no answer leaves nothing: the clone goes.
clear_log
move example.silent 1.0 npm
printf 'garbage\n' >"$UP_CONTROL/pins-garbage"
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/pins-garbage"
assert_no_step '^static '
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
work_gone
jq 'map(select(.id != "example.silent"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"

# --- the gate says no: no commit, the checkout untouched, M2: the pins hold so the others can pass -------
clear_log
: >"$UP_CONTROL/static-red"
move example.bad 2.0 pypi
printf '{"items": [{"id": "example.bad", "latest": "2.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 1 upgrade --tracked
output=$DS_STDOUT
assert_eq failed "$(step_status gate)"
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
review_json '[.items[] | select(.code == "gate-failed")] | length == 1'
review_json '[.items[] | select(.code == "red-held" and .id == "example.bad")] | length == 1'
assert_contains "$output" "validate.log"
assert_no_step '^rebuild '
work_gone
rm -f -- "$UP_CONTROL/static-red"
clear_log
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip example.bad"
assert_eq "null" "$(jq -c '."example.bad" // null' "$up_inst/versions.lock.json")"
jq 'map(select(.id != "example.bad"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
rm -f -- "$UP_CONTROL/latest-rows"

# --- M4: the remote refuses the commit: said, and the next run is not stuck on it -------------------------
clear_log
move example.refused 1.0 pypi
cat >"$up_bare/hooks/pre-receive" <<HOOK
#!$BASH
printf 'a hook of the remote says no\n' >&2
exit 1
HOOK
chmod 0755 "$up_bare/hooks/pre-receive"
assert_exit 1 upgrade --tracked
review_json '[.items[] | select(.code == "publish-refused")] | length == 1'
assert_eq "" "$(waiting_commit)"
assert_eq "null" "$(jq -c '."example.refused" // null' "$up_inst/versions.lock.json")"
work_gone
rm -f -- "$up_bare/hooks/pre-receive"
clear_log
assert_exit 3 upgrade --tracked
assert_eq 1.0 "$(jq -r '."example.refused"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# --- a framework that moved: the writer once more, with its own CLI, and the rest there too -------------
clear_log
move framework 2.0.0 framework
cat >"$up_inst/.dotsteward/cli.sh" <<LAUNCHER
#!$BASH
printf 'launcher %s\n' "\$*" >>"$UP_LOG"
exec "$fw/cli/dotsteward" --instance "\$(cd "\$(dirname "\$0")/.." && pwd)" "\$@"
LAUNCHER
chmod 0755 "$up_inst/.dotsteward/cli.sh"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the launcher"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 3 upgrade --tracked
assert_order '^pins .*apply' '^launcher pins .*apply' '^launcher gate' '^launcher rebuild' '^launcher e2e' '^launcher txn publish' '^launcher rebuild'
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# --- a dirty checkout stays as it is: pins still move and publish, it does not follow --------------------
clear_log
move example.while-dirty 1.0 pypi
printf 'a note\n' >>"$up_inst/docs/guide.md"
tracked_dirt=$(sha256sum "$up_inst/docs/guide.md")
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
output=$DS_STDOUT
assert_order '^apt commit' '^pins .*apply' '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work'
assert_eq "$tracked_dirt" "$(sha256sum "$up_inst/docs/guide.md")"
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"
[[ $(remote_oid) != "$head_before" ]] || ds_fail "the commit did not go out"
review_json '[.items[] | select(.code == "checkout-dirty")] | length == 1'
review_json '[.items[] | select(.code == "checkout-behind")] | length == 1'
assert_contains "$output" "pull --ff-only"
assert_not_contains "$(git -C "$up_inst" log -p "$(remote_oid)" -n 1 --format=%s)" "a note"
git -C "$up_inst" checkout -q -- docs/guide.md

# Clean again: the next run fast-forwards, and takes the records of the machine back.
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_order "^rebuild .*root=$up_inst\$"

# --- a commit that is not upgrade's: refused, as in v2 ------------------------------------------------------
clear_log
change_and_commit "feat: a local change"
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDERR" "not published"
assert_no_step '^(apt|pins|rebuild|e2e)'
git -C "$up_inst" reset -q --hard HEAD~1
[[ $(git -C "$up_inst" log -1 --format=%s) != "feat: a local change" ]] || ds_fail "test setup"

# --- another machine is the producer -------------------------------------------------------------------------
clear_log
mkdir -p "$up_inst/hosts"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"other-host"'
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): make other-host the producer"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 upgrade --plan --json
assert_stdout_json '.producer == "other-host"'
clear_log
assert_exit 3 upgrade --tracked
assert_no_step '^pins '
assert_contains "$DS_STDOUT" "other-host"
assert_order '^rebuild |^e2e '

# Two machines and no producer: nobody moves pins, the command is named.
clear_log
set_toml hosts producer '""'
python3 - "$up_inst/workstation.toml" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r'^producer = ""\n', "", text, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): no producer"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 3 upgrade --tracked
assert_no_step '^pins '
review_json '[.items[] | select(.code == "producer-unset" and (.run | contains("host producer")))] | length == 1'
