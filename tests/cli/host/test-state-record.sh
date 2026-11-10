# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `dotsteward state record`: the state this machine observes goes to refs/heads/state/<name>
# as state.json, the one file of an orphan history that git builds from objects alone: HEAD,
# the index and the work tree never move, so the checkout stays clean and E2E stays green.
# The record holds only what its schema allows: names from the intent, the versions of the
# packages a component installs, never free text; a value outside the schema or a finding of
# the privacy scan of the instance writes nothing and exits 4. A record equal to the last one
# is no commit. Without a network the record waits on this machine (exit 6, queued) and the
# next `state push` lands it; `[policy] observed_state_push = false` keeps it here.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds_use_stubs dpkg-query

run_state() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" state "$@" </dev/null
}

local_tip() {
  git -C "$agents_inst" rev-parse --verify --quiet refs/heads/state/laptop || true
}

remote_tip() {
  git -C "$e2e_bare" rev-parse --verify --quiet refs/heads/state/laptop || true
}

recorded() {
  git -C "$agents_inst" cat-file blob refs/heads/state/laptop:state.json
}

checkout_untouched() {
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "the checkout moved"
  assert_eq "main" "$(git -C "$agents_inst" symbolic-ref --short HEAD)" "HEAD left main"
  assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the checkout changed"
  assert_eq "$main_before" "$(git -C "$e2e_bare" rev-parse refs/heads/main)" "main of the remote moved"
}

os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release

# A deb component whose package goes by two names, as the deb method reads packageNames (one
# installed name is the package), with a plain APT package besides and one that it follows, and
# a component of another method.
add_component example-shell external '{}'
add_component example-editor deb '{"packageNames": ["example-editor", "example-editor-legacy"], "apt": ["example-editor-data"]}'
printf 'track = ["example-editor-plugins"]\n' >>"$agents_inst/workstation.toml"
publish_instance "chore: two components"
ds_dpkg_installed example-editor 1.2.3-1
ds_dpkg_installed example-editor-plugins 4.5~rc1+dfsg-0ubuntu1
ds_dpkg_installed unrelated-package 9.9

head=$(git -C "$agents_inst" rev-parse HEAD)
main_before=$(git -C "$e2e_bare" rev-parse refs/heads/main)

# --- no name, no record ------------------------------------------------------------------------

assert_exit 1 run_state record
assert_contains "$DS_STDERR" "this machine has no name yet"
assert_eq "" "$(local_tip)"

# --- the first record: an orphan commit with state.json alone, on the remote -------------------

name_machine laptop
mkdir -p "$DOTSTEWARD_STATE_ROOT/current" "$DOTSTEWARD_STATE_ROOT/update"
generation=/nix/store/b3x9k2h7q1w0v8m5n4c6z2a1s7d9f0g3-home-manager-generation
jq -n --arg generation "$generation" '{schema_version: "1.0", generation: $generation, profile: "workstation",
  activated_at: "2026-11-03T07:50:00Z"}' >"$DOTSTEWARD_STATE_ROOT/current/activation.json"
jq -n --arg generation "$generation" '{schema_version: "1.0", result: "passed", generation: $generation,
  profile: "workstation", recorded_at: "2026-11-03T07:58:10Z"}' >"$DOTSTEWARD_STATE_ROOT/update/e2e.json"

assert_exit 0 run_state record
assert_contains "$DS_STDOUT" "recorded the state of laptop on state/laptop"
assert_contains "$DS_STDOUT" "published state/laptop"
first=$(local_tip)
assert_eq "$first" "$(remote_tip)" "the record is not on the remote"
assert_eq "" "$(git -C "$agents_inst" log -1 --format=%P "$first")" "the first record has a parent"
assert_eq "state.json" "$(git -C "$agents_inst" ls-tree --name-only "$first")"
assert_eq "chore(state): record laptop" "$(git -C "$agents_inst" log -1 --format=%s "$first")"
assert_contains "$(git -C "$agents_inst" log -1 --format=%B "$first")" "Dotsteward-Machine: laptop"
checkout_untouched

recorded | assert_json - '.schema_version == 1 and .host == "laptop"
  and .machine_key == "00112233445566778899aabbccddeeff" and .recorded_by == "state"'
recorded | assert_json - '.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
assert_eq "$head" "$(recorded | jq -r .intent_commit)" "intent_commit is not HEAD"
assert_eq "$(<"$agents_fw/VERSION")" "$(recorded | jq -r .framework_version)"
recorded | assert_json - '.platform == {os: "ubuntu", version: "24.04", codename: "noble", arch: "x86_64"}'
recorded | assert_json - '.generation == {home_manager: "b3x9k2h7q1w0v8m5n4c6z2a1s7d9f0g3", e2e: "pass",
  at: "2026-11-03T07:58:10Z"}'
# Only the components of the intent, and of a deb component only the packages it names.
recorded | assert_json - '.components | keys == ["example-editor", "example-shell"]'
recorded | assert_json - '.components["example-editor"] == {status: "missing",
  packages: {"example-editor": "1.2.3-1", "example-editor-plugins": "4.5~rc1+dfsg-0ubuntu1"}}'
recorded | assert_json - '.components["example-shell"] == {}'
assert_not_contains "$(recorded)" "unrelated-package"
# No name of the person, of the host or of a path of this machine.
assert_not_contains "$(recorded)" "dotsteward-test"
assert_not_contains "$(recorded)" "$HOME"
assert_not_contains "$(recorded)" "$DS_TEST_ROOT"

# --- the same state again: no commit -----------------------------------------------------------

assert_exit 0 run_state record
assert_contains "$DS_STDOUT" "the state of laptop is as recorded"
assert_eq "$first" "$(local_tip)"
assert_eq "$first" "$(remote_tip)"

# --- a change: one commit on the last one, fast-forward on the remote ----------------------------

ds_dpkg_installed example-editor-data 1.2.3-1
assert_exit 0 run_state record
second=$(local_tip)
assert_eq "$first" "$(git -C "$agents_inst" log -1 --format=%P "$second")" "not one commit on the last record"
assert_eq "$second" "$(remote_tip)"
recorded | assert_json - '.components["example-editor"].status == "installed"
  and .components["example-editor"].packages["example-editor-data"] == "1.2.3-1"'
checkout_untouched

# --- no network: the record waits on this machine, and the next push lands it -------------------

ds_dpkg_installed example-editor 1.2.4-1
assert_exit 6 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" state record </dev/null
assert_contains "$DS_STDOUT" "recorded the state of laptop on state/laptop"
assert_contains "$DS_STDERR" "state/laptop waits: no network or no login"
third=$(local_tip)
assert_eq "$second" "$(git -C "$agents_inst" log -1 --format=%P "$third")"
assert_eq "$second" "$(remote_tip)" "an offline record reached the remote"

assert_exit 0 run_state show --json
assert_json - '.host == "laptop" and .this_machine == true and .queued == true
  and .state.components["example-editor"].packages["example-editor"] == "1.2.4-1"' <<<"$DS_STDOUT"
assert_exit 0 run_state show
assert_contains "$DS_STDOUT" "machine: laptop (this machine)"
assert_contains "$DS_STDOUT" "queued: yes"
assert_contains "$DS_STDOUT" "platform: ubuntu 24.04 noble x86_64"
assert_contains "$DS_STDOUT" "example-editor: installed"

assert_exit 6 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" state push </dev/null
assert_eq "$second" "$(remote_tip)"
assert_exit 0 run_state push
assert_contains "$DS_STDOUT" "published state/laptop"
assert_eq "$third" "$(remote_tip)"
assert_exit 0 run_state show --json
assert_json - '.queued == false' <<<"$DS_STDOUT"
assert_exit 0 run_state push
assert_contains "$DS_STDOUT" "state/laptop is on the remote; nothing to publish"
checkout_untouched

# --- outside the schema: nothing is written ------------------------------------------------------

long_version=1.$(printf '%070d' 0)
ds_dpkg_installed example-editor "$long_version"
assert_exit 4 run_state record
assert_contains "$DS_STDERR" "components.example-editor.packages.example-editor"
assert_contains "$DS_STDERR" "nothing was recorded"
assert_eq "$third" "$(local_tip)"
assert_eq "$third" "$(remote_tip)"
ds_dpkg_installed example-editor 1.2.4-1

# A machine key that is no machine key.
name_machine laptop '.machine_key = "not-a-key"'
assert_exit 4 run_state record
assert_contains "$DS_STDERR" "machine_key"
assert_eq "$third" "$(local_tip)"
name_machine laptop

# --- the privacy scan of the instance: a term of its denylist stops the record ------------------

base_config=$DS_TEST_ROOT/workstation.base.toml
cp -- "$agents_inst/workstation.toml" "$base_config"
denylist=$DS_TEST_ROOT/denylist.txt
printf 'example-editor-plugins\n' >"$denylist"
printf '\n[privacy]\ndenylist = "%s"\n' "$denylist" >>"$agents_inst/workstation.toml"
ds_dpkg_installed example-editor 1.2.5-1
assert_exit 4 run_state record
assert_contains "$DS_STDERR" "the privacy scan found something in state.json; nothing was recorded"
assert_not_contains "$DS_STDOUT$DS_STDERR" "1.2.5-1"
assert_eq "$third" "$(local_tip)"
assert_eq "$third" "$(remote_tip)"
cp -- "$base_config" "$agents_inst/workstation.toml"

# --- the policy keeps the state on this machine ---------------------------------------------------

printf '\n[policy]\nobserved_state_push = false\n' >>"$agents_inst/workstation.toml"
assert_exit 0 run_state record
assert_contains "$DS_STDOUT" "recorded the state of laptop on state/laptop"
assert_contains "$DS_STDOUT" "observed_state_push = false: state/laptop stays on this machine"
fourth=$(local_tip)
assert_eq "$third" "$(git -C "$agents_inst" log -1 --format=%P "$fourth")"
assert_eq "$third" "$(remote_tip)"
assert_exit 0 run_state push
assert_contains "$DS_STDOUT" "state/laptop stays on this machine"
assert_eq "$third" "$(remote_tip)"
cp -- "$base_config" "$agents_inst/workstation.toml"
assert_exit 0 run_state push
assert_eq "$fourth" "$(remote_tip)"

# --- the state branch is no obstacle to the commands of the checkout -----------------------------

assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)"
assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)"
assert_exit 0 run_e2e
