# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The week of the flake inputs (N14) starts when a move of a flake input is published, not when the
# writer moves one: after a red gate or a red E2E nothing went out, so the next run may move the
# flake inputs again at once (here with --retry-held, as a person would after a fix).
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
week=$DOTSTEWARD_STATE_ROOT/upgrade/nix-week.json

# A red gate: nothing committed, no week.
move flake_inputs.nixpkgs a channel
: >"$UP_CONTROL/static-red"
assert_exit 1 upgrade --tracked
rm -f -- "$UP_CONTROL/static-red"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
[[ ! -e $week ]] || ds_fail "a red gate started the week of the flake inputs"

# A red E2E: the way back, no week.
clear_log
printf 'core:managed-links\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked --retry-held
assert_not_contains "$(steps '^pins .*apply')" "--skip flake_inputs.*"
assert_eq "" "$(waiting_commit)"
[[ ! -e $week ]] || ds_fail "a red E2E started the week of the flake inputs"

# Green and published: now the week starts.
clear_log
assert_exit 3 upgrade --tracked --retry-held
assert_not_contains "$(steps '^pins .*apply')" "--skip flake_inputs.*"
assert_eq a "$(jq -r '."flake_inputs.nixpkgs"' "$up_inst/versions.lock.json")"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
[[ -e $week ]] || ds_fail "a published move of a flake input starts the week"

# A commit that waited for the network starts it when it goes out on a later run.
rm -f -- "$week"
clear_log
move flake_inputs.home-manager b channel
: >"$UP_CONTROL/drop-network-after-e2e"
upgrade --tracked >/dev/null || true
rm -f -- "$UP_CONTROL/drop-network-after-e2e" "$UP_CONTROL/network-down"
[[ -n $(waiting_commit) ]] || ds_fail "the commit does not wait for the network"
[[ ! -e $week ]] || ds_fail "an unpublished commit started the week"
clear_log
assert_exit 3 upgrade --tracked
assert_eq "" "$(waiting_commit)"
assert_eq b "$(git -C "$up_bare" show refs/heads/main:versions.lock.json | jq -r '."flake_inputs.home-manager"')"
[[ -e $week ]] || ds_fail "the commit that went out later starts the week"
