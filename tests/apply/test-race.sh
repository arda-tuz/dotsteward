# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# Two machines and one remote: another machine publishes while this one proves its transaction.
# apply moves the commits of this machine onto the new tip in a clone of its own, takes the
# mirrors of the other side where both changed them and generates them again into the top commit,
# proves the new tree with the gate, activates it and runs E2E against the new base, and pushes
# without force. A change both machines made to the same lines stops it: the commits stay as they
# were, the checkout stays clean with no cherry-pick in it, and review.json says publish-conflict.
# Where both changed flake.lock and this machine only added to it, the tip's lock is taken and nix
# flake lock adds what is missing; a moved pin of the base is a conflict. No commit is dropped. A
# red gate after the replay says that the commits moved, and a merge among them is named.
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

# --- both machines changed flake.lock -----------------------------------------------------------
# One line of JSON, so that any two changes of the lock meet. A lock that this machine only added
# to takes the tip's lock and nix flake lock adds what is missing; the commit stays, also when
# nothing of it is left. A lock in which this machine moved a pin of the base is no text to merge:
# publish-conflict, and the commit stays on the branch.

jq -c '.nodes = {nixpkgs: {locked: {rev: "1111111"}}, root: {inputs: {nixpkgs: "nixpkgs"}}} | .root = "root"' \
  "$up_inst/flake.lock" >"$DS_TEST_ROOT/flake.lock"
mv -- "$DS_TEST_ROOT/flake.lock" "$up_inst/flake.lock"
assert_exit 0 apply -m "chore: pin nixpkgs" --activate --publish
base=$(remote_oid)
jq -c '.nodes.mine = {locked: {rev: "3333333"}}' "$up_inst/flake.lock" >"$DS_TEST_ROOT/flake.lock"
mv -- "$DS_TEST_ROOT/flake.lock" "$up_inst/flake.lock"
other_machine_edits_during_gate once flake.lock \
  "jq -c '.nodes.theirs = {locked: {rev: \"4444444\"}}' \"\$FILE\" >\"\$FILE.new\" && mv \"\$FILE.new\" \"\$FILE\""
: >"$DS_CALL_LOG"
clear_log
assert_exit 0 apply -m "feat: add an input" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "feat: add an input" "$(git -C "$up_inst" log -1 --format=%s)" "the commit stays, nothing of it dropped"
assert_eq "docs: a change of the other machine" "$(git -C "$up_inst" log -1 --format=%s HEAD^)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD~2)"
assert_eq '"4444444"' "$(git -C "$up_inst" show HEAD:flake.lock | jq -c .nodes.theirs.locked.rev)" \
  "the lock of the tip, which nix flake lock completes"
assert_call_count 1 nix '*flake lock*'
apply_report '.items == [] and .status == "ok"'
no_replay_left

base=$(remote_oid)
jq -c '.nodes.nixpkgs.locked.rev = "2222222"' "$up_inst/flake.lock" >"$DS_TEST_ROOT/flake.lock"
mv -- "$DS_TEST_ROOT/flake.lock" "$up_inst/flake.lock"
other_machine_edits_during_gate once flake.lock \
  "jq -c '.nodes.other = {locked: {rev: \"5555555\"}}' \"\$FILE\" >\"\$FILE.new\" && mv \"\$FILE.new\" \"\$FILE\""
clear_log
assert_exit 3 apply -m "chore: move nixpkgs" --activate --publish
assert_eq "chore: move nixpkgs" "$(git -C "$up_inst" log -1 --format=%s)" "the move stays on the branch"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)"
assert_eq '"2222222"' "$(git -C "$up_inst" show HEAD:flake.lock | jq -c .nodes.nixpkgs.locked.rev)"
assert_eq "" "$(git -C "$up_inst" status --porcelain)"
no_replay_left
review_json '.items[] | select(.code == "publish-conflict") | .paths == ["flake.lock"]'
review_json '[.items[] | select(.code == "publish-refused")] == []'
# The person takes the tip's lock and moves nixpkgs again on top of it.
git -C "$up_inst" reset -q --hard "$(remote_oid)"
jq -c '.nodes.nixpkgs.locked.rev = "2222222"' "$up_inst/flake.lock" >"$DS_TEST_ROOT/flake.lock"
mv -- "$DS_TEST_ROOT/flake.lock" "$up_inst/flake.lock"
assert_exit 0 apply -m "chore: move nixpkgs" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"

# --- after the replay the gate says no: the commits moved and wait here --------------------------

base=$(remote_oid)
edit "a change the second gate refuses"
cat >"$UP_CONTROL/during-gate" <<HOOK
if [[ -e $UP_CONTROL/pushed ]]; then
  : >"$UP_CONTROL/static-red"
  exit 0
fi
: >"$UP_CONTROL/pushed"
clone=$DS_TEST_ROOT/other-machine
rm -rf -- "\$clone"
git clone -q "$up_bare" "\$clone"
printf 'one more page\n' >"\$clone/docs/page-of-a-red-gate.md"
git -C "\$clone" add -A
git -C "\$clone" -c user.name=other -c user.email=other@example.invalid commit -q -m "docs: a change of the other machine"
git -C "\$clone" push -q origin HEAD:main
rm -rf -- "\$clone"
HOOK
clear_log
assert_exit 1 apply -m "docs: a red second gate" --activate --publish
rm -f -- "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red" "$UP_CONTROL/pushed"
assert_eq "docs: a red second gate" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD^)" "the commit moved onto the tip"
review_json '.items[] | select(.code == "gate-failed") | .message | contains("moved onto") and (contains("nothing was committed") | not)'
[[ -z $(git -C "$up_inst" for-each-ref refs/dotsteward/apply/replayed) ]] || ds_fail "the ref of the replay stays"
no_replay_left
assert_exit 0 apply --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"

# --- a merge among the commits: no replay, the way out named -------------------------------------

git -C "$up_inst" switch -q -c side
edit "a line of a side branch"
git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid commit -qam "docs: a side line"
git -C "$up_inst" switch -q main
printf 'notes\n' >"$up_inst/docs/main-page.md"
git -C "$up_inst" add -A
git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid commit -qm "docs: a main page"
git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid merge -q --no-ff -m "docs: merge the side line" side
git -C "$up_inst" branch -q -D side
mine=$(head_oid)
other_machine_during_gate once docs/merge-race.md "a page while a merge waits"
clear_log
assert_exit 3 apply --activate --publish
assert_eq "$mine" "$(head_oid)" "the merge stays as it was"
no_replay_left
review_json '.items[] | select(.code == "replay-merge") | (.commits | length) == 1 and (.run | contains("pull --rebase origin main"))'
git -C "$up_inst" -c user.name=alice -c user.email=alice@example.invalid pull -q --rebase origin main
assert_exit 0 apply --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"

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
# Nothing waits any more: review.json goes with its last item.
[[ ! -e $DOTSTEWARD_STATE_ROOT/review.json ]] ||
  review_json '[.items[] | select(.code == "publish-race" or .code == "publish-conflict")] == []'
