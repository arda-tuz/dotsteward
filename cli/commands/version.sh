#!/usr/bin/env bash
# summary: Print the framework version, source revision and narHash
#
# Usage: dotsteward version [--json]
#
# The version comes from the VERSION file. The revision and narHash come from
# the source-info file that the Nix package bakes in; in a git checkout the
# revision is HEAD (with "-dirty" when tracked files changed) and narHash is
# unknown. Unknown values print as "unknown", or as null with --json, which
# prints {version, rev, narHash} as one 2-space pretty JSON object without
# jq (every value is validated first, so none needs escaping).
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

error() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
}

# The command takes --json (once) or --help, nothing else.
json=0
while (($#)); do
  case $1 in
    -h | --help)
      printf 'Usage: dotsteward version [--json]\n'
      exit 0
      ;;
    --json)
      if ((json)); then
        error "--json given twice"
        exit 1
      fi
      json=1
      shift
      ;;
    *)
      error "unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f $root/VERSION ]]; then
  error "missing VERSION file: $root/VERSION"
  exit 1
fi
version_text=$(<"$root/VERSION")
if [[ ! $version_text =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || (($(wc -l <"$root/VERSION") > 1)); then
  error "invalid VERSION file (expected one line X.Y.Z): $root/VERSION"
  exit 1
fi

rev=""
nar_hash=""
if [[ -f $root/source-info ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      rev=*) rev=${line#rev=} ;;
      narHash=*) nar_hash=${line#narHash=} ;;
    esac
  done <"$root/source-info"
  if [[ -n $rev && ! $rev =~ ^[0-9a-f]{7,64}(-dirty)?$ ]] ||
    [[ -n $nar_hash && ! $nar_hash =~ ^[A-Za-z0-9]+-[A-Za-z0-9+/]+=*$ ]]; then
    error "invalid source-info file: $root/source-info"
    exit 1
  fi
elif command -v git >/dev/null 2>&1 &&
  toplevel=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) &&
  [[ $(cd -P -- "$toplevel" && pwd) == "$root" ]]; then
  if rev=$(git -C "$root" rev-parse --verify --quiet HEAD); then
    git -C "$root" diff --quiet HEAD -- 2>/dev/null || rev+=-dirty
  else
    rev=""
  fi
fi

if ((json)); then
  # json_value VALUE: VALUE as a JSON string, or null when empty.
  json_value() {
    if [[ -n $1 ]]; then printf '"%s"' "$1"; else printf null; fi
  }
  printf '{\n  "version": "%s",\n  "rev": %s,\n  "narHash": %s\n}\n' \
    "$version_text" "$(json_value "$rev")" "$(json_value "$nar_hash")"
  exit 0
fi
printf 'dotsteward %s\nrev: %s\nnarHash: %s\n' "$version_text" "${rev:-unknown}" "${nar_hash:-unknown}"
