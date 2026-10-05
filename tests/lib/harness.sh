# shellcheck shell=bash
# Test harness for dotsteward. tests/run.sh starts one fresh bash process per
# test file, sources this file and tests/lib/assert.sh, calls
# `ds_harness_init FILE` and then sources the test file.
#
# A test runs with `set -Eeuo pipefail` in its own temporary root:
#   DS_REPO_ROOT    framework checkout under test (read-only for tests)
#   DS_TEST_FILE    absolute path of the running test file
#   DS_TEST_ROOT    temporary root, removed when the test exits
#   HOME, TMPDIR    directories inside DS_TEST_ROOT; the working directory is
#                   DS_TEST_ROOT/work
#   DS_CALL_LOG     call log written by ds_record_call, read by assert_calls
# The host environment is neutralized: every XDG_*, GIT_*, DOTSTEWARD_* and
# DOTFILES_* variable is removed, git reads only a temporary global config
# with the identity `dotsteward-test <dotsteward-test@example.invalid>`,
# TZ=UTC and the C locale apply, and the platform injection points
# (DOTSTEWARD_ETC_SHELLS, DOTSTEWARD_OS_RELEASE, DOTSTEWARD_PASSWD_CMD,
# DOTSTEWARD_SW_VERS) point at synthetic files inside DS_TEST_ROOT.
#
# Tests must not replace the EXIT trap; register cleanup work with ds_defer.

DS_TEST_IDENTITY_NAME=dotsteward-test
DS_TEST_IDENTITY_EMAIL=dotsteward-test@example.invalid

ds_harness_init() {
  (($# == 1)) || {
    printf 'ds_harness_init: usage: ds_harness_init TEST_FILE\n' >&2
    return 1
  }
  set -Eeuo pipefail

  local base
  DS_TEST_FILE=$1
  DS_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
  base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  DS_TEST_ROOT=$(mktemp -d "$base/dotsteward-test.XXXXXX")
  DS_DEFERRED=()
  export DS_REPO_ROOT DS_TEST_FILE DS_TEST_ROOT
  trap _ds_harness_cleanup EXIT
  # Signals end the test through exit, so the EXIT trap still cleans up.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap '_ds_on_error "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]:-?}" "$LINENO"' ERR

  # Host state must never leak into a test.
  local name
  for name in $(compgen -v XDG_ || true) $(compgen -v GIT_ || true) \
    $(compgen -v DOTSTEWARD_ || true) $(compgen -v DOTFILES_ || true); do
    unset "$name"
  done

  mkdir -p "$DS_TEST_ROOT"/{home,tmp,work,state,platform}
  export HOME=$DS_TEST_ROOT/home
  export TMPDIR=$DS_TEST_ROOT/tmp
  export TZ=UTC LANG=C LC_ALL=C
  export DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/state
  export DS_CALL_LOG=$DS_TEST_ROOT/calls.log

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=$DS_TEST_ROOT/gitconfig
  cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
name = $DS_TEST_IDENTITY_NAME
email = $DS_TEST_IDENTITY_EMAIL
[init]
defaultBranch = main
[commit]
gpgsign = false
[tag]
gpgsign = false
[advice]
detachedHead = false
EOF

  _ds_write_platform_files
  cd "$DS_TEST_ROOT/work"
}

# Synthetic platform data for the DOTSTEWARD_* injection points, so no test
# reads the host's shells file, os-release, user database or macOS version.
_ds_write_platform_files() {
  local dir=$DS_TEST_ROOT/platform
  printf '%s\n' '# /etc/shells: valid login shells' /bin/sh /bin/bash /usr/bin/bash >"$dir/shells"
  cat >"$dir/os-release" <<'EOF'
PRETTY_NAME="Ubuntu 24.04 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
EOF
  # Replacement for `getent passwd [USER]`: one synthetic entry per user.
  cat >"$dir/user-db" <<EOF
#!$BASH
set -euo pipefail
user=\${1:-\${USER:-$DS_TEST_IDENTITY_NAME}}
printf '%s:x:1000:1000:%s:%s:%s\n' "\$user" "\$user" "\$HOME" /bin/bash
EOF
  # Replacement for `sw_vers`.
  cat >"$dir/sw_vers" <<EOF
#!$BASH
set -euo pipefail
case \${1:-} in
  -productName) echo macOS ;;
  -productVersion) echo 15.0 ;;
  -buildVersion) echo 24A335 ;;
  '') printf 'ProductName:\t\t%s\nProductVersion:\t\t%s\nBuildVersion:\t\t%s\n' macOS 15.0 24A335 ;;
  *) echo "sw_vers: unknown option \$1" >&2; exit 1 ;;
esac
EOF
  chmod 0755 "$dir/user-db" "$dir/sw_vers"
  export DOTSTEWARD_ETC_SHELLS=$dir/shells
  export DOTSTEWARD_OS_RELEASE=$dir/os-release
  export DOTSTEWARD_PASSWD_CMD=$dir/user-db
  export DOTSTEWARD_SW_VERS=$dir/sw_vers
}

# fake_secret PREFIX [LENGTH] [CHARSET]
# Prints PREFIX followed by LENGTH (default 36) random characters from
# CHARSET: alnum (default, A-Za-z0-9), upper-alnum (A-Z0-9) or hex (0-9a-f).
# Secret-shaped strings exist only at run time, never in the repository.
fake_secret() {
  (($# >= 1 && $# <= 3)) || {
    printf 'fake_secret: usage: fake_secret PREFIX [LENGTH] [CHARSET]\n' >&2
    return 1
  }
  local prefix=$1 length=${2:-36} charset=${3:-alnum} chars out="" i
  case $charset in
    alnum) chars=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ;;
    upper-alnum) chars=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ;;
    hex) chars=0123456789abcdef ;;
    *)
      printf 'fake_secret: unknown charset: %s\n' "$charset" >&2
      return 1
      ;;
  esac
  [[ $length =~ ^[0-9]+$ ]] || {
    printf 'fake_secret: invalid length: %s\n' "$length" >&2
    return 1
  }
  for ((i = 0; i < length; i++)); do
    out+=${chars:RANDOM%${#chars}:1}
  done
  printf '%s%s\n' "$prefix" "$out"
}

# ds_record_call NAME [ARG...]
# Appends one line to $DS_CALL_LOG: NAME followed by each argument quoted
# with printf %q. Stubs use it; assert_calls compares the log.
ds_record_call() {
  local line
  line=$(printf '%s' "$1")
  shift
  if (($#)); then
    line+=$(printf ' %q' "$@")
  fi
  printf '%s\n' "$line" >>"$DS_CALL_LOG"
}

# ds_defer COMMAND [ARG...]: runs the command when the test exits (in
# reverse registration order), before the temporary root is removed.
ds_defer() {
  (($#)) || {
    printf 'ds_defer: usage: ds_defer COMMAND [ARG...]\n' >&2
    return 1
  }
  local quoted
  quoted=$(printf '%q ' "$@")
  DS_DEFERRED+=("$quoted")
}

_ds_on_error() {
  printf 'error: command failed (exit %s) at %s:%s: %s\n' "$1" "$3" "$4" "$2" >&2
}

_ds_harness_cleanup() {
  local status=$? i
  trap - ERR
  set +e
  for ((i = ${#DS_DEFERRED[@]} - 1; i >= 0; i--)); do
    eval "${DS_DEFERRED[i]}"
  done
  cd / || true
  if [[ -n ${DS_TEST_ROOT:-} && -d $DS_TEST_ROOT && ! -L $DS_TEST_ROOT &&
    $(basename -- "$DS_TEST_ROOT") == dotsteward-test.* ]]; then
    chmod -R u+rwx -- "$DS_TEST_ROOT" 2>/dev/null
    rm -rf -- "$DS_TEST_ROOT"
  fi
  exit "$status"
}
