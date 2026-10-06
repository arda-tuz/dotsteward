#!/usr/bin/env bash
# dotsteward instance launcher. Framework-owned: instances keep this file
# byte-identical to the pinned framework's template/.dotsteward/cli.sh
# (`dotsteward static` checks it; updates refresh it).
#
# Usage: .dotsteward/cli.sh <command> [ARG...]
#
# Runs the dotsteward CLI pinned by this instance's flake.lock, with
# DOTSTEWARD_INSTANCE set to this instance:
#   1. DOTSTEWARD_CLI set: exec it (a path, or a command name on PATH).
#   2. key = sha256 of the flake.lock bytes; when $STATE/cli/<key>/bin/dotsteward
#      exists, exec it (no Nix needed).
#   3. Otherwise build "git+file://<instance>#dotsteward" with
#      --no-update-lock-file, register the result as the GC root
#      $STATE/cli/<key> (nix-store --add-root), keep the 5 newest keys and
#      exec it.
#   4. No nix on PATH, even after sourcing the Nix daemon profile: refuse
#      with the bootstrap hint.
# The CLI depends only on the framework input and nixpkgs, both pinned by
# flake.lock, so a dirty tree is fine: git+file sees tracked files with
# their uncommitted changes and ignores untracked ones, and a changed
# flake.lock is a new key.
#
# $STATE: DOTSTEWARD_STATE_ROOT > DOTFILES_STATE_ROOT when [compat]
# legacy_env = true > state.root in workstation.toml (a leading
# ${NAME:-DEFAULT} and ~ expanded as the CLI does) > the schema default
# ${XDG_STATE_HOME:-~/.local/state}/dotsteward, expanded the same way. A
# relative result is refused, as the CLI refuses it.
#
# Runs with /bin/bash 3.2 and BSD tools (stock macOS) as well as GNU ones.
set -Eeuo pipefail

die() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
  exit 1
}

# Resolve symlinks to find the instance root, without GNU-only tools.
source_path=${BASH_SOURCE[0]}
while [ -L "$source_path" ]; do
  link_dir=$(cd -P -- "$(dirname -- "$source_path")" && pwd)
  source_path=$(readlink -- "$source_path")
  case $source_path in
    /*) ;;
    *) source_path=$link_dir/$source_path ;;
  esac
done
root=$(cd -P -- "$(dirname -- "$source_path")/.." && pwd)
export DOTSTEWARD_INSTANCE=$root

# Step 1: the development override.
if [ -n "${DOTSTEWARD_CLI:-}" ]; then
  override=$DOTSTEWARD_CLI
  case $override in
    */*) ;;
    *) override=$(command -v -- "$override" 2>/dev/null || true) ;;
  esac
  if [ -z "$override" ] || [ -d "$override" ] || [ ! -x "$override" ]; then
    die "DOTSTEWARD_CLI is not an executable file: $DOTSTEWARD_CLI"
  fi
  exec "$override" "$@"
fi

# --- workstation.toml, read minimally -----------------------------------

config=$root/workstation.toml

# toml_value TABLE KEY: prints the raw value of KEY in [TABLE] (also
# accepted as the dotted key TABLE.KEY before the first table) and returns
# 0, or returns 1 when the key is absent. Comments and surrounding blanks
# are removed; array tables, inline tables and multi-line values are not
# read.
toml_value() {
  local table=$1 key=$2 current="" line name value
  [ -f "$config" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
      '' | '#'*) continue ;;
      '[['*)
        current="[[array]]"
        continue
        ;;
      '['*)
        name=${line#\[}
        name=${name%%]*}
        name=${name//[[:space:]]/}
        current=$name
        continue
        ;;
    esac
    case $line in
      *=*) ;;
      *) continue ;;
    esac
    name=${line%%=*}
    name=${name//[[:space:]]/}
    if [ "$current" = "$table" ] && [ "$name" = "$key" ]; then
      :
    elif [ -z "$current" ] && [ "$name" = "$table.$key" ]; then
      :
    else
      continue
    fi
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    printf '%s\n' "$value"
    return 0
  done <"$config"
  return 1
}

# toml_string RAW: the content of a one-line basic or literal string
# (escape sequences are not interpreted); returns 1 for anything else.
toml_string() {
  local raw=$1 body
  case $raw in
    '"""'* | "'''"*) return 1 ;;
    '"'*)
      body=${raw#\"}
      case $body in
        *'"'*) body=${body%%\"*} ;;
        *) return 1 ;;
      esac
      ;;
    "'"*)
      body=${raw#\'}
      case $body in
        *"'"*) body=${body%%\'*} ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$body"
}

# toml_true RAW: true when RAW is the boolean true (optionally commented).
toml_true() {
  local rest=${1#true}
  [ "$rest" != "$1" ] || return 1
  rest=${rest#"${rest%%[![:space:]]*}"}
  case $rest in
    '' | '#'*) return 0 ;;
    *) return 1 ;;
  esac
}

# expand_home PATH: ~ and ~/... with the runtime HOME.
expand_home() {
  case $1 in
    '~') printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#[~]/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# expand_path VALUE: a leading ${NAME:-DEFAULT} (NAME when set and non-empty,
# else DEFAULT), then a leading ~, exactly as the CLI expands state.root.
expand_path() {
  # Bracket expressions keep the literal $, { and } portable across the GNU
  # and BSD regex engines.
  local value=$1 name default rest re='^[$][{]([A-Za-z_][A-Za-z0-9_]*):-([^}]*)[}](.*)$'
  if [[ $value =~ $re ]]; then
    name=${BASH_REMATCH[1]}
    default=${BASH_REMATCH[2]}
    rest=${BASH_REMATCH[3]}
    value=${!name:-}
    [ -n "$value" ] || value=$default
    value=$value$rest
  fi
  expand_home "$value"
}

resolve_state_root() {
  local raw value
  if [ -n "${DOTSTEWARD_STATE_ROOT:-}" ]; then
    printf '%s\n' "$DOTSTEWARD_STATE_ROOT"
    return 0
  fi
  if [ -n "${DOTFILES_STATE_ROOT:-}" ] && raw=$(toml_value compat legacy_env) && toml_true "$raw"; then
    printf '%s\n' "$DOTFILES_STATE_ROOT"
    return 0
  fi
  if raw=$(toml_value state root) && value=$(toml_string "$raw") && [ -n "$value" ]; then
    expand_path "$value"
    return 0
  fi
  # shellcheck disable=SC2016 # the schema default, spelled out literally
  expand_path '${XDG_STATE_HOME:-~/.local/state}/dotsteward'
}

state=$(resolve_state_root)
case $state in
  /*) ;;
  *) die "the state root must be an absolute path: $state" ;;
esac
cache=$state/cli

# --- cache key -------------------------------------------------------------

lock=$root/flake.lock
[ -f "$lock" ] || die "flake.lock not found in $root; the launcher needs the instance lock file"
if command -v sha256sum >/dev/null 2>&1; then
  key=$(sha256sum <"$lock")
else
  key=$(shasum -a 256 <"$lock")
fi
key=${key%%[[:space:]]*}
case $key in
  *[!0-9a-f]* | '') die "cannot compute the sha256 of $lock" ;;
esac
[ ${#key} -eq 64 ] || die "cannot compute the sha256 of $lock"

# Step 2: a cached CLI for this lock.
if [ -x "$cache/$key/bin/dotsteward" ]; then
  exec "$cache/$key/bin/dotsteward" "$@"
fi

# --- build -----------------------------------------------------------------

# Step 4 first: Nix must be reachable, from PATH or the daemon profile (as
# a fresh login shell would see it).
if ! command -v nix >/dev/null 2>&1; then
  daemon_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  if [ -r "$daemon_profile" ]; then
    set +u
    # shellcheck source=/dev/null
    . "$daemon_profile" || true
    set -u
  fi
  if ! command -v nix >/dev/null 2>&1 && [ -x "$HOME/.nix-profile/bin/nix" ]; then
    PATH=$HOME/.nix-profile/bin:$PATH
    export PATH
  fi
fi
command -v nix >/dev/null 2>&1 || die "Nix is required; run ./bootstrap.sh first"

# url_path PATH: PATH with every byte outside [A-Za-z0-9/._~-]
# percent-encoded, for a git+file URL.
url_path() {
  local path=$1 out="" char i=0
  local LC_ALL=C
  while [ "$i" -lt "${#path}" ]; do
    char=${path:i:1}
    case $char in
      [A-Za-z0-9/._~-]) out=$out$char ;;
      *) out=$out$(printf '%%%02X' "'$char") ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

installable="git+file://$(url_path "$root")#dotsteward"
printf '[dotsteward] building the CLI pinned by flake.lock (once per lock change)\n' >&2
status=0
out=$(nix --extra-experimental-features 'nix-command flakes' --no-warn-dirty build \
  --no-link --no-update-lock-file --print-out-paths "$installable") || status=$?
if [ "$status" -ne 0 ]; then
  printf '[dotsteward] ERROR: building %s failed (exit %s)\n' "$installable" "$status" >&2
  exit "$status"
fi
case $out in
  /*) ;;
  *) die "nix build printed no store path for $installable" ;;
esac
case $out in
  *"
"*) die "nix build printed more than one store path for $installable" ;;
esac
[ -x "$out/bin/dotsteward" ] || die "the build of $installable has no executable bin/dotsteward: $out"

# Store the result as a GC root, privately.
if [ ! -d "$cache" ]; then
  (umask 077 && mkdir -p -- "$cache") || die "cannot create $cache"
fi
nix-store --add-root "$cache/$key" --realise "$out" >/dev/null ||
  die "cannot register $cache/$key as a garbage collector root"

# Keep the 5 newest keys (by symlink mtime); only 64-hex names are keys.
kept=0
for entry in $(cd -- "$cache" && ls -1dt -- * 2>/dev/null || true); do
  case $entry in
    *[!0-9a-f]*) continue ;;
  esac
  [ ${#entry} -eq 64 ] && [ -L "$cache/$entry" ] || continue
  kept=$((kept + 1))
  if [ "$kept" -gt 5 ] && [ "$entry" != "$key" ]; then
    rm -f -- "$cache/$entry"
  fi
done

exec "$out/bin/dotsteward" "$@"
