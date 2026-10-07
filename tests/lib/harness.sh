# shellcheck shell=bash
# Test harness for dotsteward. tests/run.sh starts one fresh bash process per
# test file, sources this file and tests/lib/assert.sh, calls
# `ds_harness_init FILE` and then sources the test file. The stubs in
# tests/lib/stubs source this file too (for the ds_stub_* functions); sourcing
# it only defines functions and constants.
#
# A test runs with `set -Eeuo pipefail` in its own temporary root:
#   DS_REPO_ROOT    framework checkout under test (read-only for tests)
#   DS_TEST_FILE    absolute path of the running test file
#   DS_TEST_ROOT    temporary root, removed when the test exits
#   HOME, TMPDIR    directories inside DS_TEST_ROOT; the working directory is
#                   DS_TEST_ROOT/work
#   USER, LOGNAME   the synthetic user dotsteward-test
#   DS_CALL_LOG     call log written by ds_record_call and every stub, read by
#                   assert_calls, ds_calls_of and ds_call_count
#   DS_STUB_STATE   per-stub state (DS_STUB_STATE/<stub>/...), see "Stubs"
#   DS_SYSTEM_ROOT  fixture root that stands in for /: the sudo stub moves
#                   system paths and the host's user-writable areas below
#                   it, the package stubs keep their databases next to it
#   DS_PASSWD_FILE, DS_GROUP_FILE
#                   the user database behind DOTSTEWARD_PASSWD_CMD and the
#                   getent, id, chsh and dscl stubs
# The host environment is neutralized: every XDG_*, GIT_*, DOTSTEWARD_*,
# DOTFILES_* and application variable (CODEX_*, HERDR_*, PI_*, OPENCODE_*,
# CLAUDE*) is removed, so are the SSH agent (SSH_AUTH_SOCK, SSH_AGENT_PID) and
# the GitHub CLI credentials (GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN,
# GITHUB_ENTERPRISE_TOKEN, GH_HOST, GH_CONFIG_DIR), so a test that forgets the
# fake SSH transport or the gh stub cannot reach a real remote with the host
# user's identity, and the DS_* variables the harness and its helpers own
# are reset (any other DS_* variable is an input from the caller, such as a
# Nix check's setup hook, and is kept). git reads only a temporary global
# config with the identity `dotsteward-test <dotsteward-test@example.invalid>`
# and automatic maintenance off (a detached repack after a commit races with
# the test), TZ=UTC and the C locale apply, and the platform injection points
# (DOTSTEWARD_ETC_SHELLS, DOTSTEWARD_OS_RELEASE, DOTSTEWARD_PASSWD_CMD,
# DOTSTEWARD_SW_VERS) point at synthetic files inside DS_TEST_ROOT, and the
# machine facts of the derived gate parallelism (DOTSTEWARD_MEMORY_MIB,
# DOTSTEWARD_CPU_COUNT) describe a 16 GiB machine with 12 CPUs.
#
# Tests must not replace the EXIT trap; register cleanup work with ds_defer.
#
# Stubs (tests/lib/stubs, one executable per command named in the spec):
#   ds_use_stubs --all | NAME...   puts the named stubs first on PATH (never
#                                  on by default)
#   ds_stub_set NAME KEY VALUE|-   a state value a stub reads (VALUE "-" reads
#                                  standard input); each stub documents its
#                                  keys in its header, every stub knows "env"
#   ds_stub_route NAME GLOB ...    a canned answer for matching arguments
#   ds_stub_clear_routes NAME
#   ds_stub_override NAME          replaces the stub's behaviour with the
#                                  script read from standard input
#   ds_calls_of NAME, ds_env_of NAME, ds_call_count NAME [GLOB]
# Every stub call appends one line "NAME ARG..." (ds_record_call quoting) to
# DS_CALL_LOG. When environment variables are selected for a stub (state key
# "env", or the stub's documented default), a second line follows:
# "NAME:env VAR=VALUE ... -UNSET_VAR" with values quoted by printf %q.
# A route or override answers after the call is recorded.
#
# Packages: ds_dpkg_installed, ds_dpkg_config_files, ds_dpkg_version,
# ds_apt_available, ds_fake_deb.
# Users: ds_passwd_set, ds_passwd_field, ds_group_add.
# Downloads: ds_curl_serve, ds_curl_fail, ds_curl_delay, ds_curl_redirect;
# a real loopback server: ds_httpfix_start, ds_httpfix_stop.
# Fixtures: ds_fixture, ds_fixture_skill_tree, ds_fixture_backup_layouts.
# Git remotes: tests/lib/bare-remote.sh and tests/lib/fakessh.sh (sourced by
# the tests that need them).

DS_TEST_IDENTITY_NAME=dotsteward-test
DS_TEST_IDENTITY_EMAIL=dotsteward-test@example.invalid

# Digest of the tree built by ds_fixture_skill_tree with the default skill
# name, computed with the directory_sha256 algorithm (sorted sha256sum lines
# of the regular files, __pycache__ and *.pyc excluded).
# shellcheck disable=SC2034 # read by the tests that use the builder
DS_FIXTURE_SKILL_TREE_SHA256=1c53e0b2b0dd23047b5a1971ab104e9237c3e0f89df566f822f64dcec9bfc97b

_DS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

ds_harness_init() {
  (($# == 1)) || {
    printf 'ds_harness_init: usage: ds_harness_init TEST_FILE\n' >&2
    return 1
  }
  set -Eeuo pipefail

  local base
  DS_TEST_FILE=$1
  DS_REPO_ROOT=$(cd "$_DS_LIB_DIR/../.." && pwd -P)
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
    $(compgen -v DOTSTEWARD_ || true) $(compgen -v DOTFILES_ || true) \
    $(compgen -v CODEX_ || true) $(compgen -v HERDR_ || true) \
    $(compgen -v PI_ || true) $(compgen -v OPENCODE || true) \
    $(compgen -v CLAUDE || true); do
    unset "$name"
  done
  # Only the DS_* names the harness and its helpers own are reset; any other
  # DS_* variable is an input from the caller (a Nix check's setup hook, for
  # example) and is kept.
  unset DS_CALL_LOG DS_STUB_STATE DS_SYSTEM_ROOT DS_PASSWD_FILE DS_GROUP_FILE \
    DS_STUB_AS_ROOT DS_STUB_NAME DS_STUB_DIR DS_STUB_ENV_DEFAULT \
    DS_HTTPFIX_URL DS_HTTPFIX_PID DS_HTTPFIX_LOG \
    DS_FAKESSH_MAP DS_FAKESSH_LOG DS_FAKESSH_SLEEP DS_FAKESSH_FAIL \
    DS_STDOUT DS_STDERR DS_STATUS
  # Host credentials: the SSH agent and the GitHub CLI tokens.
  unset SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
    GITHUB_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR

  mkdir -p "$DS_TEST_ROOT"/{home,tmp,work,state,platform,stubs}
  export HOME=$DS_TEST_ROOT/home
  export TMPDIR=$DS_TEST_ROOT/tmp
  export USER=$DS_TEST_IDENTITY_NAME LOGNAME=$DS_TEST_IDENTITY_NAME
  export TZ=UTC LANG=C LC_ALL=C
  export DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/state
  export DS_CALL_LOG=$DS_TEST_ROOT/calls.log
  export DS_STUB_STATE=$DS_TEST_ROOT/stubs
  export DS_SYSTEM_ROOT=$DS_TEST_ROOT/system
  mkdir -p "$DS_SYSTEM_ROOT"/{etc/default,etc/apt/sources.list.d,etc/apt/keyrings,opt,srv} \
    "$DS_SYSTEM_ROOT"/{usr/local/bin,usr/share,usr/lib,var/lib,Applications,Library} \
    "$DS_SYSTEM_ROOT"/{home,root,tmp,run}

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
[maintenance]
auto = false
[gc]
auto = 0
EOF

  _ds_write_platform_files
  cd "$DS_TEST_ROOT/work"
}

# Synthetic platform data for the DOTSTEWARD_* injection points, so no test
# reads the host's shells file, os-release, user database or macOS version.
_ds_write_platform_files() {
  local dir=$DS_TEST_ROOT/platform
  printf '%s\n' '# /etc/shells: valid login shells' /bin/sh /bin/bash /usr/bin/bash >"$dir/shells"
  cp "$_DS_LIB_DIR/../fixtures/common/os-release/ubuntu-24.04" "$dir/os-release"
  chmod 0644 "$dir/os-release"
  export DS_PASSWD_FILE=$dir/passwd DS_GROUP_FILE=$dir/group
  printf '%s:x:1000:1000:%s:%s:/bin/bash\n' "$DS_TEST_IDENTITY_NAME" "$DS_TEST_IDENTITY_NAME" "$HOME" \
    >"$DS_PASSWD_FILE"
  printf '%s:x:1000:\n' "$DS_TEST_IDENTITY_NAME" >"$DS_GROUP_FILE"
  # Replacement for `getent passwd [USER]`: the entry of the user database,
  # or a synthetic entry for a user it does not list.
  cat >"$dir/user-db" <<EOF
#!$BASH
set -euo pipefail
user=\${1:-\${USER:-$DS_TEST_IDENTITY_NAME}}
awk -F: -v user="\$user" '\$1 == user { print; found = 1; exit } END { exit !found }' \\
  '$DS_PASSWD_FILE' ||
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
  # A 16 GiB machine with 12 CPUs, whose derived gate parallelism is two
  # jobs with six cores.
  export DOTSTEWARD_MEMORY_MIB=16384 DOTSTEWARD_CPU_COUNT=12
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

# _ds_call_line NAME [ARG...]: NAME followed by each argument quoted with
# printf %q.
_ds_call_line() {
  local line
  line=$(printf '%s' "$1")
  shift
  if (($#)); then
    line+=$(printf ' %q' "$@")
  fi
  printf '%s' "$line"
}

# ds_record_call NAME [ARG...]
# Appends one line to $DS_CALL_LOG: NAME followed by each argument quoted
# with printf %q. Stubs use it; assert_calls compares the log.
ds_record_call() {
  printf '%s\n' "$(_ds_call_line "$@")" >>"$DS_CALL_LOG"
}

# ds_defer COMMAND [ARG...]: runs the command when the test exits (in
# reverse registration order, standard error discarded), before the
# temporary root is removed.
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
    # Best effort: a cleanup error must not replace the test's own failure
    # message, which tests/run.sh reads from the last line of output.
    eval "${DS_DEFERRED[i]}" 2>/dev/null
  done
  cd / || true
  if [[ -n ${DS_TEST_ROOT:-} && -d $DS_TEST_ROOT && ! -L $DS_TEST_ROOT &&
    $(basename -- "$DS_TEST_ROOT") == dotsteward-test.* ]]; then
    chmod -R u+rwx -- "$DS_TEST_ROOT" 2>/dev/null
    rm -rf -- "$DS_TEST_ROOT"
  fi
  exit "$status"
}

_ds_usage() {
  printf '%s: usage: %s\n' "${FUNCNAME[1]}" "$1" >&2
  return 1
}

_ds_error() {
  printf '%s: %s\n' "${FUNCNAME[1]}" "$1" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# ds_fixture RELATIVE_PATH: the absolute path of tests/fixtures/RELATIVE_PATH.
ds_fixture() {
  (($# == 1)) || _ds_usage "ds_fixture RELATIVE_PATH" || return
  local path=$DS_REPO_ROOT/tests/fixtures/$1
  [[ -e $path ]] || _ds_error "no such fixture: $1" || return
  printf '%s\n' "$path"
}

# ds_fixture_skill_tree DIR [NAME]
# Builds a skill directory that exercises directory digests and copies:
# SKILL.md (frontmatter name NAME, default example-skill), references/ (mode
# 0750), a hidden file, scripts/run.sh (0755), scripts/private.txt (0600),
# Python bytecode in __pycache__/ and as scripts/helper.pyc, a file with a
# non-ASCII name (built from escapes) and one with a space, link.md (a
# symlink to references/guide.md) and an empty directory. With the default
# NAME its digest is DS_FIXTURE_SKILL_TREE_SHA256.
ds_fixture_skill_tree() {
  (($# == 1 || $# == 2)) || _ds_usage "ds_fixture_skill_tree DIR [NAME]" || return
  local dir=$1 name=${2:-example-skill}
  [[ ! -e $dir && ! -L $dir ]] || _ds_error "already exists: $dir" || return
  mkdir -p "$dir"/{references,scripts,__pycache__,empty}
  printf -- '---\nname: %s\ndescription: Synthetic skill for dotsteward tests.\n---\n\n# %s\n\nRead references/guide.md first.\n' \
    "$name" "$name" >"$dir/SKILL.md"
  printf '# Guide\n\nSynthetic reference text.\n' >"$dir/references/guide.md"
  printf 'hidden=true\n' >"$dir/.hidden-config"
  printf '#!/bin/sh\necho run\n' >"$dir/scripts/run.sh"
  printf 'private notes\n' >"$dir/scripts/private.txt"
  printf 'def helper():\n    return 1\n' >"$dir/scripts/helper.py"
  printf 'bytecode' >"$dir/scripts/helper.pyc"
  printf 'bytecode' >"$dir/__pycache__/helper.cpython-312.pyc"
  printf 'unicode name\n' >"$dir/"$'caf\xc3\xa9.md'
  printf 'space name\n' >"$dir/with space.md"
  ln -s references/guide.md "$dir/link.md"
  chmod 0755 "$dir/scripts/run.sh"
  chmod 0600 "$dir/scripts/private.txt"
  chmod 0644 "$dir/SKILL.md" "$dir/references/guide.md" "$dir/.hidden-config" \
    "$dir/scripts/helper.py" "$dir/scripts/helper.pyc" "$dir/__pycache__/helper.cpython-312.pyc" \
    "$dir/"$'caf\xc3\xa9.md' "$dir/with space.md"
  chmod 0750 "$dir/references"
}

# ds_fixture_backup_layouts STATE_ROOT
# Builds STATE_ROOT/backups with every layout backups have had; each copy
# holds the name of its backup directory. Directories are 0700, files 0600.
#   20251231T000000Z/files/home/.codex/AGENTS.md          legacy layout
#                                                         (files/home/<path
#                                                         relative to HOME>)
#   20260101T000000Z/files$HOME/.zshrc                     current layout
#   20260102T000000Z/files$HOME/.zshrc                     same second ...
#   20260102T000000Z-adopt/files$HOME/.zshrc               ... with a suffix
#   20260103T000000Z-skills/files$HOME/.agents/skills/example-skill/SKILL.md
#   20260104T000000Z-pre-local-maintained-files/${HOME#/}/.config/example-term/config.toml
#                                                         no files/ level
#   20260105T000000Z/files$HOME/.config/link               a dangling link copy
# The newest regular copy of $HOME/.zshrc is the -adopt one, of
# $HOME/.codex/AGENTS.md the legacy one; $HOME/.config/link has none.
ds_fixture_backup_layouts() {
  (($# == 1)) || _ds_usage "ds_fixture_backup_layouts STATE_ROOT" || return
  local backups=$1/backups entry dir file
  [[ ! -e $backups ]] || _ds_error "already exists: $backups" || return
  for entry in \
    "20251231T000000Z|files/home/.codex/AGENTS.md" \
    "20260101T000000Z|files$HOME/.zshrc" \
    "20260102T000000Z|files$HOME/.zshrc" \
    "20260102T000000Z-adopt|files$HOME/.zshrc" \
    "20260103T000000Z-skills|files$HOME/.agents/skills/example-skill/SKILL.md" \
    "20260104T000000Z-pre-local-maintained-files|${HOME#/}/.config/example-term/config.toml"; do
    dir=$backups/${entry%%|*}
    file=$dir/${entry#*|}
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "${entry%%|*}" >"$file"
    chmod 0600 "$file"
  done
  mkdir -p "$backups/20260105T000000Z/files$HOME/.config"
  ln -s "$HOME/.config/missing-target" "$backups/20260105T000000Z/files$HOME/.config/link"
  find "$1/backups" -type d -exec chmod 0700 {} +
}

# ---------------------------------------------------------------------------
# Stubs: test side
# ---------------------------------------------------------------------------

# Names that accept stub state besides the stub files: the activate script
# of fake nix build outputs.
_DS_STUB_EXTRA_NAMES=" activate "

_ds_stub_known() {
  [[ -n $1 && $1 != */* && ($_DS_STUB_EXTRA_NAMES == *" $1 "* || -f $_DS_LIB_DIR/stubs/$1) ]] ||
    {
      printf '%s: unknown stub: %s\n' "${FUNCNAME[1]}" "$1" >&2
      return 1
    }
}

# ds_use_stubs --all | NAME...
# Links the named stubs into DS_TEST_ROOT/bin and puts that directory first
# on PATH (once). Stubs are never on PATH unless a test asks for them.
ds_use_stubs() {
  (($#)) || _ds_usage "ds_use_stubs --all | NAME..." || return
  local stubs=$_DS_LIB_DIR/stubs bin=$DS_TEST_ROOT/bin name names=()
  if [[ $1 == --all && $# == 1 ]]; then
    for name in "$stubs"/*; do
      names+=("$(basename "$name")")
    done
  else
    for name in "$@"; do
      [[ $name != */* && -f $stubs/$name ]] || _ds_error "unknown stub: $name" || return
    done
    names=("$@")
  fi
  mkdir -p "$bin"
  for name in "${names[@]}"; do
    ln -sfn "$stubs/$name" "$bin/$name"
  done
  case ":$PATH:" in
    ":$bin:"*) ;;
    *) export PATH=$bin:$PATH ;;
  esac
  hash -r
}

# ds_stub_set NAME KEY VALUE|-
# Writes the state value KEY of stub NAME (followed by a newline; stubs read
# it without trailing newlines). VALUE "-" reads the value from standard input.
ds_stub_set() {
  (($# == 3)) || _ds_usage "ds_stub_set NAME KEY VALUE|-" || return
  _ds_stub_known "$1" || return
  [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $2 != routes && $2 != override ]] ||
    _ds_error "invalid key: $2" || return
  local dir=$DS_STUB_STATE/$1
  mkdir -p "$dir"
  if [[ $3 == - ]]; then
    cat >"$dir/$2"
  else
    printf '%s\n' "$3" >"$dir/$2"
  fi
}

# ds_stub_route NAME GLOB [--exit N] [--stdout TEXT | --stdout-file FILE]
#               [--stderr TEXT] [--times N] [--sleep SECONDS]
# Adds a canned answer: a call whose arguments, joined with single spaces,
# match the shell glob GLOB sleeps, prints TEXT (plus a newline) or the
# file's bytes on stdout, TEXT on stderr, and exits with N (default 0).
# Routes are tried in the order they were added; --times limits how often a
# route answers before it is removed.
ds_stub_route() {
  (($# >= 2)) || _ds_usage "ds_stub_route NAME GLOB [--exit N] [--stdout TEXT | --stdout-file FILE] [--stderr TEXT] [--times N] [--sleep SECONDS]" || return
  local name=$1 pattern=$2
  shift 2
  _ds_stub_known "$name" || return
  local status=0 stdout="" stdout_mode="" stderr="" have_stderr=0 times="" delay=""
  while (($#)); do
    (($# >= 2)) || _ds_error "option $1 requires a value" || return
    case $1 in
      --exit)
        [[ $2 =~ ^[0-9]+$ ]] && (($2 <= 255)) || _ds_error "invalid exit status: $2" || return
        status=$2
        ;;
      --stdout)
        stdout=$2
        stdout_mode="text"
        ;;
      --stdout-file)
        [[ -f $2 ]] || _ds_error "no such file: $2" || return
        stdout=$2
        stdout_mode="file"
        ;;
      --stderr)
        stderr=$2
        have_stderr=1
        ;;
      --times)
        [[ $2 =~ ^[1-9][0-9]*$ ]] || _ds_error "invalid count: $2" || return
        times=$2
        ;;
      --sleep)
        [[ $2 =~ ^[0-9]+([.][0-9]+)?$ ]] || _ds_error "invalid delay: $2" || return
        delay=$2
        ;;
      *) _ds_error "unknown option: $1" || return ;;
    esac
    shift 2
  done
  local routes=$DS_STUB_STATE/$name/routes last=0 entry number dir
  mkdir -p "$routes"
  for entry in "$routes"/*; do
    [[ -d $entry ]] || continue
    number=$((10#$(basename "$entry")))
    ((number > last)) && last=$number
  done
  dir=$routes/$(printf '%06d' $((last + 1)))
  mkdir "$dir"
  printf '%s' "$pattern" >"$dir/pattern"
  printf '%s\n' "$status" >"$dir/exit"
  case $stdout_mode in
    text) printf '%s\n' "$stdout" >"$dir/stdout" ;;
    file) cp -- "$stdout" "$dir/stdout" ;;
  esac
  if ((have_stderr)); then
    printf '%s\n' "$stderr" >"$dir/stderr"
  fi
  [[ -z $times ]] || printf '%s\n' "$times" >"$dir/times"
  [[ -z $delay ]] || printf '%s\n' "$delay" >"$dir/sleep"
}

# ds_stub_clear_routes NAME: removes every route of the stub.
ds_stub_clear_routes() {
  (($# == 1)) || _ds_usage "ds_stub_clear_routes NAME" || return
  _ds_stub_known "$1" || return
  rm -rf -- "${DS_STUB_STATE:?}/$1/routes"
}

# ds_stub_override NAME
# Reads a script from standard input; the stub records its call and then
# executes the script with its arguments instead of its own behaviour. A
# `#!/usr/bin/env PROGRAM` line is resolved to PROGRAM's path, so the script
# also runs where /usr/bin/env does not exist (the Nix build sandbox).
ds_stub_override() {
  (($# == 1)) || _ds_usage "ds_stub_override NAME" || return
  _ds_stub_known "$1" || return
  local dir=$DS_STUB_STATE/$1 first rest program resolved
  mkdir -p "$dir"
  IFS= read -r first || true
  rest=$(cat)
  if [[ $first =~ ^#![[:space:]]*/usr/bin/env[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
    program=${BASH_REMATCH[1]}
    resolved=$(command -v "$program") || _ds_error "no such program: $program" || return
    first="#!$resolved"
  fi
  printf '%s\n%s\n' "$first" "$rest" >"$dir/override"
  chmod 0755 "$dir/override"
}

# ds_calls_of NAME: the call lines of stub NAME, in order.
ds_calls_of() {
  (($# == 1)) || _ds_usage "ds_calls_of NAME" || return
  [[ -f $DS_CALL_LOG ]] || return 0
  awk -v name="$1" '$1 == name' "$DS_CALL_LOG"
}

# ds_env_of NAME: the environment lines of stub NAME, in order.
ds_env_of() {
  (($# == 1)) || _ds_usage "ds_env_of NAME" || return
  [[ -f $DS_CALL_LOG ]] || return 0
  awk -v name="$1:env" '$1 == name' "$DS_CALL_LOG"
}

# ds_call_count NAME [GLOB]
# The number of calls of NAME whose logged argument text (as written to the
# log, quoted) matches the shell glob GLOB (default: every call).
ds_call_count() {
  (($# == 1 || $# == 2)) || _ds_usage "ds_call_count NAME [GLOB]" || return
  local name=$1 pattern=${2:-*} line rest count=0
  while IFS= read -r line; do
    rest=""
    [[ $line == "$name "* ]] && rest=${line#"$name "}
    # shellcheck disable=SC2053 # GLOB is a pattern on purpose
    [[ $rest == $pattern ]] && count=$((count + 1))
  done < <(ds_calls_of "$name")
  printf '%s\n' "$count"
}

# ---------------------------------------------------------------------------
# Stubs: stub side (used by the files in tests/lib/stubs)
# ---------------------------------------------------------------------------

# ds_stub_begin [--no-routes] NAME [ARG...]
# Records the call (and the selected environment: state key "env", else
# DS_STUB_ENV_DEFAULT), runs an override when one exists, then answers with
# the first matching route unless --no-routes is given. Sets DS_STUB_NAME
# and DS_STUB_DIR for the stub.
ds_stub_begin() {
  local routes=1
  if [[ ${1:-} == --no-routes ]]; then
    routes=0
    shift
  fi
  local name=$1
  shift
  if [[ -z ${DS_CALL_LOG:-} || -z ${DS_STUB_STATE:-} ]]; then
    printf '%s stub: DS_CALL_LOG and DS_STUB_STATE are not set; stubs run only inside the test harness\n' \
      "$name" >&2
    exit 1
  fi
  DS_STUB_NAME=$name
  DS_STUB_DIR=$DS_STUB_STATE/$name
  local lines vars var
  lines=$(_ds_call_line "$name" "$@")
  if [[ -f $DS_STUB_DIR/env ]]; then
    vars=$(<"$DS_STUB_DIR/env")
  else
    vars=${DS_STUB_ENV_DEFAULT:-}
  fi
  if [[ -n ${vars//[[:space:]]/} ]]; then
    lines+=$'\n'"$name:env"
    for var in $vars; do
      if [[ -v $var ]]; then
        lines+=" $var=$(printf '%q' "${!var}")"
      else
        lines+=" -$var"
      fi
    done
  fi
  printf '%s\n' "$lines" >>"$DS_CALL_LOG"
  if [[ -x $DS_STUB_DIR/override ]]; then
    exec "$DS_STUB_DIR/override" "$@"
  fi
  if ((routes)); then
    ds_stub_try_route "$*" || true
  fi
  return 0
}

# ds_stub_try_route KEY: answers and exits when a route of the current stub
# matches KEY; returns 1 otherwise.
ds_stub_try_route() {
  local route
  route=$(_ds_stub_take_route "$DS_STUB_NAME" "$1") || return 1
  ds_stub_reply_route "$route"
}

# _ds_stub_take_route NAME KEY: prints the directory of the first route of
# NAME that matches KEY and uses it up once (under a lock, so parallel calls
# never share a single-use route).
_ds_stub_take_route() {
  local routes=$DS_STUB_STATE/$1/routes key=$2 dir pattern times used
  [[ -d $routes ]] || return 1
  if command -v flock >/dev/null 2>&1; then
    exec {_ds_lock_fd}>"$DS_STUB_STATE/$1/.routes.lock"
    flock "$_ds_lock_fd"
  fi
  for dir in "$routes"/*; do
    [[ -f $dir/pattern ]] || continue
    pattern=$(<"$dir/pattern")
    # shellcheck disable=SC2053 # the route pattern is a glob on purpose
    [[ $key == $pattern ]] || continue
    if [[ -f $dir/times ]]; then
      times=$(<"$dir/times")
      if ((times <= 1)); then
        mkdir -p "$DS_STUB_STATE/$1/used"
        used=$(mktemp -d "$DS_STUB_STATE/$1/used/route.XXXXXX")
        rmdir "$used"
        mv "$dir" "$used"
        dir=$used
      else
        printf '%s\n' $((times - 1)) >"$dir/times"
      fi
    fi
    printf '%s\n' "$dir"
    _ds_stub_unlock
    return 0
  done
  _ds_stub_unlock
  return 1
}

_ds_stub_unlock() {
  if [[ -n ${_ds_lock_fd:-} ]]; then
    exec {_ds_lock_fd}>&-
    _ds_lock_fd=""
  fi
}

# ds_stub_reply_route DIR: sleeps, prints and exits as the route says.
ds_stub_reply_route() {
  local dir=$1
  if [[ -f $dir/sleep ]]; then
    sleep "$(<"$dir/sleep")"
  fi
  if [[ -f $dir/stdout ]]; then
    cat -- "$dir/stdout"
  fi
  if [[ -f $dir/stderr ]]; then
    cat -- "$dir/stderr" >&2
  fi
  exit "$(<"$dir/exit")"
}

# ds_stub_value KEY [DEFAULT]: the state value KEY of the current stub
# without trailing newlines, or DEFAULT.
ds_stub_value() {
  local file=$DS_STUB_DIR/$1
  if [[ -f $file ]]; then
    printf '%s' "$(<"$file")"
  else
    printf '%s' "${2:-}"
  fi
}

# ds_stub_as_root: true when the stub runs below the sudo stub.
ds_stub_as_root() {
  [[ ${DS_STUB_AS_ROOT:-0} == 1 ]]
}

# ds_stub_app NAME VERSION HELP [ARG...]
# The behaviour of a plain application stub: --version / -v / version print
# the state value "version" (default VERSION), --help / -h / help print the
# state value "help" (default HELP); anything else succeeds silently.
ds_stub_app() {
  local version=$2 help=$3
  shift 3
  case ${1:-} in
    --version | -v | -V | version) printf '%s\n' "$(ds_stub_value version "$version")" ;;
    --help | -h | help) printf '%s\n' "$(ds_stub_value help "$help")" ;;
  esac
  exit 0
}

# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

# ds_passwd_set USER SHELL [UID] [HOME]
# Adds USER to the user database, or replaces its shell (and UID and HOME
# when given). New users get the next free UID (the GID equals the UID) and
# the home directory DS_TEST_ROOT/users/USER unless HOME is given.
ds_passwd_set() {
  (($# >= 2 && $# <= 4)) || _ds_usage "ds_passwd_set USER SHELL [UID] [HOME]" || return
  local user=$1 shell=$2 uid=${3:-} home=${4:-} tmp
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || _ds_error "invalid user name: $user" || return
  [[ $shell == /* && $shell != *:* ]] || _ds_error "invalid shell: $shell" || return
  [[ -z $uid || $uid =~ ^[0-9]+$ ]] || _ds_error "invalid uid: $uid" || return
  [[ $home != *:* ]] || _ds_error "invalid home: $home" || return
  tmp=$(mktemp "$DS_PASSWD_FILE.XXXXXX")
  awk -F: -v OFS=: -v user="$user" -v shell="$shell" -v uid="$uid" -v home="$home" \
    -v default_home="$DS_TEST_ROOT/users/$user" '
    $3 + 0 > max { max = $3 + 0 }
    $1 == user {
      if (uid != "") { $3 = uid; $4 = uid }
      if (home != "") $6 = home
      $7 = shell
      found = 1
    }
    { print }
    END {
      if (!found) {
        if (uid == "") uid = max + 1
        if (home == "") home = default_home
        print user, "x", uid, uid, user, home, shell
      }
    }' "$DS_PASSWD_FILE" >"$tmp"
  mv -- "$tmp" "$DS_PASSWD_FILE"
}

# ds_passwd_field USER N: field N (1-7) of USER's entry; status 1 when the
# user does not exist.
ds_passwd_field() {
  (($# == 2)) || _ds_usage "ds_passwd_field USER N" || return
  awk -F: -v user="$1" -v n="$2" '$1 == user { print $n; found = 1; exit } END { exit !found }' \
    "$DS_PASSWD_FILE"
}

# ds_group_add GROUP [USER...]: creates GROUP (next free GID) when missing and
# adds the users as members.
ds_group_add() {
  (($# >= 1)) || _ds_usage "ds_group_add GROUP [USER...]" || return
  local group=$1 tmp
  shift
  [[ $group =~ ^[a-z_][a-z0-9_-]*$ ]] || _ds_error "invalid group name: $group" || return
  tmp=$(mktemp "$DS_GROUP_FILE.XXXXXX")
  awk -F: -v OFS=: -v group="$group" -v add="$*" '
    BEGIN { n = split(add, users, " ") }
    $3 + 0 > max { max = $3 + 0 }
    $1 == group {
      found = 1
      for (i = 1; i <= n; i++) {
        if (("," $4 ",") !~ ("," users[i] ",")) $4 = ($4 == "" ? users[i] : $4 "," users[i])
      }
    }
    { print }
    END {
      if (!found) {
        members = ""
        for (i = 1; i <= n; i++) members = (members == "" ? users[i] : members "," users[i])
        print group, "x", max + 1, members
      }
    }' "$DS_GROUP_FILE" >"$tmp"
  mv -- "$tmp" "$DS_GROUP_FILE"
}

# ---------------------------------------------------------------------------
# Packages (dpkg database and APT index of the package stubs)
# ---------------------------------------------------------------------------

_ds_pkg_valid_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9+.-]+$ ]]
}

# _ds_control_paragraph PACKAGE VERSION ARCH [FIELD=VALUE...]
_ds_control_paragraph() {
  local package=$1 version=$2 arch=$3 field
  shift 3
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$package" "$version" "$arch"
  for field in "$@"; do
    [[ $field =~ ^[A-Za-z][A-Za-z0-9-]*= ]] || _ds_error "invalid field (want Name=value): $field" || return
    printf '%s: %s\n' "${field%%=*}" "${field#*=}"
  done
}

# ds_dpkg_installed PACKAGE VERSION [ARCH] [FIELD=VALUE...]
# Records PACKAGE as installed in the fake dpkg database. A "Files" field
# (space-separated absolute paths) feeds dpkg-query -L and -S.
ds_dpkg_installed() {
  (($# >= 2)) || _ds_usage "ds_dpkg_installed PACKAGE VERSION [ARCH] [FIELD=VALUE...]" || return
  _ds_pkg_valid_name "$1" || _ds_error "invalid package name: $1" || return
  local package=$1 version=$2 arch=${3:-amd64} paragraph
  shift $(($# >= 3 ? 3 : 2))
  paragraph=$(_ds_control_paragraph "$package" "$version" "$arch" "$@") || return
  _ds_pkgdb_install "$paragraph"
}

# ds_dpkg_config_files PACKAGE VERSION [ARCH]
# Records PACKAGE as removed but not purged (dpkg state config-files): the
# database keeps its Version, db:Status-Status is "config-files" and
# ds_dpkg_version reports nothing.
ds_dpkg_config_files() {
  (($# == 2 || $# == 3)) || _ds_usage "ds_dpkg_config_files PACKAGE VERSION [ARCH]" || return
  _ds_pkg_valid_name "$1" || _ds_error "invalid package name: $1" || return
  local paragraph
  paragraph=$(_ds_control_paragraph "$1" "$2" "${3:-amd64}") || return
  _ds_pkgdb_install "$paragraph" "deinstall ok config-files"
}

# _ds_pkgdb_install PARAGRAPH [STATUS]: installs a control paragraph with
# the Status line STATUS (default "install ok installed").
_ds_pkgdb_install() {
  local paragraph=$1 status=${2:-install ok installed} package dir=$DS_STUB_STATE/dpkg/installed
  package=$(sed -n 's/^Package: //p' <<<"$paragraph" | head -n 1)
  mkdir -p "$dir"
  {
    printf 'Package: %s\nStatus: %s\n' "$package" "$status"
    grep -v -e '^Package: ' -e '^Status: ' <<<"$paragraph" || true
  } >"$dir/$package"
}

# ds_dpkg_version PACKAGE: the installed version, empty when not installed
# (also when only its configuration files are left).
ds_dpkg_version() {
  (($# == 1)) || _ds_usage "ds_dpkg_version PACKAGE" || return
  local file=$DS_STUB_STATE/dpkg/installed/$1
  [[ -f $file ]] || return 0
  [[ $(sed -n 's/^Status: //p' "$file") == *' installed' ]] || return 0
  sed -n 's/^Version: //p' "$file"
}

# ds_apt_available PACKAGE VERSION [ARCH] [FIELD=VALUE...]
# Publishes PACKAGE at VERSION in the fake APT index; `apt-get install
# PACKAGE` installs exactly this version.
ds_apt_available() {
  (($# >= 2)) || _ds_usage "ds_apt_available PACKAGE VERSION [ARCH] [FIELD=VALUE...]" || return
  _ds_pkg_valid_name "$1" || _ds_error "invalid package name: $1" || return
  local package=$1 version=$2 arch=${3:-amd64} dir=$DS_STUB_STATE/apt/available
  shift $(($# >= 3 ? 3 : 2))
  mkdir -p "$dir"
  _ds_control_paragraph "$package" "$version" "$arch" "$@" >"$dir/$package"
}

# The first line of every fake package file.
_DS_FAKE_DEB_MAGIC='!<dotsteward-fake-deb>'

# ds_fake_deb OUT PACKAGE VERSION [ARCH] [FIELD=VALUE...]
# Writes a fake Debian package: the magic line, then control fields. The
# dpkg-deb, dpkg and apt-get stubs read it; it is not a real archive.
ds_fake_deb() {
  (($# >= 3)) || _ds_usage "ds_fake_deb OUT PACKAGE VERSION [ARCH] [FIELD=VALUE...]" || return
  _ds_pkg_valid_name "$2" || _ds_error "invalid package name: $2" || return
  local out=$1 package=$2 version=$3 arch=${4:-amd64} paragraph
  shift $(($# >= 4 ? 4 : 3))
  paragraph=$(_ds_control_paragraph "$package" "$version" "$arch" "$@") || return
  printf '%s\n%s\n' "$_DS_FAKE_DEB_MAGIC" "$paragraph" >"$out"
}

# _ds_deb_control FILE: the control paragraph of a fake package; status 1
# when FILE is not one.
_ds_deb_control() {
  [[ -f $1 ]] || return 1
  local first
  IFS= read -r first <"$1" || return 1
  [[ $first == "$_DS_FAKE_DEB_MAGIC" ]] || return 1
  tail -n +2 -- "$1"
}

# _ds_deb_version_compare A B: prints -1, 0 or 1 comparing two Debian
# versions (epoch, upstream version, revision; "~" sorts before anything,
# even the end of the string). An empty version is lower than any other.
_ds_deb_version_compare() {
  python3 -c '
import sys

def order(c):
    if c == "~":
        return -1
    if c.isdigit() or c == "":
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256

def verrevcmp(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = order(a[i] if i < len(a) else "")
            bc = order(b[j] if j < len(b) else "")
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and a[i].isdigit() and j < len(b) and b[j].isdigit():
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first_diff:
            return first_diff
    return 0

def parse(v):
    epoch = 0
    if ":" in v:
        e, v = v.split(":", 1)
        epoch = int(e) if e else 0
    if "-" in v:
        upstream, revision = v.rsplit("-", 1)
    else:
        upstream, revision = v, ""
    return epoch, upstream, revision

def compare(a, b):
    if a == "" or b == "":
        return (a != "") - (b != "")
    ea, ua, ra = parse(a)
    eb, ub, rb = parse(b)
    if ea != eb:
        return (ea > eb) - (ea < eb)
    r = verrevcmp(ua, ub) or verrevcmp(ra, rb)
    return (r > 0) - (r < 0)

print(compare(sys.argv[1], sys.argv[2]))
' "$1" "$2"
}

# ds_deb_compare_versions A OP B: dpkg --compare-versions semantics. OP is
# lt le eq ne ge gt (or << <= = >= >>); the -nl forms treat an empty version
# as later than any other. Status 0 when the relation holds, 1 when it does
# not, 2 for an unknown operator.
ds_deb_compare_versions() {
  local a=$1 op=$2 b=$3 result
  case $op in
    lt | le | eq | ne | ge | gt | '<<' | '<=' | '=' | '>=' | '>>') ;;
    lt-nl | le-nl | ge-nl | gt-nl)
      if [[ -z $a || -z $b ]]; then
        result=$(((${#a} == 0) - (${#b} == 0)))
        _ds_compare_result "$result" "${op%-nl}"
        return
      fi
      op=${op%-nl}
      ;;
    *)
      printf "dpkg: error: unknown relation '%s'\n" "$op" >&2
      return 2
      ;;
  esac
  result=$(_ds_deb_version_compare "$a" "$b")
  _ds_compare_result "$result" "$op"
}

_ds_compare_result() {
  case $2 in
    lt | '<<') (($1 < 0)) ;;
    le | '<=') (($1 <= 0)) ;;
    eq | '=') (($1 == 0)) ;;
    ne) (($1 != 0)) ;;
    ge | '>=') (($1 >= 0)) ;;
    gt | '>>') (($1 > 0)) ;;
  esac
}

# _ds_pkgdb_file PACKAGE: the database file of an installed package.
_ds_pkgdb_file() {
  printf '%s\n' "$DS_STUB_STATE/dpkg/installed/$1"
}

# _ds_dpkg_format FORMAT FILE: renders a dpkg-query --showformat FORMAT for
# the control paragraph in FILE (${Field} and ${Field;width}, field names
# case-insensitive, plus binary:Package and the db:Status-* virtual fields;
# \n, \t and \\ escapes).
_ds_dpkg_format() {
  local format out="" rest spec name width value line open=\$\{ want eflag state abbrev
  local -A fields=()
  printf -v format '%b' "$1"
  while IFS= read -r line; do
    [[ $line =~ ^([A-Za-z0-9:-]+):[[:space:]]?(.*)$ ]] || continue
    fields[${BASH_REMATCH[1],,}]=${BASH_REMATCH[2]}
  done <"$2"
  fields[binary:package]=${fields[package]-}
  # The db:Status-* fields come from the paragraph's "Status: WANT EFLAG
  # STATUS" line; the abbreviation uses dpkg's letters (dpkg -l).
  read -r want eflag state <<<"${fields[status]:-install ok installed}"
  fields[db:status-want]=$want
  fields[db:status-eflag]=$eflag
  fields[db:status-status]=$state
  case $want in
    deinstall) abbrev=r ;;
    *) abbrev=${want:0:1} ;;
  esac
  case $state in
    config-files) abbrev+=c ;;
    half-installed) abbrev+=H ;;
    half-configured) abbrev+=F ;;
    triggers-awaited) abbrev+=W ;;
    triggers-pending) abbrev+=t ;;
    unpacked) abbrev+=U ;;
    *) abbrev+=${state:0:1} ;;
  esac
  if [[ $eflag == ok ]]; then
    abbrev+=' '
  else
    abbrev+=R
  fi
  fields[db:status-abbrev]=$abbrev
  while [[ $format == *"$open"*"}"* ]]; do
    out+=${format%%"$open"*}
    rest=${format#*"$open"}
    spec=${rest%%\}*}
    format=${rest#*\}}
    name=${spec%%;*}
    value=${fields[${name,,}]-}
    if [[ $spec == *';'* ]]; then
      width=${spec#*;}
      if [[ $width == -* ]]; then
        printf -v value '%*s' "${width#-}" "$value"
      else
        printf -v value '%-*s' "$width" "$value"
      fi
    fi
    out+=$value
  done
  printf '%s' "$out$format"
}

# ds_stub_dpkg_query ARG...: the dpkg-query behaviour over the fake dpkg
# database (also used by the dpkg stub for its query actions):
#   -W|--show [-f|--showformat FORMAT] [PACKAGE...]
#   -s|--status PACKAGE...   -L|--listfiles PACKAGE...   -S|--search PATTERN...
# A "Files" field of a database entry (space-separated paths) feeds -L and
# -S. Missing packages are reported on stderr and make the status 1.
ds_stub_dpkg_query() {
  local action="" format="\${binary:Package}\\t\${Version}\\n" args=() status=0 package file
  while (($#)); do
    case $1 in
      -W | --show | -s | --status | -L | --listfiles | -S | --search) action=$1 ;;
      -f | --showformat)
        (($# >= 2)) || {
          printf 'dpkg-query: error: --showformat needs a value\n' >&2
          return 2
        }
        format=$2
        shift
        ;;
      -f* | --showformat=*)
        format=${1#--showformat=}
        format=${format#-f}
        format=${format#=}
        ;;
      --) ;;
      -*)
        printf 'dpkg-query: error: unknown option %s\n' "$1" >&2
        return 2
        ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  local db=$DS_STUB_STATE/dpkg/installed
  case $action in
    -W | --show)
      if ((${#args[@]} == 0)); then
        for file in "$db"/*; do
          [[ -f $file ]] && _ds_dpkg_format "$format" "$file"
        done
        return 0
      fi
      for package in "${args[@]}"; do
        file=$db/$package
        if [[ -f $file ]]; then
          _ds_dpkg_format "$format" "$file"
        else
          printf 'dpkg-query: no packages found matching %s\n' "$package" >&2
          status=1
        fi
      done
      ;;
    -s | --status)
      for package in "${args[@]}"; do
        file=$db/$package
        if [[ -f $file ]]; then
          grep -v '^Files: ' "$file" || true
          printf '\n'
        else
          printf "dpkg-query: package '%s' is not installed and no information is available\n" "$package" >&2
          status=1
        fi
      done
      ;;
    -L | --listfiles)
      for package in "${args[@]}"; do
        file=$db/$package
        if [[ -f $file ]]; then
          sed -n 's/^Files: //p' "$file" | tr ' ' '\n' | sed '/^$/d'
        else
          printf "dpkg-query: package '%s' is not installed\n" "$package" >&2
          status=1
        fi
      done
      ;;
    -S | --search)
      local pattern path found paths
      for pattern in "${args[@]}"; do
        found=0
        [[ $pattern == /* || $pattern == *[*?[]* ]] || pattern="*$pattern*"
        for file in "$db"/*; do
          [[ -f $file ]] || continue
          read -r -a paths <<<"$(sed -n 's/^Files: //p' "$file")"
          for path in "${paths[@]}"; do
            # shellcheck disable=SC2053 # the search pattern is a glob
            if [[ $path == $pattern ]]; then
              printf '%s: %s\n' "$(basename "$file")" "$path"
              found=1
            fi
          done
        done
        if ((!found)); then
          printf 'dpkg-query: no path found matching pattern %s\n' "$pattern" >&2
          status=1
        fi
      done
      ;;
    *)
      printf 'dpkg-query: error: need an action option\n' >&2
      return 2
      ;;
  esac
  return "$status"
}

# ds_stub_deb_install FILE: installs a fake package file into the fake dpkg
# database (no root check; the calling stub does that).
ds_stub_deb_install() {
  local control
  control=$(_ds_deb_control "$1") || {
    printf "dpkg-deb: error: '%s' is not a Debian format archive\n" "$1" >&2
    return 2
  }
  _ds_pkgdb_install "$control"
}

# ---------------------------------------------------------------------------
# Downloads (curl stub answers) and the loopback HTTP server
# ---------------------------------------------------------------------------

# _ds_curl_path URL: the file that answers URL in the curl stub's web root
# (DS_STUB_STATE/curl/www/<host[:port]>/<path>[?query]). Sidecar files with
# the suffixes .status, .exit, .delay and .location are reserved.
_ds_curl_path() {
  local url=$1 rest host path
  [[ $url =~ ^[a-z][a-z0-9+.-]*:// ]] || _ds_error "not a URL: $url" || return
  rest=${url#*://}
  host=${rest%%[/?]*}
  path=${rest:${#host}}
  [[ $path == /* ]] || path=/$path
  [[ $path != */ && $path != /\?* ]] || path=${path%%\?*}__index__${path#"${path%%\?*}"}
  [[ $path != *"/../"* && $path != *"/.." ]] || _ds_error "dot segments are not supported: $url" || return
  printf '%s\n' "$DS_STUB_STATE/curl/www/${host,,}$path"
}

# ds_curl_serve URL FILE [STATUS]: the curl stub answers URL with FILE's bytes
# and HTTP status STATUS (default 200).
ds_curl_serve() {
  (($# == 2 || $# == 3)) || _ds_usage "ds_curl_serve URL FILE [STATUS]" || return
  local target
  [[ -f $2 ]] || _ds_error "no such file: $2" || return
  target=$(_ds_curl_path "$1") || return
  mkdir -p "$(dirname "$target")"
  cp -- "$2" "$target"
  rm -f -- "$target.status"
  if (($# == 3)); then
    [[ $3 =~ ^[1-5][0-9][0-9]$ ]] || _ds_error "invalid HTTP status: $3" || return
    printf '%s\n' "$3" >"$target.status"
  fi
}

# ds_curl_fail URL EXIT [MESSAGE]: the curl stub fails for URL with curl exit
# status EXIT and the error MESSAGE (shown as "curl: (EXIT) MESSAGE").
ds_curl_fail() {
  (($# == 2 || $# == 3)) || _ds_usage "ds_curl_fail URL EXIT [MESSAGE]" || return
  local target
  [[ $2 =~ ^[1-9][0-9]?$ ]] || _ds_error "invalid curl exit status: $2" || return
  target=$(_ds_curl_path "$1") || return
  mkdir -p "$(dirname "$target")"
  printf '%s\n%s\n' "$2" "${3:-Failure}" >"$target.exit"
}

# ds_curl_delay URL SECONDS: the curl stub waits before answering URL (and
# fails with exit 28 when --max-time is shorter).
ds_curl_delay() {
  (($# == 2)) || _ds_usage "ds_curl_delay URL SECONDS" || return
  local target
  [[ $2 =~ ^[0-9]+$ ]] || _ds_error "invalid delay: $2" || return
  target=$(_ds_curl_path "$1") || return
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$2" >"$target.delay"
}

# ds_curl_redirect URL TARGET_URL [STATUS]: URL answers with a redirect
# (default 302) to TARGET_URL; curl follows it with --location.
ds_curl_redirect() {
  (($# == 2 || $# == 3)) || _ds_usage "ds_curl_redirect URL TARGET_URL [STATUS]" || return
  local target
  target=$(_ds_curl_path "$1") || return
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$2" >"$target.location"
  printf '%s\n' "${3:-302}" >"$target.status"
}

# ds_httpfix_start ROOT
# Starts tests/lib/httpfix.py on a free loopback port, serving ROOT; sets
# DS_HTTPFIX_URL (http://127.0.0.1:PORT), DS_HTTPFIX_PID and DS_HTTPFIX_LOG
# (one "METHOD PATH" line per request). The server stops when the test exits
# or with ds_httpfix_stop.
ds_httpfix_start() {
  (($# == 1)) || _ds_usage "ds_httpfix_start ROOT" || return
  [[ -d $1 ]] || _ds_error "no such directory: $1" || return
  local dir port="" _
  dir=$(mktemp -d "$DS_TEST_ROOT/httpfix.XXXXXX")
  DS_HTTPFIX_LOG=$dir/requests.log
  python3 "$_DS_LIB_DIR/httpfix.py" "$1" --port 0 --port-file "$dir/port" --log "$DS_HTTPFIX_LOG" \
    >"$dir/server.log" 2>&1 &
  DS_HTTPFIX_PID=$!
  ds_defer _ds_stop_process "$DS_HTTPFIX_PID"
  for _ in $(seq 1 200); do
    if [[ -s $dir/port ]]; then
      port=$(<"$dir/port")
      break
    fi
    kill -0 "$DS_HTTPFIX_PID" 2>/dev/null || break
    sleep 0.05
  done
  [[ -n $port ]] || _ds_error "httpfix did not start: $(cat "$dir/server.log")" || return
  DS_HTTPFIX_URL=http://127.0.0.1:$port
  export DS_HTTPFIX_URL DS_HTTPFIX_PID DS_HTTPFIX_LOG
}

# ds_httpfix_stop: stops the server started last.
ds_httpfix_stop() {
  [[ -n ${DS_HTTPFIX_PID:-} ]] || return 0
  _ds_stop_process "$DS_HTTPFIX_PID"
}

_ds_stop_process() {
  kill "$1" 2>/dev/null || return 0
  wait "$1" 2>/dev/null || true
}
