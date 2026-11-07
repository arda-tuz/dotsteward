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

# --- a writer that fails leaves nothing ------------------------------------------------------------------
clear_log
move example.failing 1.0 npm
printf '1\n' >"$UP_CONTROL/pins-status"
assert_exit 1 upgrade --tracked
assert_eq failed "$(step_status pins-apply)"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the tree of a failed writer goes"
assert_no_step '^static '
rm -f -- "$UP_CONTROL/pins-status"

# --- the gate says no: no commit, the tree goes, the run goes on with what is there ----------------------
clear_log
: >"$UP_CONTROL/static-red"
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 1 upgrade --tracked
assert_eq failed "$(step_status gate)"
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
review_json '[.items[] | select(.code == "gate-failed")] | length == 1'
assert_no_step '^rebuild '
rm -f -- "$UP_CONTROL/static-red"
jq 'map(select(.id != "example.failing"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"

# --- a framework that moved: the writer once more, with its own CLI, and the rest there too -------------
clear_log
move framework 2.0.0 framework
cat >"$up_inst/.dotsteward/cli.sh" <<LAUNCHER
#!$BASH
printf 'launcher %s\n' "\$*" >>"$UP_LOG"
exec "$fw/cli/dotsteward" --instance "$up_inst" "\$@"
LAUNCHER
chmod 0755 "$up_inst/.dotsteward/cli.sh"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the launcher"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 3 upgrade --tracked
assert_order '^pins .*apply' '^launcher pins .*apply' '^launcher gate' '^launcher rebuild' '^launcher e2e' '^launcher txn publish'
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# --- a dirty checkout: the repository waits, apt does not ---------------------------------------------------
clear_log
printf 'a note\n' >>"$up_inst/docs/guide.md"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_order '^apt commit' '^e2e .*--skip-repo-checks'
assert_no_step '^pins '
assert_no_step '^rebuild '
review_json '[.items[] | select(.code == "checkout-dirty")] | length == 1'
git -C "$up_inst" checkout -q -- docs/guide.md

# --- a commit that is not upgrade's: refused, as in v2 ------------------------------------------------------
clear_log
change_and_commit "feat: a local change"
assert_exit 1 upgrade --tracked
assert_contains "$DS_STDERR" "not published"
assert_no_step '^(apt|pins|rebuild|e2e)'
git -C "$up_inst" reset -q --hard HEAD~1

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
