#!/usr/bin/env bash
# E2E hook of the claude-code component (checks.e2e claude-login-zsh, phase
# main), declared with the shell component when the instance sets a launch
# environment or plugin MCP servers ([components.claude-code] options of
# workstation.toml). It runs with the hook environment and checks, in one
# interactive login zsh started from the user's PATH (user_login_zsh) with
# stdin closed, the shell a terminal opens:
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
# The login shell stops at the first problem, so nothing after it runs, and
# the first problem ends the hook with exit status 1.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the claude-code E2E hook runs from dotsteward e2e (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"

# DOTSTEWARD_LIB is the library of the CLI that runs the hook, which can be
# older than the hook (docs/component-contract.md). A lib.sh that predates
# user_login_zsh gets the helper of this release here.
if ! declare -F user_login_zsh >/dev/null; then
  user_login_zsh() {
    local script=$1 marker output status=0
    shift
    marker=dotsteward-login-zsh-$$-$RANDOM$RANDOM
    output=$(user_run zsh -l -i -c "print -r -- $marker; $script" zsh "$@" </dev/null) || status=$?
    if [[ $output == *"$marker"* ]]; then
      output=${output#*"$marker"}
      output=${output#$'\n'}
      [[ -z $output ]] || printf '%s\n' "$output"
    fi
    return "$status"
  }
fi

config_load "$DOTSTEWARD_INSTANCE"

component=${DOTSTEWARD_COMPONENT:-claude-code}

require_command zsh
require_command jq

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

# The checks, in order, as one script for one login zsh. It answers one
# line per check that did not pass and stops there (exported NAME,
# not-wrapped, no-value INDEX), else a status line per MCP server (status
# INDEX TEXT) and done.
script=''
for name in "${names[@]}"; do
  script+="[[ -z \${$name:-} ]] || { print -r -- 'exported $name'; exit 0; }"$'\n'
done
if ((${#names[@]})); then
  script+="[[ \$(whence -w claude) == 'claude: function' ]] || { print -r -- not-wrapped; exit 0; }"$'\n'
fi
for index in "${!entries[@]}"; do
  mapfile -t argv < <(jq -r '.command[]' <<<"${entries[index]}")
  quoted=$(printf '%q ' "${argv[@]}")
  script+="[[ -n \"\$(${quoted}</dev/null 2>/dev/null)\" ]] || { print -r -- 'no-value $index'; exit 0; }"$'\n'
done
for index in "${!servers[@]}"; do
  get="claude mcp get $(printf '%q' "${servers[index]}") </dev/null 2>&1 | sed -n 's/^ *Status: *//p' | tail -n 1"
  script+="print -r -- \"status $index \$($get)\""$'\n'
done
script+='print -r -- done'
answers=$(user_login_zsh "$script" 2>/dev/null) || true

problem=''
done_seen=0
declare -A statuses=()
while IFS= read -r line; do
  case $line in
    'exported '* | not-wrapped | 'no-value '*) problem=$line ;;
    'status '*)
      line=${line#status }
      statuses[${line%% *}]=${line#* }
      ;;
    done) done_seen=1 ;;
  esac
done <<<"$answers"

case $problem in
  'exported '*)
    die "a login zsh exports ${problem#exported }; only the claude function of the claude-code component may pass it to claude"
    ;;
  not-wrapped)
    die "a login zsh does not wrap claude in the launch environment function of the claude-code component"
    ;;
esac
for name in "${names[@]}"; do
  log "claude-code: a login zsh passes $name to claude only"
done

if [[ $problem == 'no-value '* ]]; then
  index=${problem#no-value }
  name=$(jq -r '.name' <<<"${entries[index]}")
  mapfile -t argv < <(jq -r '.command[]' <<<"${entries[index]}")
  log "claude-code: ${argv[*]} printed no value for $name in a login zsh; the MCP servers are checked once it does"
  exit 0
fi
((done_seen)) || die "claude-code: the login zsh did not finish its checks (it failed to start or ended early)"

for index in "${!servers[@]}"; do
  status=${statuses[$index]:-}
  [[ $status == *Connected* ]] ||
    die "Claude Code does not connect to ${servers[index]} in a login zsh (status: ${status:-unknown})"
  log "claude-code: Claude Code connects to ${servers[index]}"
done
