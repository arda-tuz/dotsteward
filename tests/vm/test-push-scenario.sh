# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# push ships a committed framework revision into the guest as a git bundle
# and checks it out at ~/dotsteward-src; scenario pushes, then runs the
# scenario's guest script from that checkout, logs the session in the run
# directory and passes the guest's exit status through.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image
assert_exit 0 "$VM_SH" up
run=$(vm_run_dir)

src=$DS_TEST_ROOT/framework
vm_framework_repo "$src"
sha=$(git -C "$src" rev-parse HEAD)

# The call number of the last ssh command that contains TEXT.
last_call_with() {
  awk -F '\t' -v text="$1" 'index($2, text) { n = $1 } END { print n }' "$DS_STUB_STATE/ssh/commands"
}

assert_exit 0 "$VM_SH" push --source "$src"
assert_contains "$DS_STDOUT" "$sha"
upload=$(last_call_with 'cat >')
[[ -n $upload ]] || ds_fail "push uploaded nothing: $(<"$DS_STUB_STATE/ssh/commands")"
git clone -q "$DS_STUB_STATE/ssh/stdin.$upload" "$DS_TEST_ROOT/unbundled" ||
  ds_fail "the upload is not a git bundle"
git -C "$DS_TEST_ROOT/unbundled" cat-file -e "$sha^{commit}" || ds_fail "the bundle lacks $sha"
checkout=$(awk -F '\t' -v n=$((upload + 1)) '$1 == n { print $2 }' "$DS_STUB_STATE/ssh/commands")
assert_contains "$checkout" 'git clone'
assert_contains "$checkout" "$sha"
assert_contains "$checkout" 'dotsteward-src'

# Uncommitted changes are not shipped, and push says so.
printf 'local edit\n' >>"$src/README.md"
assert_exit 0 "$VM_SH" push --source "$src"
assert_contains "$DS_STDERR" 'uncommitted changes'
git -C "$src" checkout -q -- README.md

# --ref takes a branch, tag or commit; an unknown one is refused.
git -C "$src" tag v0.0.0-test
assert_exit 0 "$VM_SH" push --source "$src" --ref v0.0.0-test
assert_contains "$DS_STDOUT" "$sha"
assert_exit 0 "$VM_SH" push --source "$src" --ref "$sha"
assert_exit 1 "$VM_SH" push --source "$src" --ref no-such-ref
assert_exit 1 "$VM_SH" push --source "$DS_TEST_ROOT"
assert_contains "$DS_STDERR" 'not a git checkout'

# A guest without git cannot receive the framework.
vm_fake_set ssh command_exit 1
assert_exit 1 "$VM_SH" push --source "$src"
assert_contains "$DS_STDERR" 'git'
vm_fake_set ssh command_exit 0

# The scenarios are the guest scripts.
assert_exit 0 "$VM_SH" scenario --list
assert_eq $'agent-prepare\nagent-verify\nclean-install' "$DS_STDOUT"

# scenario = push + the guest script with the given arguments.
printf 'guest says hello\n' >"$DS_STUB_STATE/ssh/command_output"
uploads_before=$(grep -c 'cat >' "$DS_STUB_STATE/ssh/commands")
assert_exit 0 "$VM_SH" scenario clean-install --source "$src" -- --keep 'a b'
assert_eq $((uploads_before + 1)) "$(grep -c 'cat >' "$DS_STUB_STATE/ssh/commands")"
assert_contains "$(tail -n 1 "$DS_STUB_STATE/ssh/commands")" \
  $'\tbash dotsteward-src/tests/vm/guest/clean-install.sh --keep a\\ b'
assert_contains "$DS_STDOUT" 'guest says hello'
logs=("$run"/logs/clean-install-*.log)
[[ -f ${logs[0]} ]] || ds_fail "scenario wrote no log"
assert_contains "$(<"${logs[0]}")" 'guest says hello'

# --no-push runs the script already in the guest; the guest's exit status
# is passed through.
vm_fake_set ssh command_exit 3
assert_exit 3 "$VM_SH" scenario agent-verify --no-push
assert_eq $((uploads_before + 1)) "$(grep -c 'cat >' "$DS_STUB_STATE/ssh/commands")"
assert_contains "$(tail -n 1 "$DS_STUB_STATE/ssh/commands")" $'\tbash dotsteward-src/tests/vm/guest/agent-verify.sh'
vm_fake_set ssh command_exit 0

# Unknown scenarios and stopped VMs are refused.
assert_exit 2 "$VM_SH" scenario no-such-scenario --no-push
assert_contains "$DS_STDERR" 'unknown scenario'
assert_exit 2 "$VM_SH" scenario common --no-push
assert_exit 1 "$VM_SH" scenario clean-install --name absent --no-push
assert_contains "$DS_STDERR" 'not running'
assert_exit 1 "$VM_SH" push --name absent --source "$src"
assert_contains "$DS_STDERR" 'not running'
