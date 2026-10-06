# shellcheck shell=bash
# dotsteward stage-0: the pre-Nix part of the instance bootstrap (SPEC
# 10.2, port of bootstrap.sh:1-89). Not sourced by the CLI:
# tools/gen-stage0.sh concatenates the stage-0 body of
# cli/commands/preflight.sh and this file into template/bootstrap.sh, which
# ends with `stage0_main "$@"`. Instances keep that file byte-identical to
# their pinned framework's template.
#
# It runs before Nix and before any dotsteward package exists: with the
# macOS /bin/bash (3.2) and BSD tools as well as on Ubuntu, without jq,
# python or GNU-only options. Its inputs are the instance's stage-0 mirror
# .dotsteward/stage0.<platform>.env (DS_STAGE0_* variables, rendered from
# workstation.toml, the components and the lock by `dotsteward sync`) and,
# for --install-nix-only without a mirror, the versions.lock.json beside
# the script.
#
#   ./bootstrap.sh --profile PROFILE   PROFILE must be the bootstrap profile;
#                                      then, in this order: the identity
#                                      check, preflight (exit 3 on the
#                                      adaptive route, before any write),
#                                      backups of every declared path into
#                                      <state>/backups/<UTC>/files/<path>,
#                                      snapshots whose required command
#                                      exists, the prerequisites (Ubuntu:
#                                      the platform base packages and the
#                                      components' apt list in one
#                                      interactive apt transaction; macOS:
#                                      the Xcode Command Line Tools must be
#                                      installed), the verified Nix install
#                                      and the exact `nix --version`, then
#                                      exec .dotsteward/cli.sh bootstrap
#                                      --profile PROFILE --stage 1
#   ./bootstrap.sh --install-nix-only  only the verified Nix install and the
#                                      version check (dotsteward-init, before
#                                      an instance exists)
#
# DOTSTEWARD_ASSUME_YES=1 (CI and VM harnesses only, D6) answers apt with -y
# and the Nix installer with --yes. The state root is DOTSTEWARD_STATE_ROOT,
# else DOTFILES_STATE_ROOT when the mirror's legacy environment is on, else
# the mirror's state root with a leading ${NAME:-DEFAULT} and ~ expanded,
# as the CLI and the launcher resolve it.

# --- copies of the library helpers ------------------------------------------
# Identical to cli/lib/lib.sh and cli/lib/platform-linux.sh (tests/cli/
# bootstrap/test-lib-parity.sh keeps them so): the stage-0 body of preflight
# and the steps below call them as the CLI does.

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

_os_release_unquote() {
  local value=$1 out='' char i quote=''
  value=${value%"${value##*[![:space:]]}"}
  if ((${#value} >= 2)) && [[ ${value:0:1} == "${value: -1}" && ${value:0:1} == [\"\'] ]]; then
    quote=${value:0:1}
    value=${value:1:${#value}-2}
  fi
  if [[ $quote == "'" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    if [[ $char == \\ ]] && ((i + 1 < ${#value})); then
      if [[ -z $quote || ${value:i+1:1} == [\$\"\\\`] ]]; then
        i=$((i + 1))
        char=${value:i:1}
      fi
    fi
    out+=$char
  done
  printf '%s\n' "$out"
}

os_release_value() {
  local key=$1 default=${2:-} file=${DOTSTEWARD_OS_RELEASE:-/etc/os-release} line value found=0
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "os_release_value: invalid key: $key"
  [[ -f $file && -r $file ]] || die "cannot read os-release: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$key="* ]]; then
      # Later assignments win, as when the file is sourced.
      value=${line#"$key="}
      found=1
    fi
  done <"$file"
  if ((found)); then
    _os_release_unquote "$value"
  else
    printf '%s\n' "$default"
  fi
}

# --- stage-0 ----------------------------------------------------------------

stage0_usage() {
  cat <<'USAGE'
Usage: ./bootstrap.sh --profile PROFILE
       ./bootstrap.sh --install-nix-only

Prepares this machine for the instance: preflight (read-only; exit 3 on
the adaptive route), backups of the files the instance manages, the
missing prerequisites, the verified Nix install, then stage 1 through
.dotsteward/cli.sh (system install, switch, login shell, desktop apply,
E2E). PROFILE must be the instance's bootstrap profile.

  --profile PROFILE    the bootstrap profile (profiles.bootstrap)
  --install-nix-only   only install the pinned Nix and check its version

DOTSTEWARD_ASSUME_YES=1 answers apt and the Nix installer (CI only).
USAGE
}

# stage0_expand_home PATH: ~ and ~/... with the runtime HOME.
stage0_expand_home() {
  case $1 in
    '~') printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#[~]/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# stage0_expand_path VALUE: a leading ${NAME:-DEFAULT} (NAME when set and
# non-empty, else DEFAULT), then a leading ~.
stage0_expand_path() {
  local value=$1 name default rest re='^[$][{]([A-Za-z_][A-Za-z0-9_]*):-([^}]*)[}](.*)$'
  if [[ $value =~ $re ]]; then
    name=${BASH_REMATCH[1]}
    default=${BASH_REMATCH[2]}
    rest=${BASH_REMATCH[3]}
    value=${!name:-}
    [[ -n $value ]] || value=$default
    value=$value$rest
  fi
  stage0_expand_home "$value"
}

# stage0_state_root: the machine state root (absolute).
stage0_state_root() {
  local state
  if [[ -n ${DOTSTEWARD_STATE_ROOT:-} ]]; then
    state=$DOTSTEWARD_STATE_ROOT
  elif [[ ${DS_STAGE0_LEGACY_ENV:-false} == true && -n ${DOTFILES_STATE_ROOT:-} ]]; then
    state=$DOTFILES_STATE_ROOT
  else
    state=$(stage0_expand_path "$DS_STAGE0_STATE_ROOT")
  fi
  case $state in
    /*) printf '%s\n' "$state" ;;
    *) die "the state root must be an absolute path: $state" ;;
  esac
}

# stage0_backups BACKUP_ROOT: copies of every declared path that exists,
# then the snapshots whose required command exists.
stage0_backups() {
  local backup_root=$1 path name require file index=0 status
  local -a argv
  ensure_private_dir "$backup_root"
  log "backing up existing files to $backup_root"
  for path in ${DS_STAGE0_BACKUP_PATHS[@]+"${DS_STAGE0_BACKUP_PATHS[@]}"}; do
    backup_file_private "$(stage0_expand_home "$path")" "$backup_root"
  done
  for name in ${DS_STAGE0_SNAPSHOTS[@]+"${DS_STAGE0_SNAPSHOTS[@]}"}; do
    eval "argv=(\${DS_STAGE0_SNAPSHOT_${index}_ARGV[@]+\"\${DS_STAGE0_SNAPSHOT_${index}_ARGV[@]}\"})"
    eval "require=\${DS_STAGE0_SNAPSHOT_${index}_REQUIRE_COMMAND-}"
    index=$((index + 1))
    case $name in
      '' | . | .. | */*) die "invalid snapshot name: $name" ;;
    esac
    if [[ -n $require ]] && ! command -v "$require" >/dev/null 2>&1; then
      continue
    fi
    ((${#argv[@]})) || die "snapshot $name has no command"
    mkdir -p "$backup_root/snapshots"
    file=$backup_root/snapshots/$name
    status=0
    (umask 077 && "${argv[@]}" >"$file" </dev/null) || status=$?
    ((status == 0)) || die "snapshot $name failed (exit $status)"
    chmod 0600 "$file"
  done
}

# stage0_prerequisites PLATFORM: Ubuntu: the missing base and component
# packages in one apt transaction (interactive unless
# DOTSTEWARD_ASSUME_YES=1). macOS: the Xcode Command Line Tools.
stage0_prerequisites() {
  # The platform base packages stage-0 installs on Ubuntu before Nix.
  local base='ca-certificates curl git gnupg xz-utils' package status seen=' '
  local -a missing
  if [[ $1 == darwin ]]; then
    xcode-select -p >/dev/null 2>&1 ||
      die "the Xcode Command Line Tools are not installed; run 'xcode-select --install', finish the installation, then run ./bootstrap.sh again"
    return 0
  fi
  command -v dpkg-query >/dev/null 2>&1 || die "required command not found: dpkg-query (stage-0 installs prerequisites with APT)"
  missing=()
  # shellcheck disable=SC2086 # the base list is split on purpose
  for package in $base ${DS_STAGE0_PREREQUISITES_APT[@]+"${DS_STAGE0_PREREQUISITES_APT[@]}"}; do
    case $seen in
      *" $package "*) continue ;;
    esac
    seen="$seen$package "
    # shellcheck disable=SC2016 # a dpkg-query format, not a shell expansion
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) || status=
    if [[ $status != installed ]]; then
      missing[${#missing[@]}]=$package
    fi
  done
  ((${#missing[@]})) || return 0
  log "installing the missing prerequisites: ${missing[*]}"
  sudo apt-get update
  if [[ ${DOTSTEWARD_ASSUME_YES:-0} == 1 ]]; then
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
  else
    sudo apt-get install --no-install-recommends "${missing[@]}"
  fi
}

# stage0_sha256 FILE: the SHA-256 of FILE (sha256sum, else macOS shasum).
stage0_sha256() {
  local line
  if command -v sha256sum >/dev/null 2>&1; then
    line=$(sha256sum <"$1") || return
  else
    line=$(shasum -a 256 <"$1") || return
  fi
  printf '%s\n' "${line%%[[:space:]]*}"
}

# stage0_download_verified URL DEST SIZE SHA256: HTTPS only; the exact size
# is checked before the digest.
stage0_download_verified() {
  local url=$1 destination=$2 expected_size=$3 expected_sha256=$4 actual_size actual_sha256 status=0
  case $url in
    https://*) ;;
    *) die "refusing a download that is not HTTPS: $url" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "required command not found: curl"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 3 --retry-delay 5 --speed-limit 10240 --speed-time 60 \
    --output "$destination" "$url" || status=$?
  if ((status != 0)); then
    printf '[dotsteward] ERROR: downloading %s failed (curl exit %s)\n' "$url" "$status" >&2
    exit "$status"
  fi
  [[ -f $destination && ! -L $destination ]] || die "downloaded file is not a regular file: $destination"
  actual_size=$(wc -c <"$destination")
  actual_size=${actual_size//[[:space:]]/}
  [[ $actual_size == "$expected_size" ]] ||
    die "size mismatch: $destination (expected $expected_size bytes, got $actual_size)"
  actual_sha256=$(stage0_sha256 "$destination") || die "cannot compute the SHA-256 of $destination"
  [[ $actual_sha256 == "$expected_sha256" ]] || die "SHA-256 mismatch: $destination"
}

# stage0_lock_pins FILE: the Nix pin from a versions lock in the canonical
# layout (two-space indent: a top-level "nix" table, one key per line), into
# the DS_STAGE0_NIX_* variables; no jq before Nix.
stage0_lock_pins() {
  local file=$1 line in_nix=0 key value
  local re='^    "([a-z0-9_]+)": ("([^"\\]*)"|([0-9]+)),?$'
  DS_STAGE0_NIX_VERSION=
  DS_STAGE0_NIX_INSTALLER_URL=
  DS_STAGE0_NIX_INSTALLER_SIZE=
  DS_STAGE0_NIX_INSTALLER_SHA256=
  while IFS= read -r line || [[ -n $line ]]; do
    if ((in_nix)); then
      case $line in
        '  }' | '  },') break ;;
      esac
      [[ $line =~ $re ]] || continue
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
      case $key:${BASH_REMATCH[4]} in
        version: | installer_url: | installer_sha256:) ;;
        installer_size:?*) ;;
        *) continue ;;
      esac
      case $key in
        version) DS_STAGE0_NIX_VERSION=$value ;;
        installer_url) DS_STAGE0_NIX_INSTALLER_URL=$value ;;
        installer_size) DS_STAGE0_NIX_INSTALLER_SIZE=$value ;;
        installer_sha256) DS_STAGE0_NIX_INSTALLER_SHA256=$value ;;
      esac
    elif [[ $line == '  "nix": {' ]]; then
      in_nix=1
    fi
  done <"$file"
  for key in version installer_url installer_size installer_sha256; do
    case $key in
      version) value=$DS_STAGE0_NIX_VERSION ;;
      installer_url) value=$DS_STAGE0_NIX_INSTALLER_URL ;;
      installer_size) value=$DS_STAGE0_NIX_INSTALLER_SIZE ;;
      installer_sha256) value=$DS_STAGE0_NIX_INSTALLER_SHA256 ;;
    esac
    [[ -n $value ]] || die "$file: cannot read nix.$key"
  done
}

# stage0_install_nix: the pinned Nix (DS_STAGE0_NIX_*): when no nix is on
# PATH (after sourcing the daemon profile), the verified multi-user
# installer; then `nix --version` must name exactly the pinned version.
stage0_install_nix() {
  local version=$DS_STAGE0_NIX_VERSION tmp_dir installer mime actual
  local -a args
  [[ $DS_STAGE0_NIX_INSTALLER_SIZE =~ ^[0-9]+$ ]] ||
    die "invalid Nix installer pin: installer_size $DS_STAGE0_NIX_INSTALLER_SIZE"
  [[ $DS_STAGE0_NIX_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid Nix installer pin: installer_sha256 $DS_STAGE0_NIX_INSTALLER_SHA256"
  [[ -n $version ]] || die "invalid Nix installer pin: empty version"
  source_nix_daemon
  if ! command -v nix >/dev/null 2>&1; then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-nix.XXXXXX") || die "cannot create a temporary directory"
    STAGE0_TMP_DIR=$tmp_dir
    trap 'cleanup_temp_dir "$STAGE0_TMP_DIR"' EXIT
    installer=$tmp_dir/install
    stage0_download_verified "$DS_STAGE0_NIX_INSTALLER_URL" "$installer" \
      "$DS_STAGE0_NIX_INSTALLER_SIZE" "$DS_STAGE0_NIX_INSTALLER_SHA256"
    if command -v file >/dev/null 2>&1; then
      mime=$(file --brief --mime-type "$installer") || die "cannot read the type of $installer"
      case $mime in
        text/*) ;;
        *) die "the Nix installer is not a text file ($mime)" ;;
      esac
    fi
    args=(--daemon)
    if [[ ${DOTSTEWARD_ASSUME_YES:-0} == 1 ]]; then
      args=(--daemon --yes)
    fi
    log "starting the verified Nix $version multi-user installer"
    sh "$installer" "${args[@]}"
    cleanup_temp_dir "$tmp_dir"
    trap - EXIT
    source_nix_daemon
  fi
  command -v nix >/dev/null 2>&1 ||
    die "nix is not on PATH after the installation; open a new terminal and run ./bootstrap.sh again"
  actual=$(nix --version) || die "nix --version failed"
  [[ $actual == "nix (Nix) $version" ]] || die "Nix version is not $version: $actual"
}

# stage0_main ARG...: the stage-0 bootstrap (see the top of this file).
stage0_main() {
  local source_path link_dir root profile='' nix_only=0 platform launcher state_root stamp
  # The instance root is the directory of this script (symlinks resolved
  # without GNU-only tools).
  source_path=${BASH_SOURCE[0]}
  while [[ -L $source_path ]]; do
    link_dir=$(cd -P -- "$(dirname -- "$source_path")" && pwd)
    source_path=$(readlink -- "$source_path")
    case $source_path in
      /*) ;;
      *) source_path=$link_dir/$source_path ;;
    esac
  done
  root=$(cd -P -- "$(dirname -- "$source_path")" && pwd)

  while (($#)); do
    case $1 in
      --profile)
        if (($# < 2)) || [[ -z $2 ]]; then
          die "--profile requires a value"
        fi
        profile=$2
        shift
        ;;
      --profile=*)
        profile=${1#--profile=}
        [[ -n $profile ]] || die "--profile requires a value"
        ;;
      --install-nix-only) nix_only=1 ;;
      -h | --help)
        stage0_usage
        return 0
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  platform=$(current_platform) || exit 1

  if ((nix_only)); then
    [[ -z $profile ]] || die "--install-nix-only takes no --profile"
    if [[ -f $root/.dotsteward/stage0.$platform.env ]]; then
      preflight_load_env "$root" "$platform"
    elif [[ -f $root/versions.lock.json ]]; then
      stage0_lock_pins "$root/versions.lock.json"
    else
      die "neither .dotsteward/stage0.$platform.env nor versions.lock.json found in $root"
    fi
    stage0_install_nix
    log "Nix $DS_STAGE0_NIX_VERSION is installed"
    return 0
  fi

  preflight_load_env "$root" "$platform"
  [[ $profile == "$DS_STAGE0_BOOTSTRAP_PROFILE" ]] ||
    die "a fresh install requires --profile $DS_STAGE0_BOOTSTRAP_PROFILE"
  require_safe_identity
  launcher=$root/.dotsteward/cli.sh
  [[ -f $launcher && -x $launcher ]] || die ".dotsteward/cli.sh is missing or not executable in $root"

  # Read-only; exits 3 on the adaptive route, before any write.
  preflight_parse --read-only --json --profile "$profile"
  preflight_run

  # Assigned first: a refusal inside a command substitution that is only
  # an argument would exit the subshell alone.
  state_root=$(stage0_state_root) || exit 1
  stamp=$(timestamp_utc) || exit 1
  stage0_backups "$state_root/backups/$stamp"
  stage0_prerequisites "$platform"
  stage0_install_nix

  exec "$launcher" bootstrap --profile "$profile" --stage 1
}
