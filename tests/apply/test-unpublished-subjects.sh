# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# An unpublished commit whose subject is not a conventional commit can never be published by txn
# publish. begin names it with the way out, and apply refuses before it stages, gates or activates
# anything, with the same way out in review.json: fold the unpublished commits into the change of
# the transaction (git reset --soft to the tip keeps every file), then apply with a subject.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
printf 'wip\n' >>"$up_inst/docs/guide.md"
git -C "$up_inst" commit -qam "wip"
wip=$(head_oid)

assert_exit 3 begin --json
assert_stdout_json "[.ask[] | select(.code == \"nonconventional-commits\") | .commits] == [[\"$wip\"]]"
assert_stdout_json "[.ask[] | select(.code == \"nonconventional-commits\") | .run] == [\"git -C $up_inst reset --soft $base\"]"

edit "a change"
clear_log
assert_exit 1 apply -m "docs: a change" --activate --publish
assert_contains "$DS_STDERR" "wip"
assert_contains "$DS_STDERR" "reset --soft $base"
assert_no_step '^static '
assert_no_step '^rebuild '
assert_eq " M docs/guide.md" "$(git -C "$up_inst" status --porcelain)" "nothing was staged"
assert_eq "$wip" "$(head_oid)"
review_json "[.items[] | select(.command == \"apply\" and .code == \"nonconventional-commits\" and .commits == [\"$wip\"]
  and .run == \"git -C $up_inst reset --soft $base\")] | length == 1"

# The way out: one commit with a conventional subject, published.
git -C "$up_inst" reset -q --soft "$base"
clear_log
assert_exit 0 apply -m "docs: a change" --activate --publish
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)"
assert_eq "$(head_oid)" "$(remote_oid)"
assert_contains "$(git -C "$up_inst" show HEAD:docs/guide.md)" "wip"
