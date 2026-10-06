# shellcheck shell=bash
# dotsteward platform layer for macOS (darwin). lib.sh sources it on darwin;
# sourcing it alone brings lib.sh first. Sourcing runs no macOS tool, so it
# works anywhere; the functions call them when used.
#
# Platform interface (the names of platform-linux.sh):
#   platform_os_id, platform_os_version   "macos" and the sw_vers product
#                                         version ("unknown" when sw_vers
#                                         does not answer)
#   platform_architecture                 uname -m
#   platform_shells_file                  DOTSTEWARD_ETC_SHELLS, else
#                                         /etc/shells
#   platform_shells_contains PATH         PATH is a line of the shells file
#   platform_shells_add PATH              appends PATH (sudo)
#   platform_shells_remove PATH           rewrites the file without PATH,
#                                         owned by root:wheel, 0644 (sudo)
#   platform_login_shell [USER]           the login shell of USER (default
#                                         $USER) from DOTSTEWARD_PASSWD_CMD
#                                         (a passwd line), else the UserShell
#                                         attribute of dscl
#   platform_set_login_shell PATH [USER]  sets UserShell with dscl (sudo)
#   platform_app_archive_check NAME       the app-archive method (SPEC 3.4)
#   platform_app_archive_install NAME     for cli/lib/methods.sh, which must
#                                         be loaded; see below
# darwin only:
#   sw_vers_value KEY                     sw_vers -KEY (productName,
#                                         productVersion, buildVersion)
#                                         through DOTSTEWARD_SW_VERS, else
#                                         sw_vers
#   xcode_clt_installed                   the Xcode Command Line Tools are
#                                         installed (xcode-select -p)
#   require_xcode_clt                     dies with the install hint when
#                                         they are not
#   app_bundle_version BUNDLE             CFBundleShortVersionString of
#                                         BUNDLE/Contents/Info.plist (XML or
#                                         binary property list; empty when
#                                         missing, unreadable or a symlink)
#
# The app-archive method installs an application bundle from the official
# archive pinned in the versions lock (install block: pin, appName, dest,
# default "~/Applications"; the pin entry: minimum_version (or version),
# url, size, sha256):
#   check    the bundle's version is at least the pin (a newer bundle, as
#            applications update themselves, satisfies it)
#   install  nothing when the check is satisfied; otherwise the archive is
#            downloaded (HTTPS only, size then SHA-256), recognised by
#            content (a zip, or a disk image by its UDIF trailer), extracted
#            with ditto (a disk image is attached read-only at a mount point
#            in the temporary directory, the bundle copied out with ditto,
#            the image detached), and the bundle at the archive's root
#            checked (Info.plist version at least the pin) before anything
#            changes. An existing bundle is then moved into a private backup
#            (<state>/backups/<UTC timestamp>/files/<path>), the new one
#            copied into place with ditto (symlinks, modes and extended
#            attributes kept) and its version read again; a failed copy
#            moves the previous bundle back. A symlink or a non-directory at
#            the destination is never replaced.
# Both set METHODS_STATUS and METHODS_DETAIL like the methods of methods.sh;
# the check returns 1 when it fails, every refusal dies.

if ! declare -F die >/dev/null; then
  # shellcheck source=cli/lib/lib.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
fi

# --- Platform facts -----------------------------------------------------------

sw_vers_value() {
  local key=$1
  [[ $key =~ ^[A-Za-z]+$ ]] || die "sw_vers_value: invalid key: $key"
  "${DOTSTEWARD_SW_VERS:-sw_vers}" "-$key" 2>/dev/null
}

platform_os_id() {
  printf 'macos\n'
}

platform_os_version() {
  local value
  value=$(sw_vers_value productVersion) || value=''
  printf '%s\n' "${value:-unknown}"
}

platform_architecture() {
  uname -m
}

xcode_clt_installed() {
  command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1
}

require_xcode_clt() {
  xcode_clt_installed ||
    die "the Xcode Command Line Tools are not installed; run 'xcode-select --install', finish the installation, then run the command again"
}

# --- Shells file and login shell ----------------------------------------------

platform_shells_file() {
  printf '%s\n' "${DOTSTEWARD_ETC_SHELLS:-/etc/shells}"
}

platform_shells_contains() {
  grep -Fxq -- "$1" "$(platform_shells_file)" 2>/dev/null
}

platform_shells_add() {
  printf '%s\n' "$1" | sudo tee -a "$(platform_shells_file)" >/dev/null
}

platform_shells_remove() {
  local file tmp_file status=0
  file=$(platform_shells_file)
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/dotsteward-shells.XXXXXX")
  target=$1 awk '$0 != ENVIRON["target"]' "$file" >"$tmp_file" || status=$?
  if ((status == 0)); then
    sudo install -o root -g wheel -m 0644 "$tmp_file" "$file" || status=$?
  fi
  rm -f -- "$tmp_file"
  return "$status"
}

platform_login_shell() {
  local user=${1:-$USER} entry='' shell='' line
  if [[ -n ${DOTSTEWARD_PASSWD_CMD:-} ]]; then
    entry=$("$DOTSTEWARD_PASSWD_CMD" "$user" 2>/dev/null) || entry=''
    shell=$(cut -d: -f7 <<<"${entry%%$'\n'*}")
  else
    entry=$(dscl . -read "/Users/$user" UserShell 2>/dev/null) || entry=''
    while IFS= read -r line; do
      if [[ $line == 'UserShell: '* ]]; then
        shell=${line#UserShell: }
        break
      fi
    done <<<"$entry"
  fi
  [[ -n $shell ]] || die "cannot read the login shell of $user"
  printf '%s\n' "$shell"
}

platform_set_login_shell() {
  sudo dscl . -create "/Users/${2:-$USER}" UserShell "$1"
}

# --- Application bundles --------------------------------------------------------

app_bundle_version() {
  local plist=$1/Contents/Info.plist
  [[ -f $plist && ! -L $plist ]] || return 0
  python3 -I - "$plist" <<'PY' 2>/dev/null || true
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        document = plistlib.load(handle)
except Exception:
    sys.exit(0)
value = document.get("CFBundleShortVersionString") if isinstance(document, dict) else None
if isinstance(value, str) and value.strip():
    print(value.strip())
PY
}

# --- app-archive ------------------------------------------------------------------

# _darwin_require_methods CALLER: methods.sh is loaded.
_darwin_require_methods() {
  if ! declare -F methods_component >/dev/null || ! declare -F _methods_set >/dev/null; then
    die "$1: cli/lib/methods.sh is not loaded"
  fi
}

# _darwin_app_archive_state NAME: reads the install block and the pin and
# finds the installed version. Sets _aa_* variables.
_darwin_app_archive_state() {
  local name=$1 component
  component=$(methods_component "$name") || exit 1
  _aa_pin=$(jq -r '.install.pin // empty | strings' <<<"$component")
  _aa_app=$(jq -r '.install.appName // empty | strings' <<<"$component")
  _aa_dest=$(jq -r '.install.dest // "~/Applications" | strings' <<<"$component")
  [[ -n $_aa_pin && -n $_aa_app ]] || die "$name (app-archive): the install block needs pin and appName"
  [[ $_aa_app =~ ^[^/.][^/]*[.]app$ ]] ||
    die "$name (app-archive): invalid appName: $_aa_app (a bundle name ending in .app)"
  case $_aa_dest in
    \~/?*) _aa_dir=$HOME/${_aa_dest#\~/} ;;
    /?*) _aa_dir=$_aa_dest ;;
    *) die "$name (app-archive): dest must be ~/... or absolute: $_aa_dest" ;;
  esac
  _aa_dir=${_aa_dir%/}
  _aa_bundle=$_aa_dir/$_aa_app
  _aa_entry=$(_methods_pin_entry "$name" app-archive "$_aa_pin") || exit 1
  _aa_version=$(_methods_pin_version "$name" app-archive "$_aa_pin" "$_aa_entry") || exit 1
  _aa_found=''
  _aa_present=0
  if [[ -e $_aa_bundle || -L $_aa_bundle ]]; then
    _aa_present=1
    _aa_found=$(app_bundle_version "$_aa_bundle")
  fi
}

# _darwin_app_archive_found: the installed version as the details show it.
_darwin_app_archive_found() {
  if [[ -n $_aa_found ]]; then
    printf '%s\n' "$_aa_found"
  elif ((_aa_present)); then
    printf 'no version\n'
  else
    printf 'none\n'
  fi
}

platform_app_archive_check() {
  (($# == 1)) || die "usage: platform_app_archive_check NAME"
  _darwin_require_methods platform_app_archive_check
  local name=$1
  _darwin_app_archive_state "$name"
  if methods_version_at_least "$_aa_found" "$_aa_version"; then
    _methods_set satisfied "$_aa_app $_aa_found"
    return 0
  fi
  _methods_set failed "$_aa_app $_aa_version or newer is not installed in $_aa_dest (found $(_darwin_app_archive_found))"
  return 1
}

platform_app_archive_install() {
  (($# == 1)) || die "usage: platform_app_archive_install NAME"
  _darwin_require_methods platform_app_archive_install
  local name=$1 download url size sha256 tmp_dir status=0 installed
  [[ $(methods_component_method "$name") == app-archive ]] || die "$name: not an app-archive component"
  _darwin_app_archive_state "$name"
  if methods_version_at_least "$_aa_found" "$_aa_version"; then
    _methods_set satisfied "$_aa_app $_aa_found"
    return 0
  fi
  if ((_aa_present)); then
    [[ -d $_aa_bundle && ! -L $_aa_bundle ]] ||
      die "$name (app-archive): refusing to replace a symlink or non-directory: $_aa_bundle"
  fi
  download=$(_methods_pin_download "$name" app-archive "$_aa_pin" "$_aa_entry") || exit 1
  read -r url size sha256 <<<"$download"
  [[ $url == https://* ]] || die "$name (app-archive): refusing a non-HTTPS download URL: $url"
  require_command ditto

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-app-archive.XXXXXX") ||
    die "$name (app-archive): cannot create a temporary directory"
  (
    trap '_darwin_app_archive_cleanup "$name" "$tmp_dir"' EXIT
    _darwin_app_archive_fetch "$name" "$url" "$size" "$sha256" "$tmp_dir"
  ) || status=$?
  ((status == 0)) || exit "$status"

  installed=$(app_bundle_version "$_aa_bundle")
  methods_version_at_least "$installed" "$_aa_version" ||
    die "$name (app-archive): $_aa_app $_aa_version or newer not found in $_aa_dir after the install (found ${installed:-none})"
  _methods_set installed "$_aa_app $installed"
}

# _darwin_archive_format FILE: zip or dmg (a UDIF disk image ends with a
# 512-byte trailer starting with "koly"); status 1 otherwise.
_darwin_archive_format() {
  local file=$1 size
  if [[ $(head -c 4 -- "$file" | od -An -tx1 | tr -d ' \n') == 504b0304 ]]; then
    printf 'zip\n'
    return 0
  fi
  size=$(stat -c %s -- "$file")
  if ((size >= 512)) && [[ $(tail -c 512 -- "$file" | head -c 4) == koly ]]; then
    printf 'dmg\n'
    return 0
  fi
  return 1
}

# _darwin_detach NAME MOUNT: detaches the disk image at MOUNT, with -force
# when the first attempt fails; status 1 when it stays attached.
_darwin_detach() {
  local name=$1 mount=$2
  if hdiutil detach "$mount" >/dev/null </dev/null; then
    rm -f -- "$mount.attached"
    return 0
  fi
  warn "$name (app-archive): detaching $mount failed; retrying with -force"
  if hdiutil detach -force "$mount" >/dev/null </dev/null; then
    rm -f -- "$mount.attached"
    return 0
  fi
  return 1
}

# _darwin_app_archive_cleanup NAME TMP_DIR: the EXIT trap of the fetch
# subshell. A disk image still attached is detached first; a temporary
# directory with a volume that stays mounted is never removed.
_darwin_app_archive_cleanup() {
  local name=$1 tmp_dir=$2 mount=$2/mount
  if [[ -f $mount.attached ]] && ! _darwin_detach "$name" "$mount" 2>/dev/null; then
    warn "$name (app-archive): the disk image is still attached at $mount; detach it with 'hdiutil detach $mount'"
    return 0
  fi
  cleanup_temp_dir "$tmp_dir"
}

# _darwin_app_archive_fetch NAME URL SIZE SHA256 TMP_DIR: runs in a subshell
# whose EXIT trap detaches and removes TMP_DIR; downloads and checks the
# archive, then replaces the bundle. The subshell is the left operand of
# `||`, where bash ignores errexit, so every step checks its own status.
_darwin_app_archive_fetch() {
  local name=$1 url=$2 size=$3 sha256=$4 tmp_dir=$5 asset format staged found status=0
  local mount=$tmp_dir/mount extracted=$tmp_dir/extracted backup='' backup_root
  asset=${url%%[?#]*}
  asset=${asset##*/}
  [[ -n $asset && $asset != mount && $asset != extracted ]] || asset=download
  log "$name (app-archive): downloading $url"
  download_verified "$url" "$tmp_dir/$asset" "$size" "$sha256" || status=$?
  ((status == 0)) || die "$name (app-archive): download failed (curl exit $status): $url"
  format=$(_darwin_archive_format "$tmp_dir/$asset") ||
    die "$name (app-archive): unsupported archive format (expected a zip or a disk image): $url"

  mkdir -p -- "$extracted" || die "$name (app-archive): cannot create $extracted"
  case $format in
    zip)
      ditto -x -k "$tmp_dir/$asset" "$extracted" || status=$?
      ((status == 0)) || die "$name (app-archive): cannot extract the archive (ditto exit $status): $url"
      ;;
    dmg)
      require_command hdiutil
      mkdir -p -- "$mount" || die "$name (app-archive): cannot create $mount"
      : >"$mount.attached"
      hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$tmp_dir/$asset" \
        >/dev/null </dev/null || status=$?
      if ((status != 0)); then
        rm -f -- "$mount.attached"
        die "$name (app-archive): cannot attach the disk image (hdiutil exit $status): $url"
      fi
      if [[ -d $mount/$_aa_app && ! -L $mount/$_aa_app ]]; then
        ditto "$mount/$_aa_app" "$extracted/$_aa_app" || status=$?
      fi
      _darwin_detach "$name" "$mount" ||
        die "$name (app-archive): cannot detach the disk image mounted at $mount"
      ((status == 0)) || die "$name (app-archive): cannot copy the bundle out of the disk image (ditto exit $status): $url"
      ;;
  esac

  staged=$extracted/$_aa_app
  [[ -d $staged && ! -L $staged ]] || die "$name (app-archive): the archive has no bundle $_aa_app at its root: $url"
  found=$(app_bundle_version "$staged")
  [[ -n $found ]] || die "$name (app-archive): $_aa_app in $url has no readable CFBundleShortVersionString"
  methods_version_at_least "$found" "$_aa_version" ||
    die "$name (app-archive): $url holds $_aa_app $found, older than $_aa_version; nothing was replaced"

  mkdir -p -- "$_aa_dir" || die "$name (app-archive): cannot create $_aa_dir"
  if [[ -d $_aa_bundle ]]; then
    backup_root="$(state_root)/backups/$(timestamp_utc)"
    ensure_private_dir "$backup_root" || die "$name (app-archive): cannot create $backup_root"
    backup=$backup_root/files$_aa_bundle
    [[ ! -e $backup && ! -L $backup ]] || die "$name (app-archive): the backup path already exists: $backup"
    mkdir -p -- "${backup%/*}" || die "$name (app-archive): cannot create ${backup%/*}"
    mv -- "$_aa_bundle" "$backup" ||
      die "$name (app-archive): cannot move $_aa_bundle to $backup; nothing was replaced"
    log "$name (app-archive): previous $_aa_bundle moved to $backup"
  fi
  ditto "$staged" "$_aa_bundle" || status=$?
  if ((status != 0)); then
    rm -rf -- "$_aa_bundle"
    if [[ -z $backup ]]; then
      die "$name (app-archive): cannot copy the bundle to $_aa_bundle (ditto exit $status)"
    fi
    mv -- "$backup" "$_aa_bundle" ||
      die "$name (app-archive): cannot copy the bundle to $_aa_bundle (ditto exit $status); restoring the previous bundle failed, it is in $backup"
    die "$name (app-archive): cannot copy the bundle to $_aa_bundle (ditto exit $status); the previous bundle was restored"
  fi
  log "$name (app-archive): installed $_aa_bundle"
}
