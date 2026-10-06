# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The VM harness touches nothing before the owner has started the VM phase:
# every command that downloads, boots, connects to or removes a VM refuses
# without DOTSTEWARD_VM_PHASE=approved, before any file or tool call. The
# read-only commands work without it. Root and malformed names are refused.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image

[[ -x $VM_SH ]] || ds_fail "tests/vm/vm.sh is missing or not executable"

# Usage on standard output, exit 0, without approval.
unset DOTSTEWARD_VM_PHASE
assert_exit 0 "$VM_SH" --help
assert_contains "$DS_STDOUT" 'DOTSTEWARD_VM_PHASE=approved'
assert_contains "$DS_STDOUT" 'scenario'
assert_exit 0 "$VM_SH" help
assert_exit 2 "$VM_SH"
assert_contains "$DS_STDERR" 'usage'
assert_exit 2 "$VM_SH" frobnicate
assert_contains "$DS_STDERR" 'unknown command: frobnicate'

# Gated commands refuse without approval, and with any other value.
gated=(fetch up ssh push "scenario clean-install" down destroy)
for command in "${gated[@]}"; do
  read -r -a words <<<"$command"
  assert_exit 1 "$VM_SH" "${words[@]}"
  assert_contains "$DS_STDERR" 'DOTSTEWARD_VM_PHASE=approved' "$command without approval"
  assert_exit 1 env DOTSTEWARD_VM_PHASE=yes "$VM_SH" "${words[@]}"
  assert_contains "$DS_STDERR" 'DOTSTEWARD_VM_PHASE=approved' "$command with a wrong value"
done
[[ ! -e $DOTSTEWARD_VM_ROOT ]] || ds_fail "a refused command created the state root"
assert_calls

# Read-only commands need no approval and write nothing.
assert_exit 0 "$VM_SH" check
assert_contains "$DS_STDOUT" 'qemu-system-x86_64'
assert_contains "$DS_STDOUT" 'kvm'
assert_exit 0 "$VM_SH" plan --name probe --ssh-port 40100
assert_contains "$DS_STDOUT" 'qemu-system-x86_64'
assert_contains "$DS_STDOUT" 'accel=kvm'
assert_contains "$DS_STDOUT" "$DOTSTEWARD_VM_ROOT/runs/probe"
assert_exit 0 "$VM_SH" status
assert_contains "$DS_STDOUT" 'no VM'
[[ ! -e $DOTSTEWARD_VM_ROOT ]] || ds_fail "a read-only command created the state root"
assert_calls

# check fails when a required tool is missing.
mkdir -p "$DS_TEST_ROOT/emptybin"
assert_exit 1 env PATH="$DS_TEST_ROOT/emptybin:/usr/bin:/bin" DOTSTEWARD_VM_QEMU=qemu-missing-for-test \
  "$VM_SH" check
assert_contains "$DS_STDOUT" 'qemu-missing-for-test'

# Root is refused even with approval, before any QEMU call.
export DOTSTEWARD_VM_PHASE=approved
ds_use_stubs id
assert_exit 1 env DS_STUB_AS_ROOT=1 "$VM_SH" up
assert_contains "$DS_STDERR" 'root'
assert_call_count 0 qemu-system-x86_64
assert_call_count 0 qemu-img
assert_call_count 0 curl
[[ ! -e $DOTSTEWARD_VM_ROOT ]] || ds_fail "the root refusal created the state root"

# VM names are short lowercase words; anything else is a usage error.
for name in ../escape 'two words' UPPER '' -dash a/b "$(printf 'x%.0s' {1..40})"; do
  assert_exit 2 "$VM_SH" up --name "$name"
  assert_contains "$DS_STDERR" 'invalid VM name' "name [$name]"
done
assert_exit 2 "$VM_SH" up --memory lots
assert_exit 2 "$VM_SH" up --cpus 0
assert_exit 2 "$VM_SH" up --disk 40
assert_exit 2 "$VM_SH" up --ssh-port 70000
assert_exit 2 "$VM_SH" up --unknown-flag
[[ ! -e $DOTSTEWARD_VM_ROOT ]] || ds_fail "a usage error created the state root"
assert_call_count 0 qemu-system-x86_64
