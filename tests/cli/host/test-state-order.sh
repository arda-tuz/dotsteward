# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The order of the records on a state branch. The newest record is the tip, whichever
# checkout of the machine made it, and a record that waited in a queue never replaces a
# newer one; the records that waited stay in the history. The machine key of a branch
# changes only through `state push --take-over` of a machine that is the reinstall of the
# name (host init --reuse) or after the records of the other machine stopped long ago:
# ordinary records of the other machine never take the branch back. Two records at the same
# time in one checkout both land, and a branch checked out in a linked work tree is never
# moved under it.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds_use_stubs dpkg-query

os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release

add_component example-editor deb '{"packageNames": ["example-editor"]}'
publish_instance "chore: a deb component"
ds_dpkg_installed example-editor 1.0.0-1

second=$DS_TEST_ROOT/second
git clone -q "$e2e_remote_url" "$second"
other=$DS_TEST_ROOT/other
git clone -q "$e2e_remote_url" "$other"
other_state=$DS_TEST_ROOT/state-other
mkdir -p "$other_state"

name_machine laptop

# st CHECKOUT ARG...: dotsteward state in CHECKOUT with the state root of this machine.
st() {
  local checkout=$1
  shift
  "$agents_fw/cli/dotsteward" --instance "$checkout" state "$@" </dev/null
}

# st_other ARG...: another machine (its own state root and machine key) that says it is laptop.
st_other() {
  DOTSTEWARD_STATE_ROOT=$other_state "$agents_fw/cli/dotsteward" --instance "$other" state "$@" </dev/null
}

version_at() {
  git -C "$e2e_bare" cat-file blob "$1:state.json" | jq -r '.components["example-editor"].packages["example-editor"]'
}

remote_tip() {
  git -C "$e2e_bare" rev-parse --verify --quiet refs/heads/state/laptop || true
}

key_at() {
  git -C "$e2e_bare" cat-file blob "$1:state.json" | jq -r .machine_key
}

# history: the versions of every record on the remote branch, oldest first.
history() {
  local commit
  git -C "$e2e_bare" rev-list --reverse --topo-order refs/heads/state/laptop | while read -r commit; do
    version_at "$commit"
  done | tr '\n' ' '
}

# --- a record that waited never replaces a newer one ------------------------------------------------

# Checkout A records 1.0.0 and keeps it here; then the machine has 2.0.0 and checkout B
# publishes that. The push of A brings its record into the history, and the tip stays 2.0.0.
assert_exit 0 st "$agents_inst" record --no-push
sleep 1
ds_dpkg_installed example-editor 2.0.0-1
assert_exit 0 st "$second" record
assert_eq "2.0.0-1" "$(version_at "$(remote_tip)")"
assert_exit 0 st "$agents_inst" push
assert_eq "2.0.0-1" "$(version_at "$(remote_tip)")" "an older record replaced the newer one"
assert_contains "$(history)" "1.0.0-1"
assert_eq "$(remote_tip)" "$(git -C "$agents_inst" rev-parse refs/heads/state/laptop)"

# Two records wait in A (3.0.0, 3.0.1), then B publishes 3.1.0: every record reaches the
# remote and the tip is the newest.
sleep 1
ds_dpkg_installed example-editor 3.0.0-1
assert_exit 0 st "$agents_inst" record --no-push
sleep 1
ds_dpkg_installed example-editor 3.0.1-1
assert_exit 0 st "$agents_inst" record --no-push
sleep 1
ds_dpkg_installed example-editor 3.1.0-1
assert_exit 0 st "$second" record
assert_exit 0 st "$agents_inst" push
assert_eq "3.1.0-1" "$(version_at "$(remote_tip)")"
assert_contains "$(history)" "3.0.0-1"
assert_contains "$(history)" "3.0.1-1"

# The records that waited are newer: they win, and what B had published stays in the history.
sleep 1
ds_dpkg_installed example-editor 3.2.0-1
assert_exit 0 st "$second" record
sleep 1
ds_dpkg_installed example-editor 3.3.0-1
assert_exit 0 st "$agents_inst" record --no-push
assert_exit 0 st "$agents_inst" push
assert_eq "3.3.0-1" "$(version_at "$(remote_tip)")"
assert_contains "$(history)" "3.2.0-1"

# A record of A that is the same as its last one, while B published another state since:
# the record says what the machine has now, so it lands on top.
sleep 1
ds_dpkg_installed example-editor 3.4.0-1
assert_exit 0 st "$second" record
sleep 1
ds_dpkg_installed example-editor 3.3.0-1
assert_exit 0 st "$agents_inst" record
assert_eq "3.3.0-1" "$(version_at "$(remote_tip)")" "the state of the machine now is not the tip"

# --- the machine key changes only through --take-over -------------------------------------------------

laptop_key=$(key_at "$(remote_tip)")
jq '.machine_key = "ffeeddccbbaa99887766554433221100"' "$(machine_file)" >"$other_state/machine.json"

# Another machine that says it is laptop, without a reuse: no record and no take-over of it lands.
before=$(remote_tip)
assert_exit 1 st_other record
assert_contains "$DS_STDERR" "state/laptop on the remote belongs to another machine"
assert_eq "$before" "$(remote_tip)"
assert_exit 1 st_other push --take-over
assert_contains "$DS_STDERR" "only the reinstall of laptop takes over"
assert_contains "$DS_STDERR" "dotsteward host init --reuse"
assert_eq "$before" "$(remote_tip)"

# The reinstall (host init --reuse) takes it over.
jq '.reused = true' "$other_state/machine.json" >"$DS_TEST_ROOT/machine.json"
mv -- "$DS_TEST_ROOT/machine.json" "$other_state/machine.json"
sleep 1
ds_dpkg_installed example-editor 4.0.0-1
assert_exit 1 st_other record
assert_exit 0 st_other push --take-over
taken=$(remote_tip)
assert_eq "ffeeddccbbaa99887766554433221100" "$(key_at "$taken")"

# The old machine, whose record says nothing new: its branch does not become the record of the
# other machine, and show never calls that record this machine's.
assert_exit 1 st "$agents_inst" record
assert_contains "$DS_STDERR" "state/laptop on the remote belongs to another machine"
assert_eq "$laptop_key" "$(git -C "$agents_inst" cat-file blob refs/heads/state/laptop:state.json | jq -r .machine_key)"
assert_exit 0 st "$agents_inst" show --json
assert_eq "$laptop_key" "$(jq -r .state.machine_key <<<"$DS_STDOUT")"
# A changed record of the old machine does not take the branch back either, nor does its take-over.
sleep 1
ds_dpkg_installed example-editor 4.1.0-1
assert_exit 1 st "$agents_inst" record
assert_exit 1 st "$agents_inst" push --take-over
assert_contains "$DS_STDERR" "only the reinstall of laptop takes over"
assert_eq "$taken" "$(remote_tip)"
assert_eq "ffeeddccbbaa99887766554433221100" "$(key_at "$(remote_tip)")"

# --- two records at the same time in one checkout ---------------------------------------------------------

cp -- "$other_state/machine.json" "$(machine_file)"
git -C "$agents_inst" update-ref -d refs/heads/state/laptop
for round in 1 2 3; do
  ds_dpkg_installed example-editor "5.0.$round-1"
  st "$agents_inst" record --no-push >"$DS_TEST_ROOT/race-a.out" 2>&1 &
  first=$!
  st "$agents_inst" record --no-push >"$DS_TEST_ROOT/race-b.out" 2>&1 &
  second_run=$!
  status_a=0
  status_b=0
  wait "$first" || status_a=$?
  wait "$second_run" || status_b=$?
  assert_eq "0 0" "$status_a $status_b" "a record at the same time failed: $(cat "$DS_TEST_ROOT/race-a.out" "$DS_TEST_ROOT/race-b.out")"
done

# --- a state branch checked out in a linked work tree is never moved under it -------------------------------

git -C "$agents_inst" worktree add -q "$DS_TEST_ROOT/worktree" state/laptop
held=$(git -C "$agents_inst" rev-parse refs/heads/state/laptop)
ds_dpkg_installed example-editor 6.0.0-1
assert_exit 1 st "$agents_inst" record --no-push
assert_contains "$DS_STDERR" "state/laptop is checked out in $DS_TEST_ROOT/worktree"
assert_eq "$held" "$(git -C "$agents_inst" rev-parse refs/heads/state/laptop)"
assert_eq "" "$(git -C "$DS_TEST_ROOT/worktree" status --porcelain)"
git -C "$agents_inst" worktree remove --force "$DS_TEST_ROOT/worktree"
assert_exit 0 st "$agents_inst" record --no-push
