# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the VM harness tests (tests/vm/test-*.sh). A test sources this
# file after the harness has started (tests/run.sh loads harness.sh and
# assert.sh first) and calls vm_test_init.
#
# The tests never boot a virtual machine: tests/vm/fakes holds stand-ins for
# qemu-system-x86_64, qemu-img, ssh, xorriso and genisoimage that record
# every call in DS_CALL_LOG (one "NAME ARG..." line, as the harness stubs
# do) and behave as the files in DS_STUB_STATE/<fake>/ say (vm_fake_set).
# Downloads go through the harness curl stub. ssh-keygen and git are real.
#
#   vm_test_init [FAKE...] environment for tests/vm/vm.sh: state root, a
#                          readable and writable stand-in for /dev/kvm, no
#                          poll delay, approval set, and the named fakes
#                          (default: all) first on PATH
#   vm_fake_set NAME KEY VALUE
#                          a behaviour value of a fake (see each fake)
#   vm_fake_image [SERIAL [FILE]]
#                          FILE (default: a small generated file) served as
#                          the cloud image by the curl stub, and a lock
#                          file pointing at it (DOTSTEWARD_VM_IMAGE_LOCK);
#                          sets VM_TEST_IMAGE_URL, VM_TEST_IMAGE_SHA256,
#                          VM_TEST_IMAGE_SIZE and VM_TEST_IMAGE_FILE
#   vm_run_dir [NAME]      the run directory of NAME (default "default")
#   vm_kill_fakes          stops every fake QEMU process of the test (runs
#                          automatically when the test exits)
#   vm_framework_repo DIR  a small committed git repository standing in for
#                          the framework checkout pushed into the guest
#   vm_quoted ARG...       the arguments as the call log writes them (each
#                          preceded by a space and quoted with printf %q)

# shellcheck disable=SC2034 # read by the test files that source this file
VM_SH=$DS_REPO_ROOT/tests/vm/vm.sh
VM_FAKES=$DS_REPO_ROOT/tests/vm/fakes
VM_FAKE_NAMES="qemu-system-x86_64 qemu-img ssh xorriso genisoimage"

# shellcheck disable=SC2120 # the fake names are optional
vm_test_init() {
  export DOTSTEWARD_VM_ROOT=$DS_TEST_ROOT/vm-root
  export DOTSTEWARD_VM_KVM_DEVICE=$DS_TEST_ROOT/kvm
  : >"$DOTSTEWARD_VM_KVM_DEVICE"
  chmod 0600 "$DOTSTEWARD_VM_KVM_DEVICE"
  export DOTSTEWARD_VM_POLL_INTERVAL=0
  export DOTSTEWARD_VM_SHUTDOWN_TIMEOUT=1
  export DOTSTEWARD_VM_PHASE=approved
  local name names=("$@") bin=$DS_TEST_ROOT/vm-fakes
  ((${#names[@]})) || read -r -a names <<<"$VM_FAKE_NAMES"
  mkdir -p "$bin"
  for name in "${names[@]}"; do
    [[ " $VM_FAKE_NAMES " == *" $name "* ]] || {
      printf 'vm_test_init: unknown fake: %s\n' "$name" >&2
      return 1
    }
    mkdir -p "$DS_STUB_STATE/$name"
    ln -sfn "$VM_FAKES/$name" "$bin/$name"
  done
  export PATH=$bin:$PATH
  hash -r
  ds_defer vm_kill_fakes
}

vm_fake_set() {
  (($# == 3)) || {
    printf 'vm_fake_set: usage: vm_fake_set NAME KEY VALUE\n' >&2
    return 1
  }
  [[ " $VM_FAKE_NAMES " == *" $1 "* ]] || {
    printf 'vm_fake_set: unknown fake: %s\n' "$1" >&2
    return 1
  }
  mkdir -p "$DS_STUB_STATE/$1"
  printf '%s\n' "$3" >"$DS_STUB_STATE/$1/$2"
}

# shellcheck disable=SC2120 # the serial and the file are optional
vm_fake_image() {
  local serial=${1:-20990101}
  ds_use_stubs curl
  VM_TEST_IMAGE_FILE=$DS_TEST_ROOT/image-source-$serial.img
  if (($# >= 2)); then
    cp -- "$2" "$VM_TEST_IMAGE_FILE"
  else
    # A recognisable, non-empty payload; the fakes never look inside it.
    printf 'fake cloud image %s\n' "$serial" >"$VM_TEST_IMAGE_FILE"
    head -c 4096 /dev/zero >>"$VM_TEST_IMAGE_FILE"
  fi
  VM_TEST_IMAGE_URL=https://images.example.invalid/noble/release-$serial/ubuntu-24.04-server-cloudimg-amd64.img
  VM_TEST_IMAGE_SHA256=$(sha256sum "$VM_TEST_IMAGE_FILE" | cut -d' ' -f1)
  VM_TEST_IMAGE_SIZE=$(stat -c %s "$VM_TEST_IMAGE_FILE")
  ds_curl_serve "$VM_TEST_IMAGE_URL" "$VM_TEST_IMAGE_FILE"
  export DOTSTEWARD_VM_IMAGE_LOCK=$DS_TEST_ROOT/image.lock
  cat >"$DOTSTEWARD_VM_IMAGE_LOCK" <<EOF
# test lock
release=24.04
serial=$serial
url=$VM_TEST_IMAGE_URL
size=$VM_TEST_IMAGE_SIZE
sha256=$VM_TEST_IMAGE_SHA256
EOF
  export VM_TEST_IMAGE_FILE VM_TEST_IMAGE_URL VM_TEST_IMAGE_SHA256 VM_TEST_IMAGE_SIZE
}

vm_run_dir() {
  printf '%s\n' "$DOTSTEWARD_VM_ROOT/runs/${1:-default}"
}

# The fake QEMU process carries "fake-qemu" and its pid file path in its
# command line; only such processes are stopped.
vm_kill_fakes() {
  local pidfile pid
  for pidfile in "$DOTSTEWARD_VM_ROOT"/runs/*/qemu.pid "$DS_TEST_ROOT"/fake-pids/*; do
    [[ -f $pidfile ]] || continue
    pid=$(<"$pidfile")
    [[ $pid =~ ^[0-9]+$ ]] || continue
    if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'fake-qemu'; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

vm_framework_repo() {
  local dir=$1
  mkdir -p "$dir/tests/vm/guest"
  git -C "$dir" init -q -b main
  printf 'framework stand-in\n' >"$dir/README.md"
  printf '#!/usr/bin/env bash\necho guest\n' >"$dir/tests/vm/guest/clean-install.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m 'chore: framework stand-in'
}

vm_quoted() {
  printf ' %q' "$@"
}
