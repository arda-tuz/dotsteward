# shellcheck shell=bash
# Shared helpers of the guest scripts (tests/vm/guest/<scenario>.sh). The
# scripts run inside a VM made by tests/vm/vm.sh, from the framework
# checkout that `vm.sh push` placed at ~/dotsteward-src, as the VM user
# (passwordless sudo inside the VM). They change the whole machine, so
# guest_require_vm stops them anywhere else before any command runs.

guest_marker=/etc/dotsteward-vm
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

# guest_require_vm: only inside a harness VM, only as the VM user.
guest_require_vm() {
  [[ -f $guest_marker ]] ||
    guest_die "this script runs only inside a VM made by tests/vm/vm.sh (marker $guest_marker is missing); it changes the whole machine"
  [[ $(id -u) != 0 ]] || guest_die "run this script as the VM user, not as root"
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
