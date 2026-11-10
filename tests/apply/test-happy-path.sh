# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A maintain transaction in two commands: `maintain begin` opens it on the published tip, the agent
# edits, and `apply` stages, generates the mirrors into the same commit, gates, commits with the
# trace line of this machine, activates the
# committed tree, runs E2E against the base and publishes, in this order and only through the
# real gate and the real txn publish. Its report names every step with its seconds. A second run
# has nothing left to do: no gate step, no rebuild, no E2E, no push.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
assert_exit 0 begin --json
assert_stdout_json ".base_oid == \"$base\" and .open == true and .ask == []"
assert_stdout_json '.profile == "workstation" and .machine == "example-host"'
assert_json "$DOTSTEWARD_STATE_ROOT/update/candidate.json" '.scope == "maintain"'

edit "a change of the transaction"
printf 'notes\n' >"$up_inst/docs/new-page.md"
clear_log
assert_exit 0 apply -m "docs: explain the guide" --activate --publish
output=$DS_STDOUT

# The order is fixed: the gate before the commit, the rebuild of the committed tree from the
# checkout, E2E against the base, then the push.
assert_order "^generate  root=$up_inst\$" '^static ' "^rebuild --profile workstation --switch root=$up_inst\$" \
  "^e2e --profile workstation .*--expected-remote-base $base( |.*)root=$up_inst\$"
assert_no_step '^install '

head=$(head_oid)
assert_eq "$head" "$(remote_oid)" "the commit is published"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "one commit on the base"
assert_eq "docs: explain the guide" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "example-host" "$(machine_trailer HEAD)" "the trace line names this machine"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
assert_eq "notes" "$(git -C "$up_inst" show HEAD:docs/new-page.md)" "an untracked file of the change is staged"
derived_current HEAD
assert_json "$DOTSTEWARD_STATE_ROOT/current/activation.json" ".tree_oid == \"$(head_tree)\""
assert_contains "$output" "published"

apply_report '.command == "apply" and .status == "ok" and .exit_code == 0'
apply_report ".data.commit == \"$head\" and .data.base == \"$base\""
apply_report '.data.profile == "workstation" and .data.activate == true and .data.publish == true'
apply_report '[.steps[].name] == ["stage", "generate", "gate", "commit", "rebuild", "e2e", "publish", "state"]'
apply_report '[.steps[] | select(.status == "ok" and (.seconds | type) == "number")] | length == 8'

# Again: nothing to apply. --json prints the report, and nothing else, on standard output.
clear_log
assert_exit 0 apply --activate --publish --json
assert_stdout_json '.command == "apply" and .status == "ok"'
assert_stdout_json '[.steps[] | [.name, .detail]] == [["stage", "nothing to apply"]]'
assert_no_step '^generate '
assert_no_step '^static '
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$head" "$(remote_oid)"
assert_eq "$head" "$(head_oid)" "no second commit"

# A new transaction starts from the new tip.
assert_exit 0 begin --json
assert_stdout_json ".base_oid == \"$head\""
