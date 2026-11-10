# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Helpers for the tests of `dotsteward observe` (tests/cli/host/test-observe*.sh). Not a
# test file.
#
# Sourcing this file sources tests/cli/host/helpers.sh and puts the dpkg, dpkg-query and
# notify-send stubs on PATH. The fixture root DS_SYSTEM_ROOT stands in for / (the CLI
# reads it as DOTSTEWARD_SYSTEM_ROOT): it gets the dpkg status file, the empty
# /var/lib/dpkg/updates, the four dpkg and apt lock files and an empty /proc/locks.
#
#   pkg PACKAGE VERSION [FIELD=VALUE...]
#                          the owner installs or upgrades PACKAGE outside dotsteward: the
#                          fake dpkg database and the status file change together, as
#                          dpkg writes them (a new file in place of the old one)
#   unpkg PACKAGE          the owner removes PACKAGE
#   run_observe [ARG...]   dotsteward --instance <instance> observe --settle-seconds 0
#                          ARG... (standard input empty)
#   run_state ARG...       dotsteward --instance <instance> state ARG...
#   shown JQ_FILTER        jq -c JQ_FILTER over `state show --json` of this machine
#   state_tip              the local tip of refs/heads/state/laptop, empty without one
#   lock_line FILE         a line of /proc/locks for a write lock of FILE (below the
#                          fixture root), as the kernel prints it
#   hooks_ran              the names of the E2E hooks that ran since the last call, one
#                          line each; empties the log

# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ds_use_stubs dpkg-query dpkg notify-send

os_release=$DS_TEST_ROOT/os-release
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' >"$os_release"
export DOTSTEWARD_OS_RELEASE=$os_release

dpkg_dir=$DS_SYSTEM_ROOT/var/lib/dpkg
mkdir -p "$dpkg_dir/updates" "$DS_SYSTEM_ROOT/var/lib/apt/lists" "$DS_SYSTEM_ROOT/var/cache/apt/archives" \
  "$DS_SYSTEM_ROOT/proc"
: >"$dpkg_dir/lock-frontend"
: >"$dpkg_dir/lock"
: >"$DS_SYSTEM_ROOT/var/lib/apt/lists/lock"
: >"$DS_SYSTEM_ROOT/var/cache/apt/archives/lock"
: >"$DS_SYSTEM_ROOT/proc/locks"
: >"$dpkg_dir/status"

_write_status() {
  local file new=$dpkg_dir/status-new
  : >"$new"
  for file in "$DS_STUB_STATE"/dpkg/installed/*; do
    [[ -f $file ]] || continue
    {
      grep -v '^Files: ' "$file"
      printf '\n'
    } >>"$new"
  done
  mv -f -- "$new" "$dpkg_dir/status"
}

pkg() {
  ds_dpkg_installed "$1" "$2" amd64 "${@:3}"
  _write_status
}

unpkg() {
  rm -f -- "$DS_STUB_STATE/dpkg/installed/$1"
  _write_status
}

run_observe() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" observe --settle-seconds 0 "$@" </dev/null
}

run_state() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" state "$@" </dev/null
}

shown() {
  assert_exit 0 run_state show --json
  jq -c "$1" <<<"$DS_STDOUT"
}

state_tip() {
  git -C "$agents_inst" rev-parse --verify --quiet refs/heads/state/laptop || true
}

lock_line() {
  local device inode
  device=$(stat -c '%D' "$DS_SYSTEM_ROOT$1")
  inode=$(stat -c '%i' "$DS_SYSTEM_ROOT$1")
  # stat %D is the device number in hex; the kernel prints major:minor in hex.
  printf '1: POSIX  ADVISORY  WRITE 4242 %02x:%02x:%s 0 EOF\n' \
    "$((16#$device >> 8 & 0xfff))" "$((16#$device & 0xff | (16#$device >> 12 & 0xfff00)))" "$inode"
}

hooks_ran() {
  if [[ -s $e2e_hook_log ]]; then
    cut -d' ' -f1 "$e2e_hook_log"
  fi
  : >"$e2e_hook_log"
}
