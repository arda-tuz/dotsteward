# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The harness against the real disk and ISO tools of this machine, still
# without booting anything: the qemu-img overlay is a qcow2 backed by the
# base image with the requested size, the xorriso seed is an ISO 9660 image
# with the NoCloud volume id carrying byte-identical user-data and
# meta-data, and the installed QEMU knows every machine type, accelerator
# and device the command line names. Missing tools are reported and their
# part is skipped.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"

real_tool() { # NAME: the tool's path on PATH outside the fakes, if any
  local path
  while IFS= read -r path; do
    [[ $path == "$VM_FAKES"/* || $path == "$DS_TEST_ROOT"/* ]] && continue
    printf '%s\n' "$path"
    return 0
  done < <(type -aP "$1")
  return 1
}

qemu_img=$(real_tool qemu-img) || qemu_img=""
xorriso=$(real_tool xorriso) || xorriso=""
qemu_system=$(real_tool qemu-system-x86_64) || qemu_system=""

if [[ -n $qemu_system ]]; then
  machines=$("$qemu_system" -machine help)
  assert_contains "$machines" 'q35'
  accels=$("$qemu_system" -accel help)
  assert_contains "$accels" 'kvm'
  assert_contains "$accels" 'tcg'
  devices=$("$qemu_system" -device help)
  for device in virtio-net-pci virtio-rng-pci virtio-blk-pci; do
    assert_contains "$devices" "\"$device\"" "QEMU device"
  done
else
  printf 'SKIP: qemu-system-x86_64 not installed, QEMU capability checks skipped\n'
fi

if [[ -z $qemu_img || -z $xorriso ]]; then
  printf 'SKIP: qemu-img or xorriso not installed, real overlay and seed checks skipped\n'
  exit 0
fi

# Only QEMU itself and ssh are fakes here.
vm_test_init qemu-system-x86_64 ssh
base=$DS_TEST_ROOT/base.qcow2
"$qemu_img" create -q -f qcow2 "$base" 64M
vm_fake_image 20990101 "$base"
export DOTSTEWARD_VM_ISO_TOOL=xorriso

assert_exit 0 "$VM_SH" up --disk 2G
run=$(vm_run_dir)
image=$DOTSTEWARD_VM_ROOT/images/ubuntu-24.04-server-cloudimg-amd64-20990101.img

info=$("$qemu_img" info --output=json "$run/disk.qcow2")
assert_json - '.format == "qcow2"' <<<"$info"
assert_json - ".[\"backing-filename\"] == \"$image\"" <<<"$info"
assert_json - '.["backing-filename-format"] == "qcow2"' <<<"$info"
assert_json - ".[\"virtual-size\"] == $((2 * 1024 * 1024 * 1024))" <<<"$info"
cmp -s "$base" "$image" || ds_fail "creating the overlay changed the base image"

pvd=$("$xorriso" -indev "$run/seed.iso" -pvd_info 2>&1)
assert_contains "$pvd" "Volume Id    : cidata"
mkdir -p "$DS_TEST_ROOT/extracted"
"$xorriso" -osirrox on -indev "$run/seed.iso" \
  -extract /user-data "$DS_TEST_ROOT/extracted/user-data" \
  -extract /meta-data "$DS_TEST_ROOT/extracted/meta-data" >/dev/null 2>&1 ||
  ds_fail "the seed image does not contain user-data and meta-data"
cmp -s "$run/seed/user-data" "$DS_TEST_ROOT/extracted/user-data" || ds_fail "user-data differs on the ISO"
cmp -s "$run/seed/meta-data" "$DS_TEST_ROOT/extracted/meta-data" || ds_fail "meta-data differs on the ISO"

# The generated keys are real OpenSSH keys.
ssh-keygen -l -f "$run/id_ed25519.pub" >/dev/null || ds_fail "the client key is not readable"
ssh-keygen -l -f "$run/host_ed25519.pub" >/dev/null || ds_fail "the host key is not readable"
assert_eq "$(ssh-keygen -y -f "$run/host_ed25519" | cut -d' ' -f1,2)" "$(cut -d' ' -f1,2 "$run/host_ed25519.pub")"

assert_exit 0 "$VM_SH" destroy
cmp -s "$base" "$image" || ds_fail "destroy changed the base image"
