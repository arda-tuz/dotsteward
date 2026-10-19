# shellcheck shell=bash
# Shared setup of the opencode-pi agents checks (not a hook; sourced by
# opencode-skill-api.sh and pi-rpc.sh). The hooks run with the hook
# environment of `dotsteward agents install|check`.
#
#   opencode_pi_expected_skills AGENT
#       prints the sorted JSON array of the skill names AGENT (opencode or
#       pi) must discover: the entries of the instance skills lock without
#       agents or with AGENT among them, and the framework skills of the
#       instance manifest mirror
#   opencode_pi_scoped_store
#       prints the scoped skill store,
#       ${XDG_DATA_HOME:-~/.local/share}/dotsteward/scoped-skills
#   opencode_pi_compare AGENT LABEL ACTUAL_JSON
#       fails naming the expected skills of AGENT missing from ACTUAL_JSON
#       (a JSON array of names), else logs that LABEL sees every expected
#       skill

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the opencode-pi agents checks run from dotsteward agents (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

config_load "$DOTSTEWARD_INSTANCE"

opencode_pi_expected_skills() {
  local agent=$1 lock instance framework
  lock=$(config_instance_path "${DS_SKILLS_LOCK:-agent/skills.lock.json}") || exit 1
  instance=$(jq -ce --arg agent "$agent" \
    '[.skills[] | select(.agents == null or (.agents | index($agent)) != null) | .name]' "$lock" 2>/dev/null) ||
    die "cannot read the skill names of the skills lock $lock"
  methods_manifest_load ""
  framework=$(jq -c '[(.skills.framework // [])[]]' <<<"$DS_MANIFEST_JSON")
  jq -cn --argjson a "$instance" --argjson b "$framework" '$a + $b | unique'
}

opencode_pi_scoped_store() {
  local data=${XDG_DATA_HOME:-$HOME/.local/share}
  printf '%s\n' "${data%/}/dotsteward/scoped-skills"
}

opencode_pi_compare() {
  local agent=$1 label=$2 actual=$3 expected missing
  expected=$(opencode_pi_expected_skills "$agent")
  missing=$(jq -rn --argjson expected "$expected" --argjson actual "$actual" \
    '$expected - $actual | join(", ")')
  [[ -z $missing ]] || die "$label does not see the skills: $missing"
  log "opencode-pi: $label sees every expected skill ($(jq -r length <<<"$expected"))"
}
