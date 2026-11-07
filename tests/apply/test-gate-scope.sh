# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A gate of the same tree in the update scope (a plain `dotsteward gate`) does not answer the gate
# of apply, which txn publish needs in the maintain scope: apply proves the tree again in its own
# scope and publishes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

assert_exit 0 begin
jq '.note = "x"' "$up_inst/versions.lock.json" >"$up_inst/versions.new"
mv -- "$up_inst/versions.new" "$up_inst/versions.lock.json"
git -C "$up_inst" add -A
assert_exit 0 "$fw/cli/dotsteward" --instance "$up_inst" gate
assert_json "$DOTSTEWARD_STATE_ROOT/update/validation.json" '.scope == "update"'

clear_log
assert_exit 0 apply -m "chore: a note in the lock" --activate --publish
assert_order '^static ' '^rebuild ' '^e2e '
assert_json "$DOTSTEWARD_STATE_ROOT/update/validation.json" '.scope == "maintain"'
assert_eq "$(head_oid)" "$(remote_oid)"
