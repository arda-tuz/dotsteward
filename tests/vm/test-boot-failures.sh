# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Boot failures surface with the evidence needed to debug them: no KVM
# without --allow-tcg, QEMU refusing to start, a VM that dies, a guest that
# never answers SSH within the boot timeout, cloud-init errors and a guest
# without the harness marker.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image

# Without a usable /dev/kvm the harness refuses unless TCG is allowed.
export DOTSTEWARD_VM_KVM_DEVICE=$DS_TEST_ROOT/no-kvm
assert_exit 1 "$VM_SH" up --name tcg
assert_contains "$DS_STDERR" 'KVM'
assert_contains "$DS_STDERR" '--allow-tcg'
[[ ! -e $(vm_run_dir tcg) ]] || ds_fail "the KVM refusal left a run directory"
assert_call_count 0 qemu-system-x86_64
assert_exit 0 "$VM_SH" up --name tcg --allow-tcg
assert_contains "$DS_STDERR" 'TCG'
qemu=$(ds_calls_of qemu-system-x86_64)
assert_contains "$qemu" "$(vm_quoted -machine q35,accel=tcg)"
assert_contains "$qemu" '-cpu max'
assert_eq tcg "$(<"$(vm_run_dir tcg)/accel")"
# A restart of a TCG run keeps TCG without the flag.
assert_exit 0 "$VM_SH" down --name tcg --force
assert_exit 0 "$VM_SH" up --name tcg
assert_contains "$(ds_calls_of qemu-system-x86_64 | tail -n 1)" "$(vm_quoted q35,accel=tcg)"
assert_exit 0 "$VM_SH" destroy --name tcg
export DOTSTEWARD_VM_KVM_DEVICE=$DS_TEST_ROOT/kvm

# QEMU refuses to start: its message is shown.
vm_fake_set qemu-system-x86_64 fail 'qemu-system-x86_64: could not open disk image'
assert_exit 1 "$VM_SH" up --name broken
assert_contains "$DS_STDERR" 'could not open disk image'
rm -f "$DS_STUB_STATE/qemu-system-x86_64/fail"
assert_exit 0 "$VM_SH" destroy --name broken

# The VM dies while booting: the console tail is shown, no SSH wait.
vm_fake_set qemu-system-x86_64 crash 1
ssh_calls=$(ds_call_count ssh)
assert_exit 1 "$VM_SH" up --name crash
assert_contains "$DS_STDERR" 'QEMU exited'
assert_contains "$DS_STDERR" 'fake console: cloud-init started'
assert_call_count "$ssh_calls" ssh
assert_exit 0 "$VM_SH" status --name crash
assert_contains "$DS_STDOUT" 'stopped'
rm -f "$DS_STUB_STATE/qemu-system-x86_64/crash"
assert_exit 0 "$VM_SH" destroy --name crash

# SSH never answers: the boot timeout ends the wait, the VM is kept for
# inspection and the message says how to stop it.
vm_fake_set ssh never_ready 1
assert_exit 1 "$VM_SH" up --name slow --boot-timeout 1
assert_contains "$DS_STDERR" 'not reachable over SSH within 1 s'
assert_contains "$DS_STDERR" 'fake console: firmware'
assert_contains "$DS_STDERR" 'tests/vm/vm.sh down --name slow'
assert_exit 0 "$VM_SH" status --name slow
assert_contains "$DS_STDOUT" 'running'
rm -f "$DS_STUB_STATE/ssh/never_ready"
assert_exit 0 "$VM_SH" destroy --name slow
assert_exit 2 "$VM_SH" up --name slow --boot-timeout 0

# cloud-init: exit 2 (recoverable errors) warns, anything else fails.
vm_fake_set ssh cloud_init_exit 2
assert_exit 0 "$VM_SH" up --name degraded
assert_contains "$DS_STDERR" 'cloud-init finished with recoverable errors'
assert_exit 0 "$VM_SH" destroy --name degraded
vm_fake_set ssh cloud_init_exit 1
assert_exit 1 "$VM_SH" up --name failed
assert_contains "$DS_STDERR" 'cloud-init failed'
assert_exit 0 "$VM_SH" destroy --name failed
vm_fake_set ssh cloud_init_exit 0

# A guest without the marker is not one of ours.
vm_fake_set ssh marker_exit 1
assert_exit 1 "$VM_SH" up --name foreign
assert_contains "$DS_STDERR" '/etc/dotsteward-vm'
assert_exit 0 "$VM_SH" destroy --name foreign

# A disk creation failure leaves no half-made run behind.
vm_fake_set qemu-img fail 'qemu-img: disk full'
assert_exit 1 "$VM_SH" up --name nodisk
assert_contains "$DS_STDERR" 'disk full'
[[ ! -e $(vm_run_dir nodisk) ]] || ds_fail "a failed disk creation left a run directory"
