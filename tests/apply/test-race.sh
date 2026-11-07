# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# Two machines and one remote: another machine publishes while this one proves its transaction.
# apply moves the commits of this machine onto the new tip in a clone of its own, takes the
# mirrors of the other side where both changed them and generates them again into the top commit,
# proves the new tree with the gate, activates it and runs E2E against the new base, and pushes
# without force. A change both machines made to the same lines stops it: the commits stay as they
# were, the checkout stays clean with no cherry-pick in it, and review.json says publish-conflict.
# Another machine that keeps publishing ends it after three pushes with publish-race; the same
# command later finishes. A push the remote rejects as no fast-forward is a race too.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

# --- the race is lost while the gate runs: the commit moves onto the new tip ------------------

base=$(remote_oid)
assert_exit 0 begin --json
edit "a change of this machine"
other_machine_during_gate once docs/other-page.md "a page of the other machine"
clear_log
assert_exit 0 apply -m "docs: extend the guide" --activate --publish
head=$(head_oid)
other=$(git -C "$up_inst" rev-parse HEAD^)
assert_eq "$head" "$(remote_oid)" "the commit is published"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD~2)" "one commit of each machine on the base"
assert_eq "docs: a change of the other machine" "$(git -C "$up_inst" log -1 --format=%s "$other")"
assert_eq "docs: extend the guide" "$(git -C "$up_inst" log -1 --format=%s HEAD)"
assert_eq "example-host" "$(machine_trailer HEAD)" "the moved commit keeps its trace line"
assert_contains "$(git -C "$up_inst" show HEAD:docs/guide.md)" "line a change of this machine"
assert_contains "$(git -C "$up_inst" show HEAD:docs/other-page.md)" "a page of the other machine"
# Both commits changed the mirror: the other side's is taken and generated again, in the top commit.
derived_current HEAD
derived_current "$other"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
no_replay_left
assert_json "$DOTSTEWARD_STATE_ROOT/current/activation.json" ".tree_oid == \"$(head_tree)\""
assert_order "^generate  root=$up_inst\$" '^static ' "^rebuild --profile workstation --switch root=$up_inst\$" \
  "^e2e .*--expected-remote-base $base( |.*)root=$up_inst\$" "^generate  root=$DOTSTEWARD_STATE_ROOT/apply/replay\$" \
  '^static ' "^rebuild --profile workstation --switch root=$up_inst\$" \
  "^e2e .*--expected-remote-base $other( |.*)root=$up_inst\$"
apply_report '.status == "ok" and .exit_code == 0 and .data.published == true'
apply_report ".data.base == \"$other\" and .data.commit == \"$head\""
apply_report '[.steps[].name] == ["stage", "generate", "gate", "commit", "rebuild", "e2e", "replay", "gate", "rebuild", "e2e", "publish"]'
apply_report '[.steps[] | select(.status != "ok")] == []'

# --- the push is rejected as no fast-forward: a race as well ---------------------------------

base=$(remote_oid)
edit "a change pushed into a race"
cat >"$up_inst/.git/hooks/pre-push" <<HOOK
#!$BASH
rm -f -- "\$0"
bash "$DS_TEST_ROOT/push-elsewhere.sh"
HOOK
chmod 0755 "$up_inst/.git/hooks/pre-push"
other_machine_during_gate once docs/third-page.md "pushed while this one pushes"
mv -- "$UP_CONTROL/during-gate" "$DS_TEST_ROOT/push-elsewhere.sh"
clear_log
assert_exit 0 apply -m "docs: one more line" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)" "the commit is published"
assert_eq "docs: a change of the other machine" "$(git -C "$up_inst" log -1 --format=%s HEAD^)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD~2)"
derived_current HEAD
no_replay_left
apply_report '.status == "ok" and ([.steps[] | select(.name == "replay")] | length) == 1'

# --- both machines changed the same lines: no text is merged ---------------------------------

base=$(remote_oid)
edit "this machine's last line"
other_machine_during_gate once docs/guide.md "the other machine's last line"
clear_log
assert_exit 3 apply -m "docs: the last line" --activate --publish
mine=$(head_oid)
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "the commit stays on its base"
assert_eq "docs: the last line" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
no_replay_left
moved=$(remote_oid)
assert_eq "docs: a change of the other machine" "$(git -C "$up_bare" log -1 --format=%s main)"
review_json '[.items[] | select(.code == "publish-conflict")] | length == 1'
review_json '.items[] | select(.code == "publish-conflict") | .paths == ["docs/guide.md"]'
review_json '.items[] | select(.code == "publish-conflict") | .run | contains("pull --rebase")'
apply_report '.status == "pending" and .exit_code == 3 and .data.published == false'
assert_contains "$DS_STDOUT" "publish-conflict"

# The same command meets the same conflict and changes nothing.
clear_log
assert_exit 3 apply --activate --publish
assert_eq "$mine" "$(head_oid)"
assert_eq "$moved" "$(remote_oid)"
no_replay_left
assert_no_step '^static '

# The person resolves it; the same command publishes.
git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid -c core.editor=true \
  pull -q --rebase -X theirs origin main >/dev/null 2>&1 || ds_fail "the rebase by hand failed"
clear_log
assert_exit 0 apply --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "$moved" "$(git -C "$up_inst" rev-parse HEAD^)"
derived_current HEAD

# --- another machine keeps publishing: three pushes, then publish-race -----------------------

base=$(remote_oid)
edit "a change that meets a busy remote"
other_machine_during_gate always docs/busy-page.md "another line of the busy machine"
clear_log
assert_exit 3 apply -m "docs: a busy remote" --activate --publish
assert_eq 3 "$(git -C "$up_bare" rev-list --count "$base..main")" "the other machine published three times"
assert_eq "" "$(git -C "$up_bare" log --format=%s "$base..main" | grep -v 'other machine' || true)" \
  "nothing of this machine is on the remote"
assert_eq "docs: a busy remote" "$(git -C "$up_inst" log -1 --format=%s)" "the commit stays here"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
no_replay_left
apply_report '.exit_code == 3 and ([.steps[] | select(.name == "replay")] | length) == 2'
apply_report '[.steps[] | select(.name == "publish")] | last | .status == "pending"'
review_json '[.items[] | select(.code == "publish-race")] | length == 1'
review_json '.items[] | select(.code == "publish-race") | .run | contains("dotsteward apply")'

# The other machine stops; the same command moves the commit onto the tip and publishes it.
rm -f -- "$UP_CONTROL/during-gate"
clear_log
assert_exit 0 apply --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "docs: a busy remote" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD~4)"
derived_current HEAD
no_replay_left
apply_report '.status == "ok" and ([.steps[] | select(.name == "replay")] | length) == 1'
review_json '[.items[] | select(.code == "publish-race" or .code == "publish-conflict")] == []'
