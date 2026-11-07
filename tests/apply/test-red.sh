# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# What goes red stops the transaction where it is, and the same command goes on once it is fixed:
# a red gate commits nothing; a red rebuild leaves the commit local and runs no E2E; a red E2E
# never publishes. The fix is a new commit (no amend), and the next apply proves the new tree with
# the gate, activates it and runs E2E again before anything is pushed.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
assert_exit 0 begin

# --- the gate says no: nothing is committed ---------------------------------------------------
edit "a change the gate refuses"
: >"$UP_CONTROL/static-red"
clear_log
assert_exit 1 apply -m "docs: a change" --activate --publish
assert_eq "$base" "$(head_oid)" "nothing was committed"
assert_eq "$base" "$(remote_oid)"
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq failed "$(apply_step gate)"
review_json '[.items[] | select(.command == "apply" and .code == "gate-failed" and (.log | endswith("validate.log")))] | length == 1'
rm -f -- "$UP_CONTROL/static-red"

# --- the rebuild fails: the commit stays local, no E2E ----------------------------------------
: >"$UP_CONTROL/rebuild-fails"
clear_log
assert_exit 1 apply -m "docs: a change" --activate --publish
first=$(head_oid)
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "the change is committed"
assert_eq "$base" "$(remote_oid)" "nothing was published"
assert_order '^static ' '^rebuild '
assert_no_step '^e2e '
assert_eq failed "$(apply_step rebuild)"
assert_eq none "$(apply_step publish)"
review_json '[.items[] | select(.command == "apply" and .code == "rebuild-failed")] | length == 1'
rm -f -- "$UP_CONTROL/rebuild-fails"

# --- the same command again: the gate answers from its memo, the commit is not made twice -------
printf 'example:check\n' >"$UP_CONTROL/e2e-red"
clear_log
assert_exit 1 apply --activate --publish
assert_eq "$first" "$(head_oid)" "no second commit"
assert_eq "$base" "$(remote_oid)" "a red E2E publishes nothing"
assert_order "^rebuild .*root=$up_inst\$" '^e2e '
assert_eq failed "$(apply_step e2e)"
apply_report '[.steps[] | select(.name == "e2e") | .findings] == [["example:check"]]'
review_json '[.items[] | select(.command == "apply" and .code == "e2e-red" and .findings == ["example:check"])] | length == 1'
review_json '[.items[] | select(.code == "e2e-red") | .run] | first | contains("dotsteward apply")'
rm -f -- "$UP_CONTROL/e2e-red"

# --- the fix: a new commit, the gate again, the rebuild, E2E again, then the push --------------
edit "the fix"
clear_log
assert_exit 0 apply -m "fix: the check" --activate --publish
assert_order '^static ' "^rebuild .*root=$up_inst\$" "^e2e .*--expected-remote-base $base"
assert_eq "$first" "$(git -C "$up_inst" rev-parse HEAD^)" "the fix is a new commit on the first"
assert_eq "$(head_oid)" "$(remote_oid)" "both commits are published"
assert_eq "docs: a change" "$(git -C "$up_inst" log -1 --format=%s HEAD^)"
assert_eq "fix: the check" "$(git -C "$up_inst" log -1 --format=%s HEAD)"
# Green, apply leaves nothing in review.json.
if [[ -e $DOTSTEWARD_STATE_ROOT/review.json ]]; then
  review_json '[.items[] | select(.command == "apply")] | length == 0'
fi
