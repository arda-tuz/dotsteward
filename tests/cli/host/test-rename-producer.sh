# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the lock holder is a script in single quotes
# `dotsteward host producer` and `host rename` change what all machines share, so each is
# one commit in the clean checkout, with the mirrors regenerated, published like every
# maintain commit. A failure leaves the checkout as it was, and the name with it.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds_use_stubs nix
mirrors=$DS_TEST_ROOT/mirrors.json
mirrors_glob="eval --json --no-update-lock-file $agents_inst#dotstewardMirrors"

serve_mirrors() {
  jq -n --rawfile manifest "$agents_manifest" '{"manifest.x86_64-linux.json": $manifest}' >"$mirrors"
  ds_stub_clear_routes nix
  ds_stub_route nix "$mirrors_glob" --stdout-file "$mirrors"
}

fail_generate() {
  ds_stub_clear_routes nix
  ds_stub_route nix "$mirrors_glob" --exit 1
}

# A comment the edits must keep, and a manifest `pins sync` can read.
sed -i '1i # The workstation of this person.' "$agents_inst/workstation.toml"
manifest_edit '.pins = { rules: [], latest: [] }'
jq '. + { flake_inputs: {}, nix_packages: {} }' "$agents_inst/versions.lock.json" >"$DS_TEST_ROOT/lock.json"
cp -- "$DS_TEST_ROOT/lock.json" "$agents_inst/versions.lock.json"
printf '{ "nodes": { "root": { "inputs": {} } }, "root": "root", "version": 7 }\n' >"$agents_inst/flake.lock"
publish_instance
serve_mirrors

toml() {
  python3 -I -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$agents_inst/workstation.toml"
}

untouched() {
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "a commit was made"
  assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the checkout changed"
}

head=$(git -C "$agents_inst" rev-parse HEAD)

# --- producer ------------------------------------------------------------------------------

assert_exit 2 run_host producer
assert_exit 2 run_host producer Not_A_Name
assert_contains "$DS_STDERR" "invalid machine name"
assert_exit 1 run_host producer nobody
assert_contains "$DS_STDERR" "nobody is neither this machine nor in hosts/"
untouched

# A machine of hosts/, or this machine before its file landed.
name_machine laptop
assert_exit 0 run_host producer laptop
assert_contains "$DS_STDOUT" "chore(hosts): make laptop the producer"
assert_contains "$DS_STDOUT" "dotsteward gate --scope maintain"
assert_contains "$DS_STDOUT" "dotsteward txn publish --scope maintain"
assert_eq "chore(hosts): make laptop the producer" "$(git -C "$agents_inst" log -1 --format=%s)"
assert_contains "$(git -C "$agents_inst" log -1 --format=%B)" "Dotsteward-Machine: laptop"
assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD^)"
assert_eq "workstation.toml" "$(git -C "$agents_inst" diff-tree --no-commit-id --name-only -r HEAD)"
assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)"
assert_json - '.hosts.producer == "laptop"' <<<"$(toml)"
assert_contains "$(<"$agents_inst/workstation.toml")" "# The workstation of this person."
assert_call_count 1 nix '*dotstewardMirrors'
git -C "$agents_inst" push -q origin main
head=$(git -C "$agents_inst" rev-parse HEAD)
assert_exit 0 run_e2e

# Already so: nothing to do.
assert_exit 0 run_host producer laptop
assert_contains "$DS_STDOUT" "is the producer already"
untouched

# Behind the remote a commit could not be published, so it is not made.
other=$DS_TEST_ROOT/other-clone
git clone -q "$e2e_bare" "$other"
ds_git_commit "$other" elsewhere.txt "elsewhere" "docs: elsewhere"
git -C "$other" push -q origin main
assert_exit 1 run_host producer other-name
assert_contains "$DS_STDERR" "nor in hosts/"
name_machine laptop-2
assert_exit 1 run_host producer laptop-2
assert_contains "$DS_STDERR" "the checkout is behind the remote"
untouched
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)
name_machine laptop

# Another registered machine; a dirty checkout is refused.
write_host desktop
publish_instance "chore(hosts): add desktop"
head=$(git -C "$agents_inst" rev-parse HEAD)
serve_mirrors
printf 'scratch\n' >"$agents_inst/scratch.txt"
assert_exit 1 run_host producer desktop
assert_contains "$DS_STDERR" "not clean"
rm -- "$agents_inst/scratch.txt"
untouched

# A failed generate leaves everything as it was.
fail_generate
assert_exit 1 run_host producer desktop
assert_contains "$DS_STDERR" "generate failed"
untouched
assert_json - '.hosts.producer == "laptop"' <<<"$(toml)"
serve_mirrors

# Another command holds the instance lock.
PYTHONPATH=$agents_fw/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.internal \
  lock run --holder upgrade --state-root "$DOTSTEWARD_STATE_ROOT" -- bash -c '
    : >"$1"
    until [[ -e $2 ]]; do
      sleep 0.02
    done' bash "$DS_TEST_ROOT/holder-started" "$DS_TEST_ROOT/holder-release" &
holder=$!
until [[ -e $DS_TEST_ROOT/holder-started ]]; do
  sleep 0.02
done
assert_exit 1 run_host producer desktop
assert_contains "$DS_STDERR" "another command holds the instance lock: upgrade"
: >"$DS_TEST_ROOT/holder-release"
wait "$holder"
untouched

assert_exit 0 run_host producer desktop
assert_contains "$(<"$agents_inst/workstation.toml")" 'producer = "desktop"'
git -C "$agents_inst" push -q origin main
head=$(git -C "$agents_inst" rev-parse HEAD)

# --- rename --------------------------------------------------------------------------------

rm -- "$(machine_file)"
assert_exit 1 run_host rename other
assert_contains "$DS_STDERR" "no name yet"
assert_exit 2 run_host rename
assert_exit 2 run_host rename Not_A_Name
name_machine loner
key=$(jq -r .machine_key "$(machine_file)")

# The same name; a name that is taken.
assert_exit 0 run_host rename loner
assert_contains "$DS_STDOUT" "this machine is loner already"
assert_exit 1 run_host rename desktop
assert_contains "$DS_STDERR" "hosts/desktop.toml exists"
assert_eq '"loner"' "$(jq -c .name "$(machine_file)")"
untouched

# The tree does not know this name: no commit.
assert_exit 0 run_host rename solo
assert_contains "$DS_STDOUT" "this machine is solo"
assert_eq '"solo"' "$(jq -c .name "$(machine_file)")"
assert_eq "$key" "$(jq -r .machine_key "$(machine_file)")"
untouched

# Behind the remote the tree may know more than this checkout says: first the pull.
git -C "$other" pull -q --ff-only origin main
ds_git_commit "$other" elsewhere-2.txt "elsewhere" "docs: elsewhere again"
git -C "$other" push -q origin main
assert_exit 1 run_host rename still-solo
assert_contains "$DS_STDERR" "the checkout is behind the remote"
assert_eq '"solo"' "$(jq -c .name "$(machine_file)")"
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)

# The tree knows it: the file, the machines lists and the producer move in one commit.
lock_add alpha
lock_add beta
set_machines alpha '["solo", "desktop"]'
set_machines beta '["desktop"]'
write_host solo 'tags = ["small"]
declined = { skills = ["gamma"] }'
python3 -I - "$agents_inst/workstation.toml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace('producer = "desktop"', 'producer = "solo"')
text += '\n[components.example]\nenable = true\n'
text += '[[components.example.options.plugins]]\nspec = "scoped@market"\nmachines = ["solo"]\n'
text += '[[components.example.options.plugins]]\nspec = "other@market"\nmachines = ["desktop"]\n'
text += '[components.scoped]\nenable = true\nmachines = ["solo"]\n'
open(path, "w", encoding="utf-8").write(text)
PY
mkdir -p "$agents_inst/components/example"
publish_instance "chore: machines"
serve_mirrors
head=$(git -C "$agents_inst" rev-parse HEAD)
assert_eq '["beta","other@market"]' "$(effective '[.skip.skills[], .skip.plugins[]]')"

# Refused or failed: the old name, the old tree.
printf 'scratch\n' >"$agents_inst/scratch.txt"
assert_exit 1 run_host rename big
assert_contains "$DS_STDERR" "not clean"
rm -- "$agents_inst/scratch.txt"
fail_generate
assert_exit 1 run_host rename big
assert_contains "$DS_STDERR" "generate failed"
untouched
[[ -f $agents_inst/hosts/solo.toml && ! -e $agents_inst/hosts/big.toml ]] || ds_fail "the file moved"
assert_eq '"solo"' "$(jq -c .name "$(machine_file)")"
serve_mirrors

assert_exit 0 run_host rename big
assert_contains "$DS_STDOUT" "chore(hosts): rename solo to big"
assert_contains "$DS_STDOUT" "this machine is big"
assert_eq '"big"' "$(jq -c .name "$(machine_file)")"
# The old name, so that the gate lets this machine, and only it, remove hosts/solo.toml.
assert_eq '"solo"' "$(jq -c .renamed_from "$(machine_file)")"
assert_eq "$key" "$(jq -r .machine_key "$(machine_file)")"
assert_eq "chore(hosts): rename solo to big" "$(git -C "$agents_inst" log -1 --format=%s)"
assert_contains "$(git -C "$agents_inst" log -1 --format=%B)" "Dotsteward-Machine: big"
assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD^)"
assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)"
[[ ! -e $agents_inst/hosts/solo.toml ]] || ds_fail "the old file stayed"
assert_contains "$(<"$agents_inst/hosts/big.toml")" 'skills = ["gamma"]'
assert_json "$agents_lock" '(.skills[] | select(.name == "alpha") | .machines) == ["big", "desktop"]
  and (.skills[] | select(.name == "beta") | .machines) == ["desktop"]'
assert_json - '.hosts.producer == "big" and .components.scoped.machines == ["big"]
  and ([.components.example.options.plugins[].machines] == [["big"], ["desktop"]])' <<<"$(toml)"
# What applies to this machine stays what it was.
assert_eq '["beta","other@market"]' "$(effective '[.skip.skills[], .skip.plugins[]]')"
assert_exit 0 run_host check
