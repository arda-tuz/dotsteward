#!/usr/bin/env bash
# The pi-rpc agents check of the opencode-pi component: Pi
# discovers every expected skill (probes/common.sh). One offline, isolated
# RPC session answers get_commands: PI_OFFLINE=1, no session, extensions or
# prompt templates, and a fresh temporary PI_CODING_AGENT_DIR, so neither
# the network nor the user's own Pi configuration (~/.pi/agent) takes part;
# the directory is removed afterwards. The skill commands (source "skill",
# named skill:<name>) are compared with the expected skills.
set -Eeuo pipefail

# shellcheck source=modules/components/opencode-pi/probes/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

require_command pi
config_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-pi-config.XXXXXX") ||
  die "cannot create a temporary Pi configuration directory"
responses=$(mktemp "${TMPDIR:-/tmp}/dotsteward-pi-rpc.XXXXXX") || {
  cleanup_temp_dir "$config_dir"
  die "cannot create a temporary file"
}
cleanup() {
  cleanup_temp_dir "$config_dir"
  rm -f -- "$responses"
}
trap cleanup EXIT

status=0
printf '%s\n' '{"type":"get_commands"}' |
  PI_CODING_AGENT_DIR=$config_dir PI_OFFLINE=1 \
    timeout 60 pi --mode rpc --no-session --no-extensions --no-prompt-templates >"$responses" || status=$?
((status == 0)) || die "Pi RPC failed (exit $status)"

actual=$(jq -cRn '[inputs | fromjson? | objects
    | select(.type == "response" and .command == "get_commands" and .success != false)]
  | if length == 0 then error("no response") else . end
  | [.[] | .data.commands[]? | objects | select(.source == "skill") | .name | strings | sub("^skill:"; "")]
  | unique' <"$responses" 2>/dev/null) ||
  die "Pi RPC answered no valid get_commands response"
opencode_pi_compare Pi "$actual"
