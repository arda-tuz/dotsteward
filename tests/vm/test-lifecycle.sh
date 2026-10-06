# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# One VM from up to destroy with the fakes: the QEMU command line (KVM,
# loopback-only SSH forward, daemonized with a pid file, overlay disk on a
# read-only base), strict SSH options, the boot wait, status, ssh, a
# graceful and a forced down, a restart that keeps the disk, a pid file that
# names a foreign process, destroy. The host never runs sudo.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image
ds_use_stubs sudo

run=$(vm_run_dir)
image=$DOTSTEWARD_VM_ROOT/images/ubuntu-24.04-server-cloudimg-amd64-20990101.img
options=(--memory 4096 --cpus 2 --disk 20G --ssh-port 40222)

# plan prints the command line up will use, without writing anything.
assert_exit 0 "$VM_SH" plan "${options[@]}"
planned=$(grep '^qemu: ' <<<"$DS_STDOUT" | sed 's/^qemu: //')
[[ -n $planned ]] || ds_fail "plan printed no qemu line: [$DS_STDOUT]"
[[ ! -e $DOTSTEWARD_VM_ROOT ]] || ds_fail "plan wrote files"

# The guest needs two connection attempts before SSH answers.
vm_fake_set ssh fail_first 2
assert_exit 0 "$VM_SH" up "${options[@]}"
assert_contains "$DS_STDOUT" 'ready'
assert_contains "$DS_STDOUT" 'tests/vm/vm.sh ssh --name default'

qemu=$(ds_calls_of qemu-system-x86_64)
assert_eq 1 "$(wc -l <<<"$qemu")"
expected_options=(
  "-name dotsteward-default"
  "-machine q35,accel=kvm"
  "-cpu host"
  "-smp 2"
  "-m 4096"
  "-drive if=virtio,format=qcow2,file=$run/disk.qcow2,discard=unmap"
  "-drive if=virtio,format=raw,readonly=on,file=$run/seed.iso"
  "-netdev user,id=net0,hostfwd=tcp:127.0.0.1:40222-:22"
  "-device virtio-net-pci,netdev=net0"
  "-device virtio-rng-pci"
  "-display none"
  "-serial file:$run/console.log"
  "-monitor none"
  "-daemonize"
  "-pidfile $run/qemu.pid"
)
for option in "${expected_options[@]}"; do
  read -r flag value <<<"$option"
  if [[ -n $value ]]; then
    assert_contains "$qemu" "$(vm_quoted "$flag" "$value")" "qemu option"
  else
    assert_contains "$qemu" "$(vm_quoted "$flag")" "qemu option"
  fi
done
assert_not_contains "$qemu" 'hostfwd=tcp::' "a forward listens beyond loopback"
assert_eq "$planned" "$(<"$run/qemu.argv")" "plan and up disagree on the QEMU command line"
assert_eq kvm "$(<"$run/accel")"
assert_eq 40222 "$(<"$run/ssh-port")"

# The overlay is the only disk QEMU writes; the base stays read-only.
# (made in a temporary run directory that is renamed when complete)
assert_call_count 1 qemu-img "create -q -f qcow2 -F qcow2 -b $image $DOTSTEWARD_VM_ROOT/runs/.new-default.*/disk.qcow2 20G"
assert_file_mode "$image" 444
cmp -s "$VM_TEST_IMAGE_FILE" "$image" || ds_fail "the base image changed"

# Every SSH call is strict, isolated from the user's SSH configuration and
# bound to the run's key and pinned host key.
while IFS= read -r line; do
  for expected in '-F /dev/null' "-i $run/id_ed25519" '-p 40222' \
    '-o IdentitiesOnly=yes' '-o StrictHostKeyChecking=yes' \
    "-o UserKnownHostsFile=$run/known_hosts" '-o GlobalKnownHostsFile=/dev/null' \
    '-o HostKeyAlias=dotsteward-vm-default' 'stranger@127.0.0.1'; do
    assert_contains "$line" " $expected" "ssh option"
  done
done < <(ds_calls_of ssh)
commands=$(<"$DS_STUB_STATE/ssh/commands")
assert_contains "$commands" 'cloud-init status --wait'
assert_contains "$commands" 'test -f /etc/dotsteward-vm'
(($(grep -c $'\ttrue$' <<<"$commands") >= 3)) || ds_fail "up did not retry the connection: [$commands]"

# status and a second up.
assert_exit 0 "$VM_SH" status
assert_contains "$DS_STDOUT" 'default'
assert_contains "$DS_STDOUT" 'running'
assert_contains "$DS_STDOUT" '40222'
assert_contains "$DS_STDOUT" 'kvm'
assert_exit 1 "$VM_SH" up
assert_contains "$DS_STDERR" 'already running'
assert_call_count 1 qemu-system-x86_64

# ssh runs a command and passes its exit status through.
vm_fake_set ssh command_exit 7
assert_exit 7 "$VM_SH" ssh -- uname -a
assert_contains "$(tail -n 1 "$DS_STUB_STATE/ssh/commands")" $'\tuname -a'
vm_fake_set ssh command_exit 0
# Arguments keep their word boundaries in the remote shell.
assert_exit 0 "$VM_SH" ssh -- printf '%s\n' 'two words'
assert_contains "$(tail -n 1 "$DS_STUB_STATE/ssh/commands")" "printf %s\\\\n two\\ words"

# A graceful down asks the guest to power off, then stops QEMU after the
# shutdown timeout when it is still running.
pid=$(<"$run/qemu.pid")
kill -0 "$pid" || ds_fail "fake QEMU is not running"
disk_before=$(sha256sum "$run/disk.qcow2" "$run/id_ed25519" "$run/host_ed25519")
assert_exit 0 "$VM_SH" down
assert_contains "$(<"$DS_STUB_STATE/ssh/commands")" 'sudo systemctl poweroff'
for _ in $(seq 1 50); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$pid" 2>/dev/null || ds_fail "down left QEMU running"
[[ ! -e $run/qemu.pid ]] || ds_fail "down left the pid file"
assert_exit 0 "$VM_SH" status
assert_contains "$DS_STDOUT" 'stopped'

# up on a stopped run boots the same disk and keys again.
assert_exit 0 "$VM_SH" up
assert_call_count 2 qemu-system-x86_64
assert_call_count 1 qemu-img
assert_eq "$disk_before" "$(sha256sum "$run/disk.qcow2" "$run/id_ed25519" "$run/host_ed25519")"
assert_eq 40222 "$(<"$run/ssh-port")" "the restart keeps the SSH port"

# A forced down skips the guest.
poweroffs=$(grep -c 'poweroff' "$DS_STUB_STATE/ssh/commands")
pid=$(<"$run/qemu.pid")
assert_exit 0 "$VM_SH" down --force
assert_eq "$poweroffs" "$(grep -c 'poweroff' "$DS_STUB_STATE/ssh/commands")"
for _ in $(seq 1 50); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$pid" 2>/dev/null || ds_fail "down --force left QEMU running"
assert_exit 0 "$VM_SH" down
assert_contains "$DS_STDOUT" 'not running'

# A pid file that names some other process is never acted on.
sleep 300 >/dev/null 2>&1 &
foreign=$!
ds_defer kill "$foreign"
printf '%s\n' "$foreign" >"$run/qemu.pid"
assert_exit 0 "$VM_SH" status
assert_contains "$DS_STDOUT" 'stopped'
assert_exit 0 "$VM_SH" down
assert_contains "$DS_STDERR" 'not a QEMU process of this run'
kill -0 "$foreign" 2>/dev/null || ds_fail "down killed a foreign process"
[[ ! -e $run/qemu.pid ]] || ds_fail "the stale pid file was kept"

# destroy removes the run and keeps the base image.
assert_exit 0 "$VM_SH" up
pid=$(<"$run/qemu.pid")
assert_exit 0 "$VM_SH" destroy
[[ ! -e $run ]] || ds_fail "destroy left the run directory"
! kill -0 "$pid" 2>/dev/null || ds_fail "destroy left QEMU running"
assert_file_mode "$image" 444
cmp -s "$VM_TEST_IMAGE_FILE" "$image" || ds_fail "destroy changed the base image"
assert_exit 0 "$VM_SH" destroy
assert_contains "$DS_STDOUT" 'nothing to destroy'

# destroy refuses a run directory that is a symlink.
mkdir -p "$DS_TEST_ROOT/elsewhere"
ln -s "$DS_TEST_ROOT/elsewhere" "$(vm_run_dir linked)"
assert_exit 1 "$VM_SH" destroy --name linked
[[ -d $DS_TEST_ROOT/elsewhere ]] || ds_fail "destroy followed a symlink"

# The host never ran sudo.
assert_call_count 0 sudo
