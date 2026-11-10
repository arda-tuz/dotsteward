# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# A move of the flake inputs whose way back is red too holds nothing (the move is not what broke the
# machine), so without a pause every run would move them again, with a heavy rebuild and a rebuild
# back each time. Such a run pauses the flake inputs for a day; every other pin still moves.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
week=$DOTSTEWARD_STATE_ROOT/upgrade/nix-week.json

move flake_inputs.nixpkgs a channel
printf 'core:managed-links\n' >"$UP_CONTROL/e2e-red"
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/e2e-red"
[[ -e $week ]] || ds_fail "a red way back does not pause the flake inputs"
[[ ! -e $DOTSTEWARD_STATE_ROOT/holds.json ]] || assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '.holds | length == 0'
# A day, not a week: the time that is left is under a day and over a day less than a week.
left=$(jq --argjson now "$(date +%s)" '.moved_at + 604800 - $now' "$week")
python3 -c 'import sys; left = float(sys.argv[1]); sys.exit(0 if 82800 < left <= 86401 else 1)' "$left" ||
  ds_fail "the pause is not a day: $left seconds left"

# The next run leaves the flake inputs and moves the rest.
clear_log
move agent_tools.codex.linux 2.0.0 download
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip flake_inputs.*"
assert_eq 2.0.0 "$(jq -r '."agent_tools.codex.linux"' "$up_inst/versions.lock.json")"
