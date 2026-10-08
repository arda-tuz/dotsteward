#!/usr/bin/env bash
# The opencode-version agents check of the opencode-pi component:
# `opencode --version` must print a version (X.Y.Z). It holds for
# every OpenCode method; the official-binary method additionally compares
# the version with the release pin before this check runs.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} ]] || {
  printf '[dotsteward] ERROR: the opencode-pi agents checks run from dotsteward agents (DOTSTEWARD_LIB is not set)\n' >&2
  exit 1
}
# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"

require_command opencode
output=$(timeout 60 opencode --version 2>/dev/null </dev/null) || true
version=$(grep -Eo '[0-9]+([.][0-9]+){2}' <<<"$output" | head -n 1) || true
[[ -n $version ]] || die "OpenCode does not run: opencode --version printed no version"
log "opencode-pi: OpenCode $version runs"
