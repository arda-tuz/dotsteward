#!/usr/bin/env bash
# dotsteward bash library: the generic helpers shared by the framework
# commands and by component hooks (SPEC 8.4). Hooks source it through
# DOTSTEWARD_LIB:
#
#   source "$DOTSTEWARD_LIB/lib.sh"
#
# Sourcing it turns on strict mode in the caller and loads
# platform-<platform>.sh of the running platform (DOTSTEWARD_PLATFORM, else
# the kernel name) when that file exists; platform-linux.sh adds the
# os-release, login shell, dpkg and APT helpers.
#
# Messages:      log, warn, die                     ([dotsteward] prefix)
# Requirements:  require_command, require_profile, require_safe_identity,
#                current_platform
# Files:         timestamp_utc, ensure_private_dir DIR, sha256_file FILE,
#                directory_sha256 DIR, install_asset SRC DEST MODE SHA256,
#                forbid_paths GLOB DIR...
# Locks:         lock_value QUERY [FILE], pin_value PACKAGE FIELD
#                (desktop_pin is the same function under its old name)
# Network:       git_net SECONDS ARG..., download_verified URL DEST SIZE SHA256
# Nix:           source_nix_daemon, nix_cmd ARG...
# State:         state_root, cleanup_temp_dir DIR,
#                backup_file_private SRC BACKUP_ROOT, backup_copy_of TARGET
# Login shell:   stable_zsh_path, ensure_stable_login_shell set|migrate [PROFILE]
#
# Inputs from the environment: DOTSTEWARD_STATE_ROOT, DOTSTEWARD_INSTANCE,
# DOTSTEWARD_PLATFORM, GIT_SSH_COMMAND, TMPDIR, XDG_STATE_HOME; and, when
# cli/lib/config.sh loaded the configuration, DS_PROFILES_NAMES (or
# DS_CONFIG_JSON), DS_PINS_VERSIONS_LOCK and DS_COMPAT_LEGACY_BACKUP_LAYOUT.
set -Eeuo pipefail

log() {
  printf '[dotsteward] %s\n' "$*"
}

warn() {
  printf '[dotsteward] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# current_platform: linux or darwin.
current_platform() {
  if [[ -n ${DOTSTEWARD_PLATFORM:-} ]]; then
    case $DOTSTEWARD_PLATFORM in
      linux | darwin) printf '%s\n' "$DOTSTEWARD_PLATFORM" ;;
      *) die "DOTSTEWARD_PLATFORM: expected linux or darwin, got $DOTSTEWARD_PLATFORM" ;;
    esac
    return 0
  fi
  local kernel
  kernel=$(uname -s)
  case $kernel in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'darwin\n' ;;
    *) die "unsupported operating system: $kernel" ;;
  esac
}

# require_profile PROFILE: PROFILE is one of the instance's profiles.names.
require_profile() {
  local names=() name
  if declare -p DS_PROFILES_NAMES >/dev/null 2>&1; then
    names=("${DS_PROFILES_NAMES[@]}")
  elif [[ -n ${DS_CONFIG_JSON:-} ]]; then
    mapfile -t names < <(jq -r '.profiles.names[]' <<<"$DS_CONFIG_JSON")
  else
    die "require_profile: the instance configuration is not loaded"
  fi
  for name in "${names[@]}"; do
    [[ $1 == "$name" ]] && return 0
  done
  local joined
  joined=$(printf '%s, ' "${names[@]}")
  die "unsupported profile: $1 (profiles: ${joined%, })"
}

# require_safe_identity: USER and HOME are safe to interpolate into the
# generated host flake (SPEC 4.4).
require_safe_identity() {
  local user=${USER:-} home=${HOME:-} platform
  platform=$(current_platform) || exit 1
  case $platform in
    darwin)
      [[ $user =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] ||
        die 'unsafe user name: macOS user names must match ^[A-Za-z_][A-Za-z0-9_.-]*$'
      ;;
    *)
      [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] ||
        die 'unsafe user name: Linux user names must match ^[a-z_][a-z0-9_-]*$'
      ;;
  esac
  [[ $home == /* && $home != *[[:space:]\"\'\$\\]* && -d $home ]] ||
    die 'unsafe HOME: it must be an absolute path of an existing directory without whitespace, quotes, $ or backslash'
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

ensure_private_dir() {
  mkdir -p -- "$1" && chmod 0700 -- "$1"
}

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

directory_sha256() {
  local directory=$1
  [[ -d $directory ]] || die "directory digest source not found: $directory"
  (
    cd -- "$directory"
    # Python bytecode caches are a run-time by-product; they are not hashed.
    find . \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' -print0 \) |
      LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

# lock_value QUERY [FILE]: a non-empty value of the versions lock (default:
# the instance's pins.versions_lock).
lock_value() {
  local query=$1 file=${2:-}
  if [[ -z $file ]]; then
    [[ -n ${DOTSTEWARD_INSTANCE:-} ]] || die "lock_value: no lock file (DOTSTEWARD_INSTANCE is not set)"
    file=$DOTSTEWARD_INSTANCE/${DS_PINS_VERSIONS_LOCK:-versions.lock.json}
  fi
  jq -er "($query) // empty" "$file" || die "cannot read lock value: $query"
}

# pin_value PACKAGE FIELD: .desktop_packages[PACKAGE][FIELD] of the lock.
pin_value() {
  local file
  [[ -n ${DOTSTEWARD_INSTANCE:-} ]] || die "pin_value: no lock file (DOTSTEWARD_INSTANCE is not set)"
  file=$DOTSTEWARD_INSTANCE/${DS_PINS_VERSIONS_LOCK:-versions.lock.json}
  jq -er --arg package "$1" --arg field "$2" '.desktop_packages[$package][$field] // empty' "$file" ||
    die "cannot read desktop package pin: $1 $2"
}

desktop_pin() {
  pin_value "$@"
}

# git_net SECONDS ARG...: git for network operations: batch-mode SSH unless
# GIT_SSH_COMMAND is set, no prompts, a time limit (status 124).
git_net() {
  local seconds=$1
  shift
  GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15} GIT_TERMINAL_PROMPT=0 \
    timeout "$seconds" git "$@"
}

# The login shell is the stable profile path: a versioned /nix/store path
# could be removed by Nix garbage collection.
stable_zsh_path() {
  printf '%s\n' "$HOME/.nix-profile/bin/zsh"
}

# ensure_stable_login_shell set|migrate [PROFILE]
# set: sets the login shell to the stable path (sudo may ask for a password).
# migrate: only moves a versioned Nix zsh to the stable path; without sudo
# and without a terminal it warns instead.
# The shells-file line this system added is recorded in
# <state>/current/etc-shells-added-path; only a recorded versioned line is
# ever removed again.
ensure_stable_login_shell() {
  local mode=${1:-} profile=${2:-}
  [[ $mode == set || $mode == migrate ]] || die "usage: ensure_stable_login_shell set|migrate [PROFILE]"
  local zsh_path current_shell record_file recorded_path=''
  zsh_path=$(stable_zsh_path)
  record_file="$(state_root)/current/etc-shells-added-path"
  [[ -x $zsh_path ]] || die "Nix zsh path is not executable: $zsh_path"
  current_shell=$(platform_login_shell "$USER") || exit 1

  if [[ $mode == migrate ]]; then
    case "$current_shell" in
      /nix/store/*/bin/zsh) ;;
      *) return 0 ;;
    esac
    if ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
      warn "the login shell is on a versioned Nix path ($current_shell); garbage collection can remove it. Run './rebuild.sh --profile ${profile:-<profile>} --switch' in a terminal to move it to the stable path ($zsh_path)."
      return 0
    fi
  fi

  if [[ -f $record_file ]]; then
    recorded_path=$(<"$record_file")
  fi
  if ! platform_shells_contains "$zsh_path"; then
    platform_shells_add "$zsh_path" || return
    ensure_private_dir "$(state_root)/current" || return
    printf '%s\n' "$zsh_path" >"$record_file" || return
    chmod 0600 "$record_file" || return
  fi
  if [[ $current_shell != "$zsh_path" ]]; then
    platform_set_login_shell "$zsh_path" "$USER" || return
  fi

  # A versioned line this system added earlier is no longer used.
  if [[ -n $recorded_path && $recorded_path != "$zsh_path" && $recorded_path == /nix/store/*/bin/zsh ]] &&
    platform_shells_contains "$recorded_path"; then
    platform_shells_remove "$recorded_path" || return
    if [[ -f $record_file && $(<"$record_file") == "$recorded_path" ]]; then
      rm -f -- "$record_file"
    fi
  fi
}

source_nix_daemon() {
  local profile_script=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  if ! command -v nix >/dev/null 2>&1 && [[ -r $profile_script ]]; then
    # shellcheck source=/dev/null
    source "$profile_script"
  fi
  if [[ -d $HOME/.nix-profile/bin ]]; then
    export PATH="$HOME/.nix-profile/bin:$PATH"
  fi
}

nix_cmd() {
  source_nix_daemon
  require_command nix
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

# download_verified URL DEST SIZE SHA256: HTTPS only; the exact size is
# checked before the digest.
download_verified() {
  local url=$1
  local destination=$2
  local expected_size=$3
  local expected_sha256=$4
  local actual_size actual_sha256

  require_command curl
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 3 --retry-delay 5 --speed-limit 10240 --speed-time 60 \
    --output "$destination" "$url" || return
  [[ -f $destination && ! -L $destination ]] || die "downloaded file is not a regular file: $destination"

  actual_size=$(stat -c '%s' -- "$destination")
  [[ $actual_size == "$expected_size" ]] ||
    die "size mismatch: $destination (expected $expected_size bytes, got $actual_size)"

  actual_sha256=$(sha256_file "$destination")
  [[ $actual_sha256 == "$expected_sha256" ]] || die "SHA-256 mismatch: $destination"
}

# install_asset SOURCE DEST MODE SHA256: installs a file whose digest is
# known, with MODE; the source is verified before anything is written and
# the installed copy after.
install_asset() {
  local source_path=$1 destination=$2 mode=$3 expected_sha256=$4
  [[ $mode =~ ^[0-7]{3,4}$ ]] || die "install_asset: invalid mode: $mode"
  [[ -f $source_path ]] || die "asset not found: $source_path"
  [[ $(sha256_file "$source_path") == "$expected_sha256" ]] || die "asset digest mismatch: $source_path"
  mkdir -p -- "$(dirname -- "$destination")" || return
  if [[ -L $destination ]]; then
    rm -f -- "$destination" || return
  fi
  install -m "$mode" -- "$source_path" "$destination" || return
  [[ $(sha256_file "$destination") == "$expected_sha256" ]] ||
    die "installed asset digest mismatch: $destination"
}

# forbid_paths GLOB DIR...: prints every regular file directly in one of the
# directories whose name matches GLOB (case-insensitive) and returns 1 when
# there is one. Each directory is checked on its own; a missing one has no
# matches.
forbid_paths() {
  (($# >= 2)) || die "usage: forbid_paths GLOB DIR..."
  local glob=$1 directory found=0 match
  shift
  for directory in "$@"; do
    [[ -d $directory ]] || continue
    while IFS= read -r -d '' match; do
      printf '%s\n' "$match"
      found=1
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname "$glob" -print0 2>/dev/null | LC_ALL=C sort -z)
  done
  ((found == 0))
}

# state_root: the machine state root (DOTSTEWARD_STATE_ROOT, set by
# config_load from the configuration, else the framework default).
state_root() {
  printf '%s\n' "${DOTSTEWARD_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/dotsteward}"
}

# cleanup_temp_dir DIR: removes DIR only when it is a real directory whose
# physical path is <physical TMPDIR>/dotsteward-*; the temp prefix and this
# guard change together.
cleanup_temp_dir() {
  local target=${1:-}
  local tmp_root
  [[ -n $target && -d $target && ! -L $target ]] || return 0
  tmp_root=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
  target=$(cd -- "$target" && pwd -P)
  case "$target" in
    "$tmp_root"/dotsteward-*) rm -rf -- "$target" ;;
    *) warn "unsafe temporary directory not removed: $target" ;;
  esac
}

backup_file_private() {
  local source_path=$1
  local backup_root=$2
  local relative_path destination

  [[ -e $source_path || -L $source_path ]] || return 0
  [[ $source_path == /* ]] || die "backup source must be an absolute path: $source_path"
  relative_path=${source_path#/}
  destination="$backup_root/files/$relative_path"
  mkdir -p -- "$(dirname -- "$destination")" || return
  cp -a -- "$source_path" "$destination" || return
  if [[ -f $destination && ! -L $destination ]]; then
    chmod 0600 -- "$destination"
  fi
}

# backup_copy_of TARGET: prints the newest backup holding a regular-file copy
# of the absolute path TARGET; backup directories start with a UTC
# timestamp, so partial backups are skipped. With
# compat.legacy_backup_layout the legacy files/home/<path relative to HOME>
# layout counts too.
backup_copy_of() {
  local target=$1
  local root
  local directory candidate relative=
  [[ $target == /* ]] || die "backup lookup needs an absolute path: $target"
  root="$(state_root)/backups"
  [[ -d $root ]] || return 1
  if [[ ${DS_COMPAT_LEGACY_BACKUP_LAYOUT:-false} == true && $target == "$HOME"/* ]]; then
    relative=${target#"$HOME"/}
  fi
  while IFS= read -r directory; do
    for candidate in "$directory/files$target" ${relative:+"$directory/files/home/$relative"}; do
      if [[ -f $candidate && ! -L $candidate ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | LC_ALL=C sort -r)
  return 1
}

# The platform layer of the running platform, when it exists.
_ds_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if _ds_platform=$(current_platform 2>/dev/null) && [[ -f $_ds_lib_dir/platform-$_ds_platform.sh ]]; then
  # shellcheck source=cli/lib/platform-linux.sh
  source "$_ds_lib_dir/platform-$_ds_platform.sh"
fi
unset _ds_platform
