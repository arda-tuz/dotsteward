# shellcheck shell=bash
# Shared helpers of the guest scripts (tests/vm/guest/<scenario>.sh). The
# scripts run inside a VM made by tests/vm/vm.sh, from the framework
# checkout that `vm.sh push` placed at ~/dotsteward-src, as the VM user
# (passwordless sudo inside the VM). They change the whole machine (vendor
# installers into the home directory, Nix, a login shell), so every scenario
# calls guest_require_vm first, and it stops them anywhere else before any
# command with a side effect runs.

# What vm.sh gives every VM: the marker cloud-init writes (render_user_data)
# and the user it creates. Nothing here is read from the environment.
guest_marker=/etc/dotsteward-vm
guest_marker_text='This machine was made by tests/vm/vm.sh'
guest_user=stranger
guest_src=$HOME/dotsteward-src

guest_log() {
  printf '[dotsteward-vm guest] %s\n' "$*"
}

guest_step() {
  printf '\n[dotsteward-vm guest] === %s\n' "$*"
}

guest_die() {
  printf '[dotsteward-vm guest] ERROR: %s\n' "$*" >&2
  exit 1
}

# guest_help_requested ARG...: true when -h or --help is among the arguments
# (help works anywhere, before the VM check).
guest_help_requested() {
  local arg
  for arg in "$@"; do
    [[ $arg == -h || $arg == --help ]] && return 0
  done
  return 1
}

# guest_require_vm: exits 1, having changed nothing, unless every sign of a
# harness VM is present:
#   1. the marker /etc/dotsteward-vm, a regular file with the text cloud-init
#      of vm.sh writes into it (a host never has it; only root could make it)
#   2. a hypervisor: systemd-detect-virt --vm names one (on a physical
#      machine it prints "none"; without the tool nothing confirms a VM)
#   3. the VM user stranger, never root and never the host's owner
#   4. the framework checkout vm.sh push placed at ~/dotsteward-src
# The marker comes first and needs no command, so outside a VM nothing runs
# at all. There is no override: the self-test checks the "inside a VM" path
# on a copy of the scripts whose marker path points into its temporary root.
guest_require_vm() {
  local refusal='this script runs only inside a VM made by tests/vm/vm.sh, because it changes the whole machine; nothing was changed'
  local marker_content virt user
  [[ -f $guest_marker && ! -L $guest_marker ]] ||
    guest_die "$refusal (the marker $guest_marker is missing)"
  marker_content=$(<"$guest_marker") || guest_die "$refusal (the marker $guest_marker is unreadable)"
  [[ $marker_content == *"$guest_marker_text"* ]] ||
    guest_die "$refusal (the marker $guest_marker was not written by tests/vm/vm.sh)"
  virt=$(systemd-detect-virt --vm 2>/dev/null) || true
  [[ -n $virt && $virt != none ]] ||
    guest_die "$refusal (systemd-detect-virt --vm reports ${virt:-nothing}, not a hypervisor)"
  user=$(id -un 2>/dev/null) || guest_die "$refusal (cannot read the user name)"
  [[ $user == "$guest_user" ]] ||
    guest_die "$refusal (it runs as $guest_user, not as $user)"
  [[ $(id -u) != 0 ]] || guest_die "$refusal (it runs as $guest_user, not as root)"
  [[ -d $guest_src/.git ]] || guest_die "no framework checkout at $guest_src (run tests/vm/vm.sh push first)"
}

# guest_load_nix: the Nix daemon profile, when Nix is installed.
guest_load_nix() {
  local profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  if [[ -r $profile ]]; then
    set +u
    # shellcheck source=/dev/null
    source "$profile"
    set -u
  fi
}

guest_nix() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

# guest_login_shell: the VM user's login shell from the user database.
guest_login_shell() {
  getent passwd "$(id -un)" | cut -d: -f7
}
