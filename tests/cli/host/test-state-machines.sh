# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The state branches of several machines on one remote. Only the machine writes its own
# branch, and every push is a plain fast-forward. A second checkout of the same machine
# (the same machine key) that records on its own commits again on the tip of the remote; a
# branch whose records come from another machine key is two machines with one name, and
# the push stops until this machine takes another name or says it is the reinstall of that
# machine. `state fetch` brings the branches of the others, and `state show NAME` reads
# them.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds_use_stubs dpkg-query

os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release

add_component example-editor deb '{"packageNames": ["example-editor"]}'
publish_instance "chore: a deb component"
ds_dpkg_installed example-editor 1.0.0-1

laptop_state=$DOTSTEWARD_STATE_ROOT
second_state=$DS_TEST_ROOT/state-second
desk_state=$DS_TEST_ROOT/state-desk
mkdir -p "$second_state" "$desk_state"

second=$DS_TEST_ROOT/second
desk=$DS_TEST_ROOT/desk
git clone -q "$e2e_remote_url" "$second"
git clone -q "$e2e_remote_url" "$desk"

# state_in CHECKOUT STATE_ROOT ARG...: dotsteward state in another checkout of another state root.
state_in() {
  local checkout=$1 root=$2
  shift 2
  DOTSTEWARD_STATE_ROOT=$root "$agents_fw/cli/dotsteward" --instance "$checkout" state "$@" </dev/null
}

remote_tip() {
  git -C "$e2e_bare" rev-parse --verify --quiet "refs/heads/state/$1" || true
}

remote_state() {
  git -C "$e2e_bare" cat-file blob "refs/heads/state/$1:state.json"
}

name_machine laptop
cp -- "$laptop_state/machine.json" "$second_state/machine.json"
jq '.name = "desk" | .machine_key = "ffeeddccbbaa99887766554433221100"' \
  "$laptop_state/machine.json" >"$desk_state/machine.json"

# --- one machine, two checkouts --------------------------------------------------------------------

assert_exit 0 state_in "$agents_inst" "$laptop_state" record
first=$(remote_tip laptop)
[[ -n $first ]] || ds_fail "the first record is not on the remote"

# The second checkout records what it sees on its own, without the history of the first:
# its push is no fast-forward, the remote branch is this machine's, so it commits again
# on the tip of the remote.
ds_dpkg_installed example-editor 1.0.1-1
assert_exit 0 state_in "$second" "$second_state" record
assert_contains "$DS_STDOUT" "published state/laptop"
tip=$(remote_tip laptop)
assert_eq "$first" "$(git -C "$e2e_bare" log -1 --format=%P "$tip")" "not one commit on the tip of the remote"
remote_state laptop | assert_json - '.components["example-editor"].packages["example-editor"] == "1.0.1-1"'
assert_eq "$tip" "$(git -C "$second" rev-parse refs/heads/state/laptop)" "the local branch is not the published one"
assert_eq "1" "$(git -C "$e2e_bare" ls-tree --name-only "$tip" | wc -l | tr -d ' ')"

# The first checkout is behind now: what it records is what the remote branch already
# says, so nothing goes out and the local branch takes the remote one.
assert_exit 0 state_in "$agents_inst" "$laptop_state" record
assert_eq "$tip" "$(remote_tip laptop)"
assert_exit 0 state_in "$agents_inst" "$laptop_state" push
assert_contains "$DS_STDOUT" "state/laptop is on the remote; nothing to publish"
assert_eq "$tip" "$(git -C "$agents_inst" rev-parse refs/heads/state/laptop)"

# --- another machine, its own branch ---------------------------------------------------------------

assert_exit 0 state_in "$desk" "$desk_state" record
assert_contains "$DS_STDOUT" "published state/desk"
remote_state desk | assert_json - '.host == "desk" and .machine_key == "ffeeddccbbaa99887766554433221100"'
assert_eq "$tip" "$(remote_tip laptop)" "another machine moved the branch of laptop"

# Before a fetch the branch of desk is not here.
assert_exit 1 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDERR" "no recorded state of desk here: 'dotsteward state fetch' brings it"
assert_exit 0 state_in "$agents_inst" "$laptop_state" fetch
assert_contains "$DS_STDOUT" "fetched the state of 2 machines"
assert_eq "$(remote_tip desk)" "$(git -C "$agents_inst" rev-parse refs/remotes/origin/state/desk)"
assert_exit 0 state_in "$agents_inst" "$laptop_state" show desk --json
assert_json - '.host == "desk" and .this_machine == false and .queued == null
  and .state.machine_key == "ffeeddccbbaa99887766554433221100"' <<<"$DS_STDOUT"
assert_exit 0 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDOUT" "machine: desk"
assert_not_contains "$DS_STDOUT" "this machine"
assert_exit 1 state_in "$agents_inst" "$laptop_state" show nobody
assert_contains "$DS_STDERR" "no recorded state of nobody here"
assert_exit 2 state_in "$agents_inst" "$laptop_state" show 'Not A Name'
# The fetch keeps away from main and from the checkout.
assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)"

# A branch of the remote that breaks the schema is no state: show refuses to read it.
broken=$DS_TEST_ROOT/broken
mkdir -p "$broken"
printf '{"schema_version": 1, "host": "desk", "note": "free text"}\n' >"$broken/state.json"
blob=$(git -C "$e2e_bare" hash-object -w "$broken/state.json")
tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$e2e_bare" mktree)
commit=$(git -C "$e2e_bare" commit-tree "$tree" -p "$(remote_tip desk)" -m "chore(state): record desk")
git -C "$e2e_bare" update-ref refs/heads/state/desk "$commit"
assert_exit 0 state_in "$agents_inst" "$laptop_state" fetch
assert_exit 1 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDERR" "unknown key note"

# --- two machines, one name ------------------------------------------------------------------------

# A third machine names itself laptop, with a machine key of its own.
jq '.name = "laptop"' "$desk_state/machine.json" >"$DS_TEST_ROOT/machine.json"
mv -- "$DS_TEST_ROOT/machine.json" "$desk_state/machine.json"
before=$(remote_tip laptop)
ds_dpkg_installed example-editor 2.0.0-1
assert_exit 1 state_in "$desk" "$desk_state" record
assert_contains "$DS_STDOUT" "recorded the state of laptop on state/laptop"
assert_contains "$DS_STDERR" "state/laptop on the remote belongs to another machine"
assert_contains "$DS_STDERR" "dotsteward host rename"
assert_contains "$DS_STDERR" "dotsteward state push --take-over"
assert_eq "$before" "$(remote_tip laptop)" "the record of another machine moved the branch"
assert_exit 1 state_in "$desk" "$desk_state" push
assert_eq "$before" "$(remote_tip laptop)"

# The reinstall of laptop says so: its records continue the history of the branch.
assert_exit 0 state_in "$desk" "$desk_state" push --take-over
assert_contains "$DS_STDOUT" "published state/laptop"
taken=$(remote_tip laptop)
assert_eq "$before" "$(git -C "$e2e_bare" log -1 --format=%P "$taken")"
remote_state laptop | assert_json - '.machine_key == "ffeeddccbbaa99887766554433221100"'

# From now on the old key is the other machine: the first checkout of laptop stops.
ds_dpkg_installed example-editor 2.0.1-1
assert_exit 1 state_in "$agents_inst" "$laptop_state" record
assert_contains "$DS_STDERR" "state/laptop on the remote belongs to another machine"
assert_eq "$taken" "$(remote_tip laptop)"

# Nothing here ever moved main of the remote or a checkout.
for checkout in "$agents_inst" "$second" "$desk"; do
  assert_eq "" "$(git -C "$checkout" status --porcelain --untracked-files=normal)" "$checkout changed"
  assert_eq "main" "$(git -C "$checkout" symbolic-ref --short HEAD)"
done
assert_eq "$(git -C "$agents_inst" rev-parse HEAD)" "$(git -C "$e2e_bare" rev-parse refs/heads/main)"
