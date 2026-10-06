#!/usr/bin/env bash
# dotsteward platform layer for Linux. lib.sh sources it on Linux; sourcing
# it alone brings lib.sh first.
#
# Platform interface (platform-darwin.sh provides the same names):
#   platform_os_id, platform_os_version   from os-release ("unknown" when
#                                         absent)
#   platform_architecture                 uname -m
#   platform_shells_file                  DOTSTEWARD_ETC_SHELLS, else
#                                         /etc/shells
#   platform_shells_contains PATH         PATH is a line of the shells file
#   platform_shells_add PATH              appends PATH (sudo)
#   platform_shells_remove PATH           rewrites the file without PATH,
#                                         root-owned 0644 (sudo)
#   platform_login_shell [USER]           the login shell of USER (default
#                                         $USER) from DOTSTEWARD_PASSWD_CMD,
#                                         else getent passwd
#   platform_set_login_shell PATH [USER]  chsh (sudo)
# Linux only:
#   os_release_value KEY [DEFAULT]        a value of DOTSTEWARD_OS_RELEASE
#                                         (else /etc/os-release), parsed by
#                                         the os-release(5) quoting rules,
#                                         never executed
#   dpkg_installed PACKAGE                the package is installed
#   dpkg_version PACKAGE                  its version (empty when unknown)
#   dpkg_version_at_least PACKAGE MINIMUM installed at MINIMUM or later
#   package_provides PACKAGE REGEX        the installed package lists a path
#                                         matching the bash ERE REGEX that
#                                         exists as a regular file
#   deb_field FILE FIELD                  a control field of a .deb
#   apt_update                            sudo apt-get update
#   apt_install [--reinstall] PACKAGE...  one sudo apt-get install
#                                         --no-install-recommends
#                                         transaction (packages or .deb
#                                         paths); -y only with
#                                         DOTSTEWARD_ASSUME_YES=1 (D6)

if ! declare -F die >/dev/null; then
  # shellcheck source=cli/lib/lib.sh
  source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
fi

# _os_release_unquote VALUE: the value of an os-release assignment, with
# shell-style double quotes, single quotes or backslash escapes removed.
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

platform_os_id() {
  local value
  value=$(os_release_value ID) || exit 1
  printf '%s\n' "${value:-unknown}"
}

platform_os_version() {
  local value
  value=$(os_release_value VERSION_ID) || exit 1
  printf '%s\n' "${value:-unknown}"
}

platform_architecture() {
  uname -m
}

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
    sudo install -o root -g root -m 0644 "$tmp_file" "$file" || status=$?
  fi
  rm -f -- "$tmp_file"
  return "$status"
}

platform_login_shell() {
  local user=${1:-$USER} entry shell
  if [[ -n ${DOTSTEWARD_PASSWD_CMD:-} ]]; then
    entry=$("$DOTSTEWARD_PASSWD_CMD" "$user" 2>/dev/null) || entry=''
  else
    entry=$(getent passwd "$user" 2>/dev/null) || entry=''
  fi
  shell=$(cut -d: -f7 <<<"${entry%%$'\n'*}")
  [[ -n $shell ]] || die "cannot read the login shell of $user"
  printf '%s\n' "$shell"
}

platform_set_login_shell() {
  sudo chsh -s "$1" "${2:-$USER}"
}

dpkg_installed() {
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

dpkg_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

dpkg_version_at_least() {
  local version
  version=$(dpkg_version "$1")
  [[ -n $version ]] && dpkg --compare-versions "$version" ge "$2"
}

package_provides() {
  local package=$1 regex=$2 path
  dpkg_installed "$package" || return 1
  while IFS= read -r path; do
    [[ $path =~ $regex ]] || continue
    if [[ -f $path ]]; then
      return 0
    fi
  done < <(dpkg-query -L "$package" 2>/dev/null)
  return 1
}

deb_field() {
  dpkg-deb -f "$1" "$2"
}

apt_update() {
  sudo apt-get update
}

apt_install() {
  local args=(install)
  if [[ ${DOTSTEWARD_ASSUME_YES:-0} == 1 ]]; then
    args+=(-y)
  fi
  if [[ ${1:-} == --reinstall ]]; then
    args+=(--reinstall)
    shift
  fi
  (($#)) || die "usage: apt_install [--reinstall] PACKAGE..."
  sudo apt-get "${args[@]}" --no-install-recommends "$@"
}
