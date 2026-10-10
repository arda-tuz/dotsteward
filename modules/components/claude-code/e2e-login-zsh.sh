#!/usr/bin/env bash
# E2E hook of the claude-code component (checks.e2e claude-login-zsh, phase
# main), declared with the shell component when the instance sets a launch
# environment or plugin MCP servers ([components.claude-code] options of
# workstation.toml). It runs with the hook environment and checks, in an
# interactive login zsh started from the user's PATH (user_run) with stdin
# closed, the shell a terminal opens:
#   - no launchEnvironment variable is set: the claude function of the
#     claude-code-launch-environment block is the only way it reaches claude
#     (the hook unsets them first, so the caller's own values do not count);
#   - claude is that function (with a launch environment);
#   - every launch command prints a value; a command without one (for
#     example a credential the user has not created yet) is a hint, and the
#     MCP servers are not checked;
#   - `claude mcp get plugin:NAME:SERVER` reports Connected for every MCP
#     server of the plugins (mcpServers), through the function.
# A launch value never leaves the login shell: the checks test it there.
# The first problem ends the hook with exit status 1.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the claude-code E2E hook runs from dotsteward e2e (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"

config_load "$DOTSTEWARD_INSTANCE"

component=${DOTSTEWARD_COMPONENT:-claude-code}

require_command zsh
require_command jq

# login_zsh SCRIPT: the last line a login zsh prints for SCRIPT (anything a
# startup file prints comes before it).
login_zsh() {
  user_run zsh -l -i -c "$1" </dev/null 2>/dev/null | tail -n 1 || true
}

# shellcheck disable=SC2016 # jq programs: $component is a jq variable
launch=$(config_query -c --arg component "$component" '.components[$component].options.launchEnvironment // [] | .[]')
entries=()
if [[ -n $launch ]]; then
  mapfile -t entries <<<"$launch"
fi
# shellcheck disable=SC2016 # jq programs: $component and $name are jq variables
listed=$(config_query -r --arg component "$component" '.components[$component].options.plugins // []
  | .[] | (.spec | split("@")[0]) as $name | (.mcpServers // [])[] | "plugin:\($name):\(.)"')
servers=()
if [[ -n $listed ]]; then
  mapfile -t servers <<<"$listed"
fi

names=()
for entry in "${entries[@]}"; do
  name=$(jq -r '.name' <<<"$entry")
  [[ $name =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "claude-code: invalid launch environment name: $name"
  names+=("$name")
  unset "$name"
done

for name in "${names[@]}"; do
  [[ $(login_zsh "if [[ -n \${$name:-} ]]; then print set; else print unset; fi") == unset ]] ||
    die "a login zsh exports $name; only the claude function of the claude-code component may pass it to claude"
done

if ((${#names[@]})); then
  [[ $(login_zsh 'whence -w claude') == "claude: function" ]] ||
    die "a login zsh does not wrap claude in the launch environment function of the claude-code component"
  for name in "${names[@]}"; do
    log "claude-code: a login zsh passes $name to claude only"
  done
fi

for entry in "${entries[@]}"; do
  name=$(jq -r '.name' <<<"$entry")
  mapfile -t argv < <(jq -r '.command[]' <<<"$entry")
  quoted=$(printf '%q ' "${argv[@]}")
  if [[ $(login_zsh "if [[ -n \"\$(${quoted}</dev/null 2>/dev/null)\" ]]; then print value; else print none; fi") != value ]]; then
    log "claude-code: ${argv[*]} printed no value for $name in a login zsh; the MCP servers are checked once it does"
    exit 0
  fi
done

for server in "${servers[@]}"; do
  status=$(user_run zsh -l -i -c "claude mcp get $(printf '%q' "$server")" </dev/null 2>&1 |
    sed -n 's/^ *Status: *//p' | tail -n 1) || true
  [[ $status == *Connected* ]] ||
    die "Claude Code does not connect to $server in a login zsh (status: ${status:-unknown})"
  log "claude-code: Claude Code connects to $server"
done
