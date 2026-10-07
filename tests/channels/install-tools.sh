#!/usr/bin/env bash
# Installs the Claude Code and Codex command line tools that the channel test
# (tests/channels/local-install.sh) drives, on a clean Linux x86_64 runner:
# the official release binaries at the versions the framework pins in the
# component seeds (modules/components/claude-code/seed.json, linux-x64, and
# modules/components/codex/seed.json, linux), downloaded from the URLs there
# and checked against the pinned size and SHA-256 before anything is kept.
#
# Usage: tests/channels/install-tools.sh DIR
#
#   DIR  directory that receives the executables claude and codex (created
#        when missing); put it on PATH afterwards
#
# Needs curl, jq, tar and sha256sum. Exit 0 when both tools are installed and
# report their pinned versions, 1 otherwise.
set -Eeuo pipefail

die() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::error title=channels::%s\n' "$*"
  fi
  printf '[dotsteward] ERROR: install-tools: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] install-tools: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac
(($# == 1)) && [[ -n $1 ]] || die "usage: install-tools.sh DIR"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die "runs only on Linux x86_64"
for tool in curl jq tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required on PATH"
done

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p -- "$1"
bin=$(cd -P -- "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# pin COMPONENT PLATFORM FIELD: one field of the component's seed pin.
pin() {
  local value
  value=$(jq -er --arg c "$1" --arg p "$2" --arg f "$3" '.versions_lock.agent_tools[$c][$p][$f]' \
    "$root/modules/components/$1/seed.json") || die "the seed of $1 has no $2 $3"
  printf '%s' "$value"
}

# fetch COMPONENT PLATFORM FILE: downloads the pinned asset to FILE and checks
# its size and SHA-256.
fetch() {
  local url size sha actual
  url=$(pin "$1" "$2" url)
  size=$(pin "$1" "$2" size)
  sha=$(pin "$1" "$2" sha256)
  [[ $url == https://* ]] || die "the $1 pin is not an https URL: $url"
  log "downloading $url"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$3" -- "$url" || die "downloading $url failed"
  actual=$(stat -c %s -- "$3")
  [[ $actual == "$size" ]] || die "$url has $actual bytes, the pin says $size"
  actual=$(sha256sum -- "$3" | cut -d' ' -f1)
  [[ $actual == "$sha" ]] || die "$url has SHA-256 $actual, the pin says $sha"
}

# Claude Code: a single executable.
fetch claude-code linux-x64 "$work/claude"
install -m 0755 -- "$work/claude" "$bin/claude"

# Codex: an archive with one executable named after the target triple.
fetch codex linux "$work/codex.tar.gz"
mkdir "$work/codex"
tar -xzf "$work/codex.tar.gz" -C "$work/codex"
mapfile -t found < <(find "$work/codex" -type f -name 'codex*' ! -name '*.*')
((${#found[@]} == 1)) || die "the codex archive holds ${#found[@]} executables named codex*, expected one"
install -m 0755 -- "${found[0]}" "$bin/codex"

# Both report the pinned versions.
check_version() {
  local want got
  want=$(pin "$1" "$2" version)
  got=$("$bin/$3" --version 2>&1) || die "$3 --version failed: $got"
  [[ $got == *"$want"* ]] || die "$3 reports '$got', the pin is $want"
  log "$3 $want installed in $bin"
}
check_version claude-code linux-x64 claude
check_version codex linux codex
