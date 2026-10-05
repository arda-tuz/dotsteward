#!/usr/bin/env bash
# Fake SSH transport for git (a GIT_SSH_COMMAND), so code keeps byte-identical
# SSH remote URLs (git@github.com:org/repo.git, ssh://user@host:port/path)
# while talking to local bare repositories.
#
# Sourced from a test (after the harness) it defines:
#   ds_fakessh_enable        exports GIT_SSH_COMMAND (this file),
#                            DS_FAKESSH_MAP and DS_FAKESSH_LOG
#   ds_fakessh_map URL BARE  serves the bare repository BARE for URL
# Executed by git as `fakessh.sh [OPTIONS] [USER@]HOST COMMAND`, it accepts
# OpenSSH options (-G for git's variant probe, -o OPT, -p PORT, -4, -6, ...),
# runs git-upload-pack, git-receive-pack or git-upload-archive against the
# mapped repository and appends "USER@HOST COMMAND PATH" to DS_FAKESSH_LOG.
# An unmapped repository fails like a missing GitHub repository. Test knobs
# (environment): DS_FAKESSH_SLEEP=SECONDS delays the connection,
# DS_FAKESSH_FAIL=1 refuses it (exit 255).

_ds_fakessh_self=$(readlink -f "${BASH_SOURCE[0]}")

# _ds_fakessh_key USER@HOST PATH: the map key (path without leading slashes
# or "~/", host lowercased).
_ds_fakessh_key() {
  local host=$1 path=$2
  path=${path#\~/}
  while [[ $path == /* ]]; do path=${path#/}; done
  printf '%s %s' "${host,,}" "$path"
}

ds_fakessh_enable() {
  export GIT_SSH_COMMAND=$_ds_fakessh_self
  export DS_FAKESSH_MAP=${DS_FAKESSH_MAP:-$DS_TEST_ROOT/fakessh.map}
  export DS_FAKESSH_LOG=${DS_FAKESSH_LOG:-$DS_TEST_ROOT/fakessh.log}
  touch "$DS_FAKESSH_MAP" "$DS_FAKESSH_LOG"
}

ds_fakessh_map() {
  (($# == 2)) || {
    printf 'ds_fakessh_map: usage: ds_fakessh_map URL BARE\n' >&2
    return 1
  }
  [[ -n ${DS_FAKESSH_MAP:-} ]] || {
    printf 'ds_fakessh_map: call ds_fakessh_enable first\n' >&2
    return 1
  }
  local url=$1 bare host path rest
  bare=$(cd "$2" && pwd -P) || return 1
  if [[ $url =~ ^ssh://([^/]+)(/.*)$ ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    host=${host%:*}
  elif [[ $url =~ ^([^/:]+@)?[^/:]+: ]]; then
    host=${url%%:*}
    rest=${url#*:}
    path=$rest
  else
    printf 'ds_fakessh_map: not an SSH URL: %s\n' "$url" >&2
    return 1
  fi
  [[ $host == *@* ]] || host=$USER@$host
  printf '%s\t%s\n' "$(_ds_fakessh_key "$host" "$path")" "$bare" >>"$DS_FAKESSH_MAP"
}

_ds_fakessh_main() {
  local host="" command
  while (($#)); do
    case $1 in
      -G) exit 0 ;;
      -o | -p | -i | -l | -F | -J | -E | -c | -m | -b)
        (($# >= 2)) || {
          printf 'fakessh: option %s requires an argument\n' "$1" >&2
          exit 255
        }
        shift 2
        ;;
      -[46AaCfgKkMNnqsTtVvXxYy]*) shift ;;
      --) shift && break ;;
      -*)
        printf 'fakessh: unknown option %s\n' "$1" >&2
        exit 255
        ;;
      *) break ;;
    esac
  done
  (($# >= 2)) || {
    printf 'usage: fakessh.sh [OPTIONS] [USER@]HOST COMMAND\n' >&2
    exit 255
  }
  host=$1
  shift
  command=$*
  [[ $host == *@* ]] || host=${USER:-git}@$host
  if [[ -n ${DS_FAKESSH_SLEEP:-} ]]; then
    sleep "$DS_FAKESSH_SLEEP"
  fi
  if [[ ${DS_FAKESSH_FAIL:-0} == 1 ]]; then
    printf 'ssh: connect to host %s port 22: Connection refused\n' "${host#*@}" >&2
    exit 255
  fi
  local service path
  if [[ $command =~ ^(git-upload-pack|git-receive-pack|git-upload-archive)\ +\'([^\']*)\'$ ]] ||
    [[ $command =~ ^(git-upload-pack|git-receive-pack|git-upload-archive)\ +([^\ \']+)$ ]]; then
    service=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
  else
    printf 'fakessh: unsupported command: %s\n' "$command" >&2
    exit 1
  fi
  local key bare=""
  key=$(_ds_fakessh_key "$host" "$path")
  if [[ -n ${DS_FAKESSH_LOG:-} ]]; then
    printf '%s %s %s\n' "$host" "$service" "${key#* }" >>"$DS_FAKESSH_LOG"
  fi
  if [[ -n ${DS_FAKESSH_MAP:-} && -f $DS_FAKESSH_MAP ]]; then
    bare=$(awk -F'\t' -v key="$key" '$1 == key { found = $2 } END { print found }' "$DS_FAKESSH_MAP")
  fi
  if [[ -z $bare || ! -d $bare ]]; then
    printf 'ERROR: Repository not found.\n' >&2
    exit 1
  fi
  exec git "${service#git-}" "$bare"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  _ds_fakessh_main "$@"
fi
