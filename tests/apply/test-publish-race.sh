# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The remote moves while apply runs: another machine, or a skill capture of this one. apply moves
# its commit onto the new tip by itself, proves and activates the combined tree and publishes, also
# in a checkout without an upstream branch. When the other side changed the same lines, the
# commits stay here and review.json names the command that takes the remote in, which works
# without an upstream; then the same apply proves the combined tree and publishes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

git -C "$up_inst" branch --unset-upstream 2>/dev/null || true

# capture_once FILE TEXT: a skill capture of this machine pushes FILE while the rebuild runs, once.
capture_once() {
  rm -f -- "$UP_CONTROL/raced"
  cat >"$UP_CONTROL/rebuild-status-hook" <<HOOK
if [[ ! -e \$UP_CONTROL/raced ]]; then
  : >"\$UP_CONTROL/raced"
  clone=\$(mktemp -d)
  git clone -q "$up_bare" "\$clone/c"
  printf '%s\n' "$2" >>"\$clone/c/$1"
  git -C "\$clone/c" add -A
  git -C "\$clone/c" -c user.name=x -c user.email=x@example.invalid commit -qm "chore(skills): capture s"
  git -C "\$clone/c" push -q origin HEAD:main
  rm -rf -- "\$clone"
fi
HOOK
}

# --- the remote moved once: the commit moves onto it ----------------------------------------------

assert_exit 0 begin
edit "raced"
capture_once skill.md s
assert_exit 0 apply -m "docs: raced" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "s" "$(git -C "$up_inst" show HEAD:skill.md)"
assert_eq "chore(skills): capture s" "$(git -C "$up_inst" log -1 --format=%s HEAD^)"
apply_report '[.steps[] | select(.name == "replay")] | length == 1'
assert_json "$DOTSTEWARD_STATE_ROOT/current/activation.json" ".tree_oid == \"$(head_tree)\""

# --- the same lines: the command of the item takes the remote in without an upstream -------------

edit "this machine's line"
capture_once docs/guide.md "the capture's line"
assert_exit 3 apply -m "docs: the same lines" --activate --publish
review_json '[.items[] | select(.command == "apply" and .code == "publish-conflict")] | length == 1'
review_json '[.items[] | select(.code == "publish-conflict") | .paths] | first == ["docs/guide.md"]'
command=$(jq -r '[.items[] | select(.code == "publish-conflict") | .run] | first' "$DOTSTEWARD_STATE_ROOT/review.json")
assert_eq "git -C $up_inst pull --rebase origin main && dotsteward apply --activate --publish" "$command"

# The first half of the command works without an upstream and stops at the lines; the person keeps
# both; the rest is the same apply.
assert_exit 1 git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid pull -q --rebase origin main
assert_not_contains "$DS_STDERR" "no tracking information"
{
  git -C "$up_inst" show origin/main:docs/guide.md
  printf 'line %s\n' "this machine's line"
} >"$DS_TEST_ROOT/guide.md"
mv -- "$DS_TEST_ROOT/guide.md" "$up_inst/docs/guide.md"
git -C "$up_inst" add docs/guide.md
assert_exit 0 env GIT_EDITOR=true git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid \
  rebase --continue
clear_log
assert_exit 0 apply -m "chore: generate the mirrors" --activate --publish
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"
assert_contains "$(git -C "$up_inst" show HEAD:docs/guide.md)" "the capture's line"
assert_contains "$(git -C "$up_inst" show HEAD:docs/guide.md)" "this machine's line"
derived_current HEAD
