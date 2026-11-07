# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The remote moves while apply runs: another machine, or a skill capture of this one. The commits
# stay here and review.json says what moved and the command that takes the remote in, which works
# in a checkout without an upstream branch; then the same apply proves the combined tree and
# publishes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

git -C "$up_inst" branch --unset-upstream 2>/dev/null || true
assert_exit 0 begin
edit "raced"
cat >"$UP_CONTROL/rebuild-status-hook" <<HOOK
if [[ ! -e \$UP_CONTROL/raced ]]; then
  : >"\$UP_CONTROL/raced"
  clone=\$(mktemp -d)
  git clone -q "$up_bare" "\$clone/c"
  printf 's\n' >"\$clone/c/skill.md"
  git -C "\$clone/c" add -A
  git -C "\$clone/c" -c user.name=x -c user.email=x@example.invalid commit -qm "chore(skills): capture s"
  git -C "\$clone/c" push -q origin HEAD:main
  rm -rf -- "\$clone"
fi
HOOK

assert_exit 3 apply -m "docs: raced" --activate --publish
review_json '[.items[] | select(.command == "apply" and .code == "publish-race")] | length == 1'
review_json '[.items[] | select(.code == "publish-race") | .message] | first | contains("skill capture")'
command=$(jq -r '[.items[] | select(.code == "publish-race") | .run] | first' "$DOTSTEWARD_STATE_ROOT/review.json")
assert_eq "git -C $up_inst pull --rebase origin main && dotsteward apply --activate --publish" "$command"

# The first half of the command works without an upstream; the rest is the same apply.
assert_exit 0 git -C "$up_inst" pull -q --rebase origin main
clear_log
assert_exit 0 apply --activate --publish
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "s" "$(git -C "$up_inst" show HEAD:skill.md)"
