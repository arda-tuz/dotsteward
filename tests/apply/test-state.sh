# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# After a green publish, apply records what this machine observes on its state branch
# (state/<name>, recorded_by apply) and pushes it, so add and remove leave the state of the machine
# as current as the intent. A run that does not publish records nothing. A record that cannot be
# made (a machine without a name, a finding of the privacy scan) is a note: the commit is published
# and apply stays green.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release

state_tip() {
  git -C "$1" rev-parse --verify --quiet refs/heads/state/example-host || true
}

# Not published: nothing recorded.
edit "a change kept here"
assert_exit 0 apply -m "docs: kept here" --no-activate --no-publish
assert_eq "" "$(state_tip "$up_inst")" "a record without a publish"
apply_report '[.steps[].name] | index("state") == null'

# Published: one record, on the remote too, of the published commit.
assert_exit 0 apply --activate --publish
head=$(head_oid)
assert_eq "$head" "$(remote_oid)" "published"
local_tip=$(state_tip "$up_inst")
[[ -n $local_tip ]] || ds_fail "apply recorded no state"
assert_eq "$local_tip" "$(state_tip "$up_bare")" "the record is not on the remote"
git -C "$up_inst" cat-file blob refs/heads/state/example-host:state.json >"$DS_TEST_ROOT/state.json"
assert_json "$DS_TEST_ROOT/state.json" ".recorded_by == \"apply\" and .host == \"example-host\" and .intent_commit == \"$head\""
apply_report '[.steps[].name] == ["stage", "generate", "gate", "commit", "rebuild", "e2e", "publish", "state"]'
apply_report '.steps[-1].status == "ok" and .status == "ok"'
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"

# Published without an activation: the state of this machine did not change, nothing is recorded.
edit "a change published but not activated here"
assert_exit 0 apply -m "docs: published, not activated" --no-activate --publish
assert_eq "$(head_oid)" "$(remote_oid)" "published"
assert_eq "$local_tip" "$(state_tip "$up_inst")" "a record of a tree that is not active here"
apply_report '(.steps[-1] | .name == "state" and (.detail | test("not recorded: nothing was activated")))'

# Any failure of the record after the publish is a note: here the denylist of the privacy policy
# goes away while E2E runs, after the gate proved the tree.
denylist=$DS_TEST_ROOT/denylist.txt
printf 'denied-name\n' >"$denylist"
printf '\n[privacy]\ndenylist = "%s"\n' "$denylist" >>"$up_inst/workstation.toml"
git -C "$up_inst" commit -q -am "chore: a denylist"
git -C "$up_inst" push -q origin HEAD:main
printf 'rm -f -- %q\n' "$denylist" >"$UP_CONTROL/e2e-hook"
edit "a change whose record fails"
assert_exit 0 apply -m "docs: the record fails" --activate --publish
rm -f -- "$UP_CONTROL/e2e-hook"
assert_eq "$(head_oid)" "$(remote_oid)" "published"
apply_report '.status == "ok" and (.steps[-1] | .name == "state" and (.detail | test("not recorded")))'
assert_contains "$DS_STDOUT" "state: not recorded"
python3 - "$up_inst/workstation.toml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(re.sub(r"\n\[privacy\]\ndenylist = .*\n", "\n", text))
PY
git -C "$up_inst" commit -q -am "chore: no denylist"
git -C "$up_inst" push -q origin HEAD:main

# A machine without a name: published, no record, a note, exit 0.
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine.json"
edit "a change of an unnamed machine"
assert_exit 0 apply -m "docs: an unnamed machine" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)" "published"
assert_eq "$local_tip" "$(state_tip "$up_inst")" "a record of a machine without a name"
apply_report '.status == "ok" and (.steps[-1] | .name == "state" and .status == "ok" and (.detail | test("not recorded")))'
assert_contains "$DS_STDOUT" "state: not recorded"
