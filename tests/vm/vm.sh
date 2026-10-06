#!/usr/bin/env bash
# QEMU harness for the dotsteward VM phase: disposable Ubuntu 24.04 VMs on
# this machine, as an unprivileged user, for the clean-install scenario and
# the agentic end-to-end test of dotsteward-init. See tests/vm/README.md.
#
# The VM phase starts only after the owner has approved it. Until then the
# commands that download, boot, connect to or remove a VM refuse to run, and
# tests/vm/selftest.sh checks the harness with fakes, never booting a VM.
set -Eeuo pipefail
umask 077

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
framework_root=$(cd "$script_dir/../.." && pwd -P)
# Verified downloads (download_verified, sha256_file) come from the
# framework library.
# shellcheck source=cli/lib/lib.sh
source "$framework_root/cli/lib/lib.sh"

readonly guest_user=stranger
readonly guest_hostname=dotsteward-vm
readonly guest_marker=/etc/dotsteward-vm
readonly guest_checkout=dotsteward-src
readonly image_release=24.04
readonly image_name=ubuntu-24.04-server-cloudimg-amd64.img
readonly iso_tools=(xorriso genisoimage mkisofs cloud-localds)

vm_root=${DOTSTEWARD_VM_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/dotsteward-vm}
image_lock=${DOTSTEWARD_VM_IMAGE_LOCK:-$script_dir/image.lock}
image_index=${DOTSTEWARD_VM_IMAGE_INDEX:-https://cloud-images.ubuntu.com/releases/noble}
kvm_device=${DOTSTEWARD_VM_KVM_DEVICE:-/dev/kvm}
qemu_bin=${DOTSTEWARD_VM_QEMU:-qemu-system-x86_64}
poll_interval=${DOTSTEWARD_VM_POLL_INTERVAL:-3}
shutdown_timeout=${DOTSTEWARD_VM_SHUTDOWN_TIMEOUT:-60}

usage() {
  cat <<'EOF'
Usage: tests/vm/vm.sh COMMAND [OPTIONS]

Disposable Ubuntu 24.04 VMs (QEMU, KVM, user-mode network, cloud-init) for
the dotsteward VM phase. Runs as a normal user and never uses sudo on the
host; the guest user "stranger" has passwordless sudo inside the VM.

Read-only commands (no approval needed):
  help                 this text
  check                host readiness: tools, KVM access, free space
  plan [RUN OPTIONS]   the files and the QEMU command line `up` would use
  status [--name N]    state of one VM, or of every VM
  pin [--write]        resolve the current Ubuntu 24.04 release image and
                       print its lock (--write replaces tests/vm/image.lock)
  scenario --list      the scenarios (guest scripts in tests/vm/guest)

Commands of the VM phase (need DOTSTEWARD_VM_PHASE=approved):
  fetch                download and verify the pinned base image
  up [RUN OPTIONS]     create (or restart) a VM and wait until SSH and
                       cloud-init are ready
  ssh [--name N] [-- COMMAND...]
                       a shell in the VM, or COMMAND (exit status kept)
  push [--name N] [--source DIR] [--ref REV]
                       ship a committed framework revision (default: HEAD of
                       this checkout) to ~/dotsteward-src in the VM
  scenario NAME [--name N] [--source DIR] [--ref REV] [--no-push] [-- ARGS]
                       push, then run tests/vm/guest/NAME.sh in the VM; the
                       session is logged in the run directory
  down [--name N] [--force]
                       power the VM off (--force: stop QEMU right away)
  destroy [--name N]   stop the VM and delete its run directory (the base
                       image is kept)

Run options:
  --name N             VM name: lowercase letters, digits, dashes (default
                       "default")
  --memory MIB         guest memory in MiB (default 6144)
  --cpus N             virtual CPUs (default: up to 4)
  --disk SIZE          overlay disk size, for example 40G (default 40G)
  --ssh-port PORT      host port forwarded to the guest's SSH (default: a
                       free port; kept across restarts)
  --boot-timeout S     seconds to wait for SSH (default 900, 3600 with TCG)
  --allow-tcg          boot without KVM (slow software emulation)

Environment:
  DOTSTEWARD_VM_PHASE=approved   set only after the owner approved the VM
                                 phase
  DOTSTEWARD_VM_ROOT             images and runs (default
                                 ${XDG_CACHE_HOME:-~/.cache}/dotsteward-vm)
  DOTSTEWARD_VM_IMAGE_LOCK       base image pin (default tests/vm/image.lock)
  DOTSTEWARD_VM_IMAGE_INDEX      release index read by `pin`
  DOTSTEWARD_VM_ISO_TOOL         seed image tool: xorriso, genisoimage,
                                 mkisofs or cloud-localds (name or path;
                                 default: the first one found)
  DOTSTEWARD_VM_QEMU             QEMU system emulator (default
                                 qemu-system-x86_64)
  DOTSTEWARD_VM_KVM_DEVICE       KVM device (default /dev/kvm)

Exit status: 0 success, 1 failure or refusal, 2 usage error; `ssh` and
`scenario` pass the guest command's status through.
EOF
}

# Messages carry the harness prefix; lib.sh helpers use these too.
log() {
  printf '[dotsteward-vm] %s\n' "$*"
}

warn() {
  printf '[dotsteward-vm] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[dotsteward-vm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf '[dotsteward-vm] usage error: %s\n' "$*" >&2
  printf "Run 'tests/vm/vm.sh help' for usage.\n" >&2
  exit 2
}

# Paths removed when the script exits (temporary downloads and half-made
# run directories); remove_pending checks each against its allowed parent.
pending=()
remove_pending() {
  local path
  for path in "${pending[@]}"; do
    [[ -n $path && ! -L $path ]] || continue
    case $path in
      "$vm_root"/images/.download.* | "$vm_root"/runs/.new-* | "$vm_root"/runs/*/.bundle.*)
        chmod -R u+w -- "$path" 2>/dev/null || true
        rm -rf -- "$path"
        ;;
    esac
  done
}
trap remove_pending EXIT

forget_pending() {
  local path kept=()
  for path in "${pending[@]}"; do
    [[ $path == "$1" ]] || kept+=("$path")
  done
  pending=("${kept[@]}")
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

command=""
name=default
name_given=0
memory=""
cpus=""
disk=""
ssh_port=""
boot_timeout=""
allow_tcg=0
force=0
write_lock=0
source_dir=""
ref=HEAD
no_push=0
list_scenarios=0
scenario=""
extra_args=()

# allowed COMMAND OPTION: the options each command takes.
allowed() {
  local run_options="--name --memory --cpus --disk --ssh-port --boot-timeout --allow-tcg"
  local options
  case $1 in
    plan | up) options=$run_options ;;
    status | ssh) options="--name" ;;
    down) options="--name --force" ;;
    destroy) options="--name" ;;
    pin) options="--write" ;;
    push) options="--name --source --ref" ;;
    scenario) options="--name --source --ref --no-push --list" ;;
    *) options="" ;;
  esac
  [[ " $options " == *" $2 "* ]]
}

parse_options() {
  local option value
  while (($#)); do
    option=$1
    value=""
    if [[ $option == --*=* ]]; then
      value=${option#*=}
      option=${option%%=*}
      set -- "$option" "$value" "${@:2}"
    fi
    if [[ $option == -- ]]; then
      shift
      extra_args=("$@")
      break
    fi
    if [[ $option != -* ]]; then
      [[ $command == scenario && -z $scenario ]] || usage_error "unexpected argument: $option"
      scenario=$option
      shift
      continue
    fi
    allowed "$command" "$option" || usage_error "$command does not take $option"
    case $option in
      --allow-tcg | --force | --write | --no-push | --list)
        case $option in
          --allow-tcg) allow_tcg=1 ;;
          --force) force=1 ;;
          --write) write_lock=1 ;;
          --no-push) no_push=1 ;;
          --list) list_scenarios=1 ;;
        esac
        shift
        continue
        ;;
    esac
    (($# >= 2)) || usage_error "$option needs a value"
    value=$2
    case $option in
      --name)
        name=$value
        name_given=1
        ;;
      --memory) memory=$value ;;
      --cpus) cpus=$value ;;
      --disk) disk=$value ;;
      --ssh-port) ssh_port=$value ;;
      --boot-timeout) boot_timeout=$value ;;
      --source) source_dir=$value ;;
      --ref) ref=$value ;;
    esac
    shift 2
  done

  [[ $name =~ ^[a-z][a-z0-9-]{0,30}$ ]] || usage_error "invalid VM name: '$name' (lowercase letters, digits and dashes, at most 31 characters, starting with a letter)"
  [[ -z $memory || ($memory =~ ^[1-9][0-9]*$ && memory -ge 1024) ]] ||
    usage_error "--memory takes MiB, at least 1024: $memory"
  [[ -z $cpus || ($cpus =~ ^[1-9][0-9]*$ && cpus -le 64) ]] || usage_error "--cpus takes 1 to 64: $cpus"
  [[ -z $disk || $disk =~ ^[1-9][0-9]*[GT]$ ]] || usage_error "--disk takes a size such as 40G: $disk"
  [[ -z $ssh_port || ($ssh_port =~ ^[1-9][0-9]*$ && ssh_port -ge 1024 && ssh_port -le 65535) ]] ||
    usage_error "--ssh-port takes 1024 to 65535: $ssh_port"
  [[ -z $boot_timeout || $boot_timeout =~ ^[1-9][0-9]*$ ]] ||
    usage_error "--boot-timeout takes a positive number of seconds: $boot_timeout"
  if [[ $command == scenario && $list_scenarios == 0 ]]; then
    [[ -n $scenario ]] || usage_error "scenario needs a NAME (see: tests/vm/vm.sh scenario --list)"
    known_scenario "$scenario" ||
      usage_error "unknown scenario: $scenario (known: $(list_scenario_names | paste -sd ' '))"
  fi
  if ((${#extra_args[@]})) && [[ $command != ssh && $command != scenario ]]; then
    usage_error "$command takes no arguments after --"
  fi
}

# ---------------------------------------------------------------------------
# Guards and host checks
# ---------------------------------------------------------------------------

require_approval() {
  [[ ${DOTSTEWARD_VM_PHASE:-} == approved ]] ||
    die "the VM phase has not been approved: '$command' runs only with DOTSTEWARD_VM_PHASE=approved, set after the owner started the VM phase"
}

require_not_root() {
  [[ $(id -u) != 0 ]] || die "do not run the VM harness as root: it runs as a normal user and never uses sudo on the host"
}

require_safe_root() {
  [[ $vm_root == /* ]] || die "DOTSTEWARD_VM_ROOT must be an absolute path: $vm_root"
  # QEMU option values are comma-separated; a comma in a path would split it.
  [[ $vm_root != *,* ]] || die "DOTSTEWARD_VM_ROOT must not contain a comma: $vm_root"
}

require_tools() {
  local tool
  for tool in "$qemu_bin" qemu-img ssh ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool (see tests/vm/vm.sh check)"
  done
}

kvm_usable() {
  [[ -c $kvm_device || -f $kvm_device ]] && [[ -r $kvm_device && -w $kvm_device ]]
}

# iso_tool: the seed image tool (DOTSTEWARD_VM_ISO_TOOL, else the first of
# the supported tools found on PATH).
iso_tool() {
  local tool
  if [[ -n ${DOTSTEWARD_VM_ISO_TOOL:-} ]]; then
    tool=$DOTSTEWARD_VM_ISO_TOOL
    [[ " ${iso_tools[*]} " == *" $(basename -- "$tool") "* ]] ||
      die "DOTSTEWARD_VM_ISO_TOOL: unsupported tool $tool (use ${iso_tools[*]})"
    command -v "$tool" >/dev/null 2>&1 || die "DOTSTEWARD_VM_ISO_TOOL: $tool not found"
    printf '%s\n' "$tool"
    return 0
  fi
  for tool in "${iso_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
      return 0
    fi
  done
  die "no seed image tool found: install one of ${iso_tools[*]}"
}

cmd_check() {
  local missing=0 tool path probe free_kib
  printf 'VM harness host check\n'
  for tool in "$qemu_bin" qemu-img ssh ssh-keygen git python3; do
    if path=$(command -v "$tool" 2>/dev/null); then
      printf '  ok       %-20s %s\n' "$tool" "$path"
    else
      printf '  MISSING  %s\n' "$tool"
      missing=1
    fi
  done
  if tool=$( (iso_tool) 2>/dev/null); then
    printf '  ok       %-20s %s\n' 'seed image tool' "$tool"
  else
    printf '  MISSING  seed image tool (one of %s)\n' "${iso_tools[*]}"
    missing=1
  fi
  if kvm_usable; then
    printf '  ok       %-20s %s is readable and writable\n' kvm "$kvm_device"
  else
    printf '  warning  %-20s %s is not usable; up needs --allow-tcg (slow)\n' kvm "$kvm_device"
  fi
  probe=$vm_root
  while [[ ! -d $probe && $probe != / ]]; do
    probe=$(dirname -- "$probe")
  done
  free_kib=$(df -Pk -- "$probe" | awk 'NR == 2 { print $4 }')
  if [[ $free_kib =~ ^[0-9]+$ ]] && ((free_kib < 20 * 1024 * 1024)); then
    printf '  warning  %-20s %s GiB free at %s (a VM needs up to 20 GiB)\n' 'free space' $((free_kib / 1024 / 1024)) "$probe"
  else
    printf '  ok       %-20s %s GiB free at %s\n' 'free space' $((${free_kib:-0} / 1024 / 1024)) "$probe"
  fi
  printf '  state    %-20s %s\n' 'state root' "$vm_root"
  if [[ ${DOTSTEWARD_VM_PHASE:-} == approved ]]; then
    printf '  state    %-20s approved\n' 'VM phase'
  else
    printf '  state    %-20s not approved (DOTSTEWARD_VM_PHASE=approved is not set)\n' 'VM phase'
  fi
  return "$missing"
}

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

lock_release="" lock_serial="" lock_url="" lock_size="" lock_sha256=""

load_lock() {
  local line key value
  local -A seen=()
  [[ -f $image_lock && -r $image_lock ]] || die "image lock not found: $image_lock"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line == '#'* ]] && continue
    [[ $line =~ ^([a-z0-9]+)=(.*)$ ]] || die "image lock $image_lock: malformed line: $line"
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]:-} ]] || die "image lock $image_lock: duplicate key: $key"
    seen[$key]=1
    case $key in
      release) lock_release=$value ;;
      serial) lock_serial=$value ;;
      url) lock_url=$value ;;
      size) lock_size=$value ;;
      sha256) lock_sha256=$value ;;
      *) die "image lock $image_lock: unknown key: $key" ;;
    esac
  done <"$image_lock"
  for key in release serial url size sha256; do
    [[ -n ${seen[$key]:-} ]] || die "image lock $image_lock: missing key: $key"
  done
  [[ $lock_release == "$image_release" ]] || die "image lock $image_lock: release must be $image_release: $lock_release"
  [[ $lock_serial =~ ^[0-9]{8}(\.[0-9]+)?$ ]] || die "image lock $image_lock: invalid serial: $lock_serial"
  [[ $lock_url =~ ^https://[^[:space:]]+$ ]] || die "image lock $image_lock: url must be an https URL: $lock_url"
  [[ $lock_url == */"$image_name" ]] || die "image lock $image_lock: url must name $image_name: $lock_url"
  [[ $lock_size =~ ^[1-9][0-9]*$ ]] || die "image lock $image_lock: invalid size: $lock_size"
  [[ $lock_sha256 =~ ^[0-9a-f]{64}$ ]] || die "image lock $image_lock: invalid sha256: $lock_sha256"
}

image_path() {
  printf '%s\n' "$vm_root/images/${image_name%.img}-$lock_serial.img"
}

image_verified() {
  [[ -f $1 && ! -L $1 ]] &&
    [[ $(stat -c %s -- "$1") == "$lock_size" ]] &&
    [[ $(sha256_file "$1") == "$lock_sha256" ]]
}

# ensure_image: the pinned base image, verified, read-only, in the cache.
ensure_image() {
  load_lock
  local image download
  image=$(image_path)
  mkdir -p -- "$vm_root/images"
  if [[ -e $image || -L $image ]]; then
    if image_verified "$image"; then
      log "cached base image verified: $image"
      return 0
    fi
    warn "cached base image fails verification, downloading it again: $image"
    chmod u+w -- "$image" 2>/dev/null || true
    rm -f -- "$image"
  fi
  log "downloading Ubuntu $lock_release cloud image $lock_serial ($lock_size bytes)"
  download=$(mktemp "$vm_root/images/.download.XXXXXX")
  pending+=("$download")
  download_verified "$lock_url" "$download" "$lock_size" "$lock_sha256" ||
    die "download failed: $lock_url"
  chmod 0444 -- "$download"
  mv -f -- "$download" "$image"
  forget_pending "$download"
  log "base image downloaded and verified: $image"
}

https_get() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 3 --retry-delay 5 "$@"
}

cmd_pin() {
  local build_info serial sums sha256 url headers size content tmp
  [[ $image_index =~ ^https://[^[:space:]]+$ ]] || die "DOTSTEWARD_VM_IMAGE_INDEX must be an https URL: $image_index"
  image_index=${image_index%/}
  build_info=$(https_get "$image_index/release/unpacked/build-info.txt") ||
    die "cannot read $image_index/release/unpacked/build-info.txt"
  serial=$(sed -n 's/^serial=//p' <<<"$build_info" | head -n 1)
  [[ $serial =~ ^[0-9]{8}(\.[0-9]+)?$ ]] || die "no release serial in build-info.txt: '$serial'"
  sums=$(https_get "$image_index/release-$serial/SHA256SUMS") ||
    die "cannot read $image_index/release-$serial/SHA256SUMS"
  sha256=$(awk -v file="$image_name" '$2 == file || $2 == "*" file { print $1 }' <<<"$sums")
  [[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS of release $serial has no single entry for $image_name"
  url=$image_index/release-$serial/$image_name
  headers=$(https_get --head "$url") || die "cannot read the size of $url"
  size=$(tr -d '\r' <<<"$headers" | awk 'tolower($1) == "content-length:" { value = $2 } END { print value }')
  [[ $size =~ ^[1-9][0-9]*$ ]] || die "no content length for $url"
  content=$(
    cat <<EOF
# Ubuntu $image_release LTS server cloud image (amd64) booted by tests/vm/vm.sh.
# Refresh with: tests/vm/vm.sh pin --write
release=$image_release
serial=$serial
url=$url
size=$size
sha256=$sha256
EOF
  )
  printf '%s\n' "$content"
  if ((write_lock)); then
    tmp=$(mktemp "$(dirname -- "$image_lock")/.image.lock.XXXXXX")
    printf '%s\n' "$content" >"$tmp"
    chmod 0644 -- "$tmp"
    mv -f -- "$tmp" "$image_lock"
    log "wrote $image_lock" >&2
  fi
}

# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

run_dir() {
  printf '%s\n' "$vm_root/runs/$name"
}

# process_alive PID: the process exists and is not a zombie.
process_alive() {
  local state
  [[ $1 =~ ^[1-9][0-9]*$ && -r /proc/$1/stat ]] || return 1
  state=$(sed -E 's/^.*\) ([A-Za-z]).*$/\1/' "/proc/$1/stat" 2>/dev/null) || return 1
  [[ -n $state && $state != Z && $state != X ]]
}

# qemu_pid RUN: the pid of the run's QEMU when it is running.
qemu_pid() {
  local run=$1 pid
  local args=()
  [[ -f $run/qemu.pid ]] || return 1
  pid=$(<"$run/qemu.pid")
  process_alive "$pid" || return 1
  mapfile -d '' args 2>/dev/null <"/proc/$pid/cmdline" || return 1
  ((${#args[@]})) || return 1
  # The program is QEMU and its command line names this run's pid file.
  [[ ${args[0]%% *} == *qemu* ]] || return 1
  [[ $(printf '%s\n' "${args[@]}") == *"$run/qemu.pid"* ]] || return 1
  printf '%s\n' "$pid"
}

recorded() { # RUN KEY [DEFAULT]
  if [[ -f $1/$2 ]]; then
    printf '%s' "$(<"$1/$2")"
  else
    printf '%s' "${3:-}"
  fi
}

default_cpus() {
  local available
  available=$(nproc 2>/dev/null || echo 2)
  ((available < 4)) && printf '%s\n' "$available" || printf '4\n'
}

free_port() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to pick a free SSH port; pass --ssh-port"
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# qemu_argv RUN ACCEL MEMORY CPUS PORT: sets the array qemu_cmd.
qemu_cmd=()
qemu_argv() {
  local run=$1 accel=$2 mem=$3 cpu_count=$4 port=$5 cpu_model=host
  [[ $accel == kvm ]] || cpu_model=max
  qemu_cmd=(
    "$qemu_bin"
    -name "dotsteward-$name"
    -machine "q35,accel=$accel"
    -cpu "$cpu_model"
    -smp "$cpu_count"
    -m "$mem"
    -drive "if=virtio,format=qcow2,file=$run/disk.qcow2,discard=unmap"
    -drive "if=virtio,format=raw,readonly=on,file=$run/seed.iso"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22"
    -device "virtio-net-pci,netdev=net0"
    -device virtio-rng-pci
    -display none
    -serial "file:$run/console.log"
    -monitor none
    -daemonize
    -pidfile "$run/qemu.pid"
  )
}

# quoted_cmd ARG...: the command as one shell line; words made only of
# characters that need no quoting stay as they are, others use printf %q.
quoted_cmd() {
  local arg text=""
  for arg in "$@"; do
    if [[ $arg =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then
      text+=" $arg"
    else
      text+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s\n' "${text# }"
}

# choose_accel PREVIOUS: kvm, tcg (allowed or recorded) or dies.
choose_accel() {
  if kvm_usable; then
    printf 'kvm\n'
  elif ((allow_tcg)) || [[ ${1:-} == tcg ]]; then
    printf 'tcg\n'
  else
    die "KVM is not usable ($kvm_device must be readable and writable by $(id -un)); fix the access or pass --allow-tcg for slow software emulation"
  fi
}

cmd_plan() {
  local run accel image port
  run=$(run_dir)
  load_lock
  image=$(image_path)
  if kvm_usable; then
    accel=kvm
  elif ((allow_tcg)); then
    accel=tcg
  else
    accel=""
  fi
  port=${ssh_port:-PORT}
  qemu_argv "$run" "${accel:-tcg}" "${memory:-6144}" "${cpus:-$(default_cpus)}" "$port"
  printf 'VM: %s\n' "$name"
  if [[ -e $run ]]; then
    printf 'run directory: %s (exists)\n' "$run"
  else
    printf 'run directory: %s (created by up)\n' "$run"
  fi
  if [[ -f $image ]]; then
    printf 'base image: %s (cached)\n' "$image"
  else
    printf 'base image: %s (not downloaded)\n' "$image"
  fi
  printf 'image source: %s\n' "$lock_url"
  if [[ -n $accel ]]; then
    printf 'accelerator: %s\n' "$accel"
  else
    printf 'accelerator: unavailable (%s is not usable; up needs --allow-tcg)\n' "$kvm_device"
  fi
  printf 'disk: %s overlay on the read-only base image\n' "${disk:-40G}"
  printf 'guest: %s@127.0.0.1 port %s\n' "$guest_user" "$port"
  printf 'qemu: %s\n' "$(quoted_cmd "${qemu_cmd[@]}")"
}

render_user_data() { # CLIENT_PUB HOST_PUB HOST_PRIVATE_FILE
  local line
  cat <<EOF
#cloud-config
# Generated by tests/vm/vm.sh for the disposable VM "$name".
hostname: $guest_hostname
users:
  - name: $guest_user
    gecos: dotsteward VM user
    shell: /bin/bash
    groups: [sudo]
    ssh_authorized_keys:
      - $1
ssh_pwauth: false
disable_root: true
ssh_deletekeys: true
ssh_genkeytypes: []
ssh_keys:
  ed25519_private: |
EOF
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done <"$3"
  cat <<EOF
  ed25519_public: $2
write_files:
  - path: $guest_marker
    permissions: "0644"
    content: |
      This machine was made by tests/vm/vm.sh (VM "$name") and is disposable.
  - path: /etc/sudoers.d/90-dotsteward-vm
    permissions: "0440"
    content: |
      Defaults:$guest_user !authenticate
      $guest_user ALL=(ALL:ALL) ALL
package_update: false
package_upgrade: false
EOF
}

build_seed_iso() { # TOOL OUTPUT USER_DATA META_DATA
  case $(basename -- "$1") in
    xorriso) "$1" -as mkisofs -quiet -output "$2" -volid cidata -joliet -rock "$3" "$4" ;;
    genisoimage | mkisofs) "$1" -quiet -output "$2" -volid cidata -joliet -rock "$3" "$4" ;;
    cloud-localds) "$1" "$2" "$3" "$4" ;;
  esac
}

# create_run TOOL IMAGE: a complete run directory (keys, seed, overlay),
# built under a temporary name and renamed at the end.
create_run() {
  local tool=$1 image=$2 run new client_pub host_pub
  run=$(run_dir)
  mkdir -p -- "$vm_root/runs"
  new=$(mktemp -d "$vm_root/runs/.new-$name.XXXXXX")
  pending+=("$new")
  ssh-keygen -q -t ed25519 -N '' -C "dotsteward-vm-$name" -f "$new/id_ed25519" </dev/null
  ssh-keygen -q -t ed25519 -N '' -C "dotsteward-vm-$name-host" -f "$new/host_ed25519" </dev/null
  client_pub=$(<"$new/id_ed25519.pub")
  host_pub=$(cut -d' ' -f1,2 "$new/host_ed25519.pub")
  printf 'dotsteward-vm-%s %s\n' "$name" "$host_pub" >"$new/known_hosts"
  mkdir -m 0700 -- "$new/seed"
  render_user_data "$client_pub" "$host_pub" "$new/host_ed25519" >"$new/seed/user-data"
  printf 'instance-id: dotsteward-%s-%s\nlocal-hostname: %s\n' "$name" "$(timestamp_utc)" "$guest_hostname" \
    >"$new/seed/meta-data"
  build_seed_iso "$tool" "$new/seed.iso" "$new/seed/user-data" "$new/seed/meta-data" ||
    die "building the cloud-init seed image with $tool failed"
  qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$new/disk.qcow2" "${disk:-40G}" ||
    die "creating the overlay disk failed"
  mkdir -m 0700 -- "$new/logs"
  mv -T -- "$new" "$run"
  forget_pending "$new"
}

console_tail() {
  local run=$1
  if [[ -s $run/console.log ]]; then
    printf '[dotsteward-vm] last lines of the serial console (%s):\n' "$run/console.log" >&2
    tail -n 25 -- "$run/console.log" | sed 's/^/    /' >&2
  else
    printf '[dotsteward-vm] the serial console log is empty: %s\n' "$run/console.log" >&2
  fi
}

ssh_cmd=()
# ssh_args RUN [batch]: sets ssh_cmd to a strict ssh invocation of the run's
# guest, isolated from the user's SSH configuration and known hosts.
ssh_args() {
  local run=$1 port
  port=$(recorded "$run" ssh-port)
  [[ $port =~ ^[0-9]+$ ]] || die "no SSH port recorded for VM $name"
  ssh_cmd=(
    ssh -F /dev/null
    -i "$run/id_ed25519"
    -p "$port"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$run/known_hosts"
    -o GlobalKnownHostsFile=/dev/null
    -o "HostKeyAlias=dotsteward-vm-$name"
    -o ConnectTimeout=5
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o LogLevel=ERROR
  )
  if [[ ${2:-} == batch ]]; then
    ssh_cmd+=(-o BatchMode=yes)
  fi
}

guest_run() { # RUN COMMAND_STRING: non-interactive command in the guest
  ssh_args "$1" batch
  "${ssh_cmd[@]}" "$guest_user@127.0.0.1" "$2"
}

require_running() {
  local run
  run=$(run_dir)
  if [[ ! -d $run || -L $run ]] || ! qemu_pid "$run" >/dev/null; then
    die "VM $name is not running (start it with: tests/vm/vm.sh up --name $name)"
  fi
}

wait_ready() {
  local run=$1 timeout=$2 deadline status=0
  deadline=$((SECONDS + timeout))
  log "waiting for SSH on 127.0.0.1:$(recorded "$run" ssh-port) (up to ${timeout} s)"
  while :; do
    if ! qemu_pid "$run" >/dev/null; then
      console_tail "$run"
      die "QEMU exited while VM $name was booting"
    fi
    if guest_run "$run" true </dev/null >/dev/null 2>&1; then
      break
    fi
    if ((SECONDS >= deadline)); then
      console_tail "$run"
      die "VM $name is not reachable over SSH within $timeout s; it is still running for inspection: stop it with tests/vm/vm.sh down --name $name"
    fi
    sleep "$poll_interval"
  done
  log "waiting for cloud-init to finish"
  guest_run "$run" 'cloud-init status --wait --long' </dev/null >"$run/cloud-init.status" 2>&1 || status=$?
  case $status in
    0) ;;
    2) warn "cloud-init finished with recoverable errors (see $run/cloud-init.status)" ;;
    *)
      sed 's/^/    /' "$run/cloud-init.status" >&2
      die "cloud-init failed in VM $name (exit $status)"
      ;;
  esac
  guest_run "$run" "test -f $guest_marker" </dev/null >/dev/null 2>&1 ||
    die "VM $name has no $guest_marker marker: it was not made by this harness"
}

cmd_up() {
  local run tool image accel previous_accel="" restart=0 port mem cpu_count timeout err pid
  require_safe_root
  require_tools
  run=$(run_dir)
  [[ ! -L $run ]] || die "the run directory is a symlink: $run"
  if [[ -d $run ]]; then
    pid=$(qemu_pid "$run") && die "VM $name is already running (pid $pid, SSH port $(recorded "$run" ssh-port))"
    [[ -f $run/disk.qcow2 && -f $run/seed.iso && -f $run/id_ed25519 ]] ||
      die "the run directory is incomplete: $run (remove it with tests/vm/vm.sh destroy --name $name)"
    restart=1
    previous_accel=$(recorded "$run" accel)
  fi
  accel=$(choose_accel "$previous_accel")
  ((restart)) || tool=$(iso_tool)
  ensure_image
  image=$(image_path)

  if ((restart)); then
    if [[ -n $memory$cpus$disk$ssh_port ]]; then
      warn "VM $name exists: it restarts with its recorded settings; --memory, --cpus, --disk and --ssh-port are ignored"
    fi
    mem=$(recorded "$run" memory 6144)
    cpu_count=$(recorded "$run" cpus "$(default_cpus)")
    port=$(recorded "$run" ssh-port)
    [[ $port =~ ^[0-9]+$ ]] || port=$(free_port)
    log "restarting VM $name"
  else
    mem=${memory:-6144}
    cpu_count=${cpus:-$(default_cpus)}
    port=${ssh_port:-$(free_port)}
    create_run "$tool" "$image"
    log "created VM $name in $run"
  fi
  [[ $accel == kvm ]] || warn "KVM is not used: booting with TCG software emulation, which is much slower"

  printf '%s\n' "$accel" >"$run/accel"
  printf '%s\n' "$mem" >"$run/memory"
  printf '%s\n' "$cpu_count" >"$run/cpus"
  printf '%s\n' "$port" >"$run/ssh-port"
  qemu_argv "$run" "$accel" "$mem" "$cpu_count" "$port"
  quoted_cmd "${qemu_cmd[@]}" >"$run/qemu.argv"
  rm -f -- "$run/qemu.pid"
  err=$(mktemp "$run/.qemu-stderr.XXXXXX")
  if ! "${qemu_cmd[@]}" </dev/null >/dev/null 2>"$err"; then
    sed 's/^/    /' "$err" >&2
    rm -f -- "$err"
    die "QEMU did not start VM $name (its files stay in $run; remove them with tests/vm/vm.sh destroy --name $name)"
  fi
  rm -f -- "$err"
  [[ -s $run/qemu.pid ]] || die "QEMU started without writing $run/qemu.pid"

  timeout=${boot_timeout:-}
  if [[ -z $timeout ]]; then
    if [[ $accel == kvm ]]; then
      timeout=900
    else
      timeout=3600
    fi
  fi
  wait_ready "$run" "$timeout"
  log "VM $name is ready: tests/vm/vm.sh ssh --name $name"
}

cmd_fetch() {
  require_safe_root
  ensure_image
}

cmd_ssh() {
  local run remote
  require_running
  run=$(run_dir)
  if ((${#extra_args[@]})); then
    remote=$(quoted_cmd "${extra_args[@]}")
    ssh_args "$run"
    [[ -t 0 && -t 1 ]] && ssh_cmd+=(-t)
    exec "${ssh_cmd[@]}" "$guest_user@127.0.0.1" "$remote"
  fi
  ssh_args "$run"
  exec "${ssh_cmd[@]}" "$guest_user@127.0.0.1"
}

stop_qemu() { # RUN PID: graceful power-off unless --force, then signals
  local run=$1 pid=$2 i
  if ((!force)); then
    log "asking VM $name to power off"
    guest_run "$run" 'sudo systemctl poweroff' </dev/null >/dev/null 2>&1 || true
    for ((i = 0; i < shutdown_timeout * 10; i++)); do
      process_alive "$pid" || break
      sleep 0.1
    done
  fi
  if process_alive "$pid"; then
    ((force)) || warn "VM $name did not power off within $shutdown_timeout s; stopping QEMU"
    kill -TERM "$pid" 2>/dev/null || true
    for ((i = 0; i < 100; i++)); do
      process_alive "$pid" || break
      sleep 0.1
    done
    if process_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

cmd_down() {
  local run pid
  run=$(run_dir)
  if [[ ! -f $run/qemu.pid ]]; then
    log "VM $name is not running"
    return 0
  fi
  if ! pid=$(qemu_pid "$run"); then
    pid=$(<"$run/qemu.pid")
    if process_alive "$pid"; then
      warn "the pid file names process $pid, which is not a QEMU process of this run; it is left alone"
    fi
    rm -f -- "$run/qemu.pid"
    log "VM $name is not running"
    return 0
  fi
  stop_qemu "$run" "$pid"
  rm -f -- "$run/qemu.pid"
  log "VM $name stopped"
}

cmd_destroy() {
  local run runs_real
  run=$(run_dir)
  [[ ! -L $run ]] || die "refusing to remove a run directory that is a symlink: $run"
  if [[ ! -e $run ]]; then
    log "nothing to destroy: there is no VM named $name"
    return 0
  fi
  [[ -d $run ]] || die "not a run directory: $run"
  force=1
  cmd_down >/dev/null
  runs_real=$(cd -- "$vm_root/runs" && pwd -P)
  [[ $(cd -- "$run" && pwd -P) == "$runs_real/$name" ]] || die "refusing to remove $run: it is not inside $runs_real"
  chmod -R u+w -- "$run" 2>/dev/null || true
  rm -rf -- "$run"
  log "VM $name destroyed (the base image is kept)"
}

status_line() {
  local run=$1 vm=$2 pid state
  if pid=$(qemu_pid "$run"); then
    state="running pid $pid"
  else
    state=stopped
  fi
  printf '%s: %s, SSH port %s, accelerator %s, %s\n' "$vm" "$state" \
    "$(recorded "$run" ssh-port '?')" "$(recorded "$run" accel '?')" "$run"
}

cmd_status() {
  local run found=0
  if ((name_given)); then
    run=$(run_dir)
    if [[ -d $run && ! -L $run ]]; then
      status_line "$run" "$name"
    else
      printf 'no VM named %s\n' "$name"
    fi
    return 0
  fi
  for run in "$vm_root"/runs/*; do
    [[ -d $run && ! -L $run ]] || continue
    status_line "$run" "$(basename -- "$run")"
    found=1
  done
  ((found)) || printf 'no VM in %s\n' "$vm_root/runs"
}

# ---------------------------------------------------------------------------
# Framework checkout and scenarios
# ---------------------------------------------------------------------------

list_scenario_names() {
  local script base
  for script in "$script_dir"/guest/*.sh; do
    base=$(basename -- "$script" .sh)
    [[ $base == common ]] || printf '%s\n' "$base"
  done | LC_ALL=C sort
}

known_scenario() {
  list_scenario_names | grep -qxF -- "$1"
}

cmd_push() {
  local run src top sha common work bundle
  require_running
  run=$(run_dir)
  src=${source_dir:-$framework_root}
  [[ -d $src ]] || die "not a git checkout: $src"
  top=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $src"
  sha=$(git -C "$top" rev-parse --verify --quiet "$ref^{commit}") || die "unknown revision in $top: $ref"
  if [[ -n $(git -C "$top" status --porcelain --untracked-files=no) ]]; then
    warn "$top has uncommitted changes; only commit $sha is pushed"
  fi
  guest_run "$run" 'command -v git >/dev/null' </dev/null >/dev/null 2>&1 ||
    die "VM $name has no git (install it in the guest with: sudo apt-get install git)"

  # A bundle of exactly that commit, made in a scratch repository that
  # borrows the checkout's objects, so the checkout itself is not touched.
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)
  work=$(mktemp -d "$run/.bundle.XXXXXX")
  pending+=("$work")
  git init -q --bare "$work/repo.git"
  printf '%s\n' "$common/objects" >"$work/repo.git/objects/info/alternates"
  git -C "$work/repo.git" update-ref refs/heads/dotsteward-vm "$sha"
  bundle=$run/framework.bundle
  git -C "$work/repo.git" bundle create -q "$bundle" refs/heads/dotsteward-vm ||
    die "creating the git bundle of $sha failed"

  guest_run "$run" 'mkdir -p .dotsteward-vm && cat > .dotsteward-vm/framework.bundle' <"$bundle" ||
    die "uploading the framework bundle to VM $name failed"
  guest_run "$run" "set -e; rm -rf $guest_checkout.new; git clone -q --no-checkout .dotsteward-vm/framework.bundle $guest_checkout.new; git -C $guest_checkout.new checkout -q --detach $sha; rm -rf $guest_checkout; mv $guest_checkout.new $guest_checkout" </dev/null ||
    die "checking out $sha in VM $name failed"
  log "pushed $sha to ~/$guest_checkout in VM $name"
}

cmd_scenario() {
  local run remote log_file status=0
  if ((list_scenarios)); then
    list_scenario_names
    return 0
  fi
  require_running
  run=$(run_dir)
  ((no_push)) || cmd_push
  remote=$(quoted_cmd bash "$guest_checkout/tests/vm/guest/$scenario.sh" "${extra_args[@]}")
  mkdir -p -- "$run/logs"
  log_file=$run/logs/$scenario-$(timestamp_utc).log
  log "running scenario $scenario in VM $name (log: $log_file)"
  set +e
  guest_run "$run" "$remote" </dev/null 2>&1 | tee -a -- "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  if ((status == 0)); then
    log "scenario $scenario passed"
  else
    warn "scenario $scenario failed with exit $status (log: $log_file)"
  fi
  return "$status"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  (($#)) || usage_error "a command is required"
  command=$1
  shift
  case $command in
    help | -h | --help)
      usage
      return 0
      ;;
    check | plan | status | pin | fetch | up | ssh | push | scenario | down | destroy) ;;
    *) usage_error "unknown command: $command" ;;
  esac
  parse_options "$@"
  case $command in
    check | plan | status | pin) ;;
    scenario) ((list_scenarios)) || require_approval ;;
    *) require_approval ;;
  esac
  require_not_root
  case $command in
    check) cmd_check ;;
    plan) cmd_plan ;;
    status) cmd_status ;;
    pin) cmd_pin ;;
    fetch) cmd_fetch ;;
    up) cmd_up ;;
    ssh) cmd_ssh ;;
    push) cmd_push ;;
    scenario) cmd_scenario ;;
    down) cmd_down ;;
    destroy) cmd_destroy ;;
  esac
}

main "$@"
