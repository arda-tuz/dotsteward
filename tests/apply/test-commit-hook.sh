# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A commit hook of the checkout that changes the staged tree: the commit is not the tree the gate
# proved, so apply takes back the commit it just made (the changes stay staged) and says so; no
# unproven commit stays. The same apply then proves the tree with the hook's change and publishes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
assert_exit 0 begin
edit "a change"
cat >"$up_inst/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
[ -e "$UP_CONTROL/hooked" ] && exit 0
: >"$UP_CONTROL/hooked"
printf 'added by a hook\n' >>docs/guide.md && git add docs/guide.md
HOOK
chmod 0755 "$up_inst/.git/hooks/pre-commit"

clear_log
assert_exit 1 apply -m "docs: hooked" --activate --publish
assert_eq "$base" "$(head_oid)" "no unproven commit stays"
assert_no_step '^rebuild '
review_json '[.items[] | select(.command == "apply" and .code == "tree-changed")] | length == 1'
assert_contains "$(git -C "$up_inst" diff --cached)" "added by a hook"

clear_log
assert_exit 0 apply -m "docs: hooked" --activate --publish
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)"
assert_contains "$(git -C "$up_inst" show HEAD:docs/guide.md)" "added by a hook"
