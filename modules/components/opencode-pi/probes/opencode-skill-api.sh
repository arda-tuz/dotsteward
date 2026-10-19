#!/usr/bin/env bash
# The opencode-skill-api agents check of the opencode-pi component: OpenCode
# discovers every expected skill (probes/common.sh) in the canonical root
# ~/.agents/skills or, for a skill scoped to OpenCode, in the scoped skill
# store through ~/.config/opencode/skills. A temporary `opencode serve --pure` on a free loopback port
# answers GET /skill; the listing is read from that API rather than from
# `opencode debug skill`, whose output is truncated at 64 KiB. The server is
# stopped before the check ends (opencode-skill-api.py).
set -Eeuo pipefail

# shellcheck source=modules/components/opencode-pi/probes/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

require_command opencode
require_command python3
probe=$(dirname -- "${BASH_SOURCE[0]}")/opencode-skill-api.py
actual=$(python3 -I "$probe" "$HOME" "$(opencode_pi_scoped_store)") ||
  die "OpenCode skill catalog could not be verified (see above)"
opencode_pi_compare opencode OpenCode "$actual"
