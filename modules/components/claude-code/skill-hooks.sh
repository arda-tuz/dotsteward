#!/usr/bin/env bash
# The skill tracking hook of the claude-code catalog component (agentsPost). It runs
# with the hook environment of `dotsteward agents install|check` and asks the CLI
# of the same framework source to put the hooks of skill tracking into the
# configuration of the agent (install; it takes them out when [skills] tracking
# is off) or to report on them (check, which never fails: a hook that waits for
# trust or was removed for a while is a note).
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the claude-code skill-hooks hook runs from dotsteward agents (DOTSTEWARD_INSTANCE is not set)\n' >&2
  exit 1
}

framework=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
action=install
[[ ${DOTSTEWARD_CHECK_ONLY:-0} != 1 ]] || action=check
exec "$framework/cli/dotsteward" --instance "$DOTSTEWARD_INSTANCE" skills hooks "$action" --agent claude
