#!/usr/bin/env bash
# The opencode-skill-api agents check of the opencode-pi component: OpenCode
# lists every expected skill (probes/common.sh) by name. A temporary
# `opencode serve --pure` on a free loopback port answers GET /skill; the
# listing is read from that API rather than from `opencode debug skill`,
# whose output is truncated at 64 KiB, and the server is stopped before the
# check ends (opencode-skill-api.py). OpenCode reads ~/.agents/skills,
# ~/.claude/skills and ~/.config/opencode/skills (where the skills scoped to
# OpenCode are linked) and lists a name found in several of them once, from
# whichever root it loaded last, so a listed name counts wherever it was
# found, and every other SKILL.md of an expected name in those roots is
# named in a warning, in every run (skill-shadows.py).
set -Eeuo pipefail

# shellcheck source=modules/components/opencode-pi/probes/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

require_command opencode
require_command python3
probe=$(dirname -- "${BASH_SOURCE[0]}")/opencode-skill-api.py
actual=$(python3 -I "$probe") ||
  die "OpenCode skill catalog could not be verified (see above)"
opencode_pi_shadows opencode
opencode_pi_compare opencode OpenCode "$actual"
