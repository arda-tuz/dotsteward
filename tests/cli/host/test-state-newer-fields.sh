# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# A machine on a newer framework records fields this CLI does not know, at the top and inside
# an entry: the reader ignores them and reads the rest, held to the schema as strictly as before
# (a known field of another form, or a record without a required field, is still no state).
# What it ignores is never printed, since the schema is the allowlist of what a record may say.
# The writer stays strict (test-state-record.sh): a record of this machine is the schema only.
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
desk_state=$DS_TEST_ROOT/state-desk
desk=$DS_TEST_ROOT/desk
mkdir -p "$desk_state"
git clone -q "$e2e_remote_url" "$desk"

state_in() {
  local checkout=$1 root=$2
  shift 2
  DOTSTEWARD_STATE_ROOT=$root "$agents_fw/cli/dotsteward" --instance "$checkout" state "$@" </dev/null
}

name_machine laptop
jq '.name = "desk" | .machine_key = "ffeeddccbbaa99887766554433221100"' \
  "$laptop_state/machine.json" >"$desk_state/machine.json"
assert_exit 0 state_in "$desk" "$desk_state" record

# newer PYTHON: a record of desk on the remote, as a newer framework writes it: the last
# record of desk with PYTHON applied to it (`data`).
newer() {
  local file=$DS_TEST_ROOT/newer.json blob tree commit parent
  parent=$(git -C "$e2e_bare" rev-parse refs/heads/state/desk)
  git -C "$e2e_bare" cat-file blob "$parent:state.json" >"$file"
  python3 - "$file" "$1" <<'PY'
import json, sys
path, program = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
exec(program)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
PY
  blob=$(git -C "$e2e_bare" hash-object -w "$file")
  tree=$(printf '100644 blob %s\tstate.json\n' "$blob" | git -C "$e2e_bare" mktree)
  commit=$(git -C "$e2e_bare" commit-tree "$tree" -p "$parent" -m "chore(state): record desk")
  git -C "$e2e_bare" update-ref refs/heads/state/desk "$commit"
  assert_exit 0 state_in "$agents_inst" "$laptop_state" fetch
}

held='{"commit": "1111111111111111111111111111111111111111", "lock_commit": "2222222222222222222222222222222222222222", "components": ["example-editor"], "at": "2026-11-01T10:00:00Z"}'

# Fields of a newer framework at the top, inside a component entry and inside held.
newer "
data['held'] = json.loads('''$held''')
data['held']['reason_code'] = 'newer'
data['future_summary'] = {'count': 3, 'secret_word': 'example-unknown-value'}
data['components']['example-editor']['future_channel'] = 'example-unknown-value'
"
assert_exit 0 state_in "$agents_inst" "$laptop_state" show desk --json
assert_json - '.host == "desk" and .this_machine == false
  and .state.machine_key == "ffeeddccbbaa99887766554433221100"
  and .state.components["example-editor"].packages["example-editor"] == "1.0.0-1"
  and .state.held.lock_commit == "2222222222222222222222222222222222222222"
  and (.state | has("future_summary") | not)
  and (.state.components["example-editor"] | has("future_channel") | not)
  and (.state.held | has("reason_code") | not)
  and .ignored == 3' <<<"$DS_STDOUT"
assert_not_contains "$DS_STDOUT" "example-unknown-value"
assert_exit 0 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDOUT" "machine: desk"
assert_contains "$DS_STDOUT" "ignored: 3 fields of a newer framework"
assert_not_contains "$DS_STDOUT" "example-unknown-value"
assert_not_contains "$DS_STDOUT" "future_"

# A known field of another form is still no state.
newer "data['machine_key'] = 'not a key'"
assert_exit 1 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDERR" "breaks its schema"

# Nor is a record without a required field, whatever else it holds.
newer "
data['machine_key'] = 'ffeeddccbbaa99887766554433221100'
del data['recorded_by']
data['future_summary'] = {'count': 1}
"
assert_exit 1 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDERR" "breaks its schema"
assert_contains "$DS_STDERR" "recorded_by"

# Nor a record of another schema version.
newer "
data['recorded_by'] = 'state'
data['schema_version'] = 2
"
assert_exit 1 state_in "$agents_inst" "$laptop_state" show desk
assert_contains "$DS_STDERR" "breaks its schema"

