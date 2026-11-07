# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# `dotsteward maintain begin` is the start of a maintain transaction in one command: the checkout
# guards, the read-only preflight of the current profile, txn prepare in the maintain scope and the
# settings status. It fast-forwards a checkout that is only behind, refuses a diverged one, and
# lists what the agent must put to the user before writing (exit 3): uncommitted changes, commits
# that are not published, settings entries that wait, the adaptive route. --json prints one
# document on standard output.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)

# Clean and on the tip.
clear_log
assert_exit 0 begin --json
document=$DS_STDOUT
assert_stdout_json ".open == true and .base_oid == \"$base\" and .ask == [] and .dirty == []"
assert_stdout_json ".instance.path == \"$up_inst\" and .instance.branch == \"main\""
assert_stdout_json '.preflight.route == "fast" and .profile == "workstation"'
assert_stdout_json '.activate == false and .publish == false'
assert_stdout_json '.next | contains("dotsteward apply")'
assert_order '^preflight --read-only --json --profile workstation' '^settings status --json'
assert_json "$DOTSTEWARD_STATE_ROOT/update/candidate.json" ".base_oid == \"$base\" and .scope == \"maintain\""
assert_not_contains "$document" "[dotsteward]"

# Without --json: lines for a person.
assert_exit 0 begin
assert_contains "$DS_STDOUT" "$base"

# Uncommitted changes: open, and a question.
edit "uncommitted"
assert_exit 3 begin --json
assert_stdout_json '.open == true and .dirty == [" M docs/guide.md"]'
assert_stdout_json '[.ask[].code] == ["checkout-dirty"]'
git -C "$up_inst" checkout -q -- docs/guide.md

# Settings that wait for a decision.
printf '%s\n' '{"schema_version": 1, "entries": [{"id": "editor", "state": "local-changed", "needs_decision": false},
  {"id": "shell", "state": "in-sync", "needs_decision": false}]}' >"$UP_CONTROL/settings.json"
assert_exit 3 begin --json
assert_stdout_json '[.ask[] | select(.code == "settings-local") | .entries] == [["editor"]]'
rm -f -- "$UP_CONTROL/settings.json"

# The adaptive route: nothing opened.
: >"$UP_CONTROL/preflight-adaptive"
rm -f -- "$DOTSTEWARD_STATE_ROOT/update/candidate.json"
assert_exit 3 begin --json
assert_stdout_json '.open == false and .preflight.route == "adaptive" and ([.ask[].code] | index("adaptive-route") != null)'
[[ ! -e $DOTSTEWARD_STATE_ROOT/update/candidate.json ]] || ds_fail "the adaptive route opened a transaction"
rm -f -- "$UP_CONTROL/preflight-adaptive"

# Behind: begin fast-forwards, also with uncommitted changes elsewhere.
push_from_elsewhere "another machine"
printf 'local\n' >"$up_inst/docs/local.md"
assert_exit 3 begin --json
assert_eq "$(remote_oid)" "$(head_oid)" "fast-forwarded"
assert_stdout_json ".base_oid == \"$(remote_oid)\" and .open == true and .dirty == [\"?? docs/local.md\"]"
rm -f -- "$up_inst/docs/local.md"

# Commits that are not published: they belong to the transaction apply finishes, or not.
edit "a local commit"
commit_all "docs: a local commit"
assert_exit 3 begin --json
assert_stdout_json ".open == true and .base_oid == \"$(remote_oid)\""
assert_stdout_json "[.ask[] | select(.code == \"unpublished-commits\") | .commits] == [[\"$(head_oid)\"]]"

# Diverged: refused, nothing moved.
push_from_elsewhere "another machine again"
local_head=$(head_oid)
assert_exit 1 begin --json
assert_eq "$local_head" "$(head_oid)"
assert_contains "$DS_STDERR" "diverged"

# Not the instance checkout.
git -C "$up_inst" reset -q --hard "$(remote_oid)"
git -C "$up_inst" remote set-url origin git@github.com:someone/else.git
assert_exit 1 begin --json
assert_contains "$DS_STDERR" "origin"
git -C "$up_inst" remote set-url origin "$UP_REMOTE"

# Offline: what can be known locally, exit 6, nothing opened.
: >"$UP_CONTROL/network-down"
rm -f -- "$DOTSTEWARD_STATE_ROOT/update/candidate.json"
assert_exit 6 begin --json
assert_stdout_json '.open == false and .offline == true'
rm -f -- "$UP_CONTROL/network-down"

# Usage.
assert_exit 2 "$fw/cli/dotsteward" --instance "$up_inst" maintain
assert_exit 2 "$fw/cli/dotsteward" --instance "$up_inst" maintain finish
