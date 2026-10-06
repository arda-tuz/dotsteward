# shellcheck shell=bash
# Shared setup of the opencode-pi agents checks (not a hook; sourced by
# opencode-skill-api.sh and pi-rpc.sh). The hooks run with the hook
# environment of `dotsteward agents install|check` (SPEC 8.4).
#
#   opencode_pi_expected_skills
#       prints the sorted JSON array of the skill names every agent must
#       discover in ~/.agents/skills: the entries of the instance skills lock
#       and the framework skills of the instance manifest mirror
#   opencode_pi_compare AGENT ACTUAL_JSON
#       fails naming the expected skills missing from ACTUAL_JSON (a JSON
#       array of names), else logs that AGENT sees every expected skill

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
  local lock instance framework
  lock=$(config_instance_path "${DS_SKILLS_LOCK:-agent/skills.lock.json}") || exit 1
  instance=$(jq -ce '[.skills[].name]' "$lock" 2>/dev/null) ||
    die "cannot read the skill names of the skills lock $lock"
  methods_manifest_load ""
  framework=$(jq -c '[(.skills.framework // [])[]]' <<<"$DS_MANIFEST_JSON")
  jq -cn --argjson a "$instance" --argjson b "$framework" '$a + $b | unique'
}

opencode_pi_compare() {
  local agent=$1 actual=$2 expected missing
  expected=$(opencode_pi_expected_skills)
  missing=$(jq -rn --argjson expected "$expected" --argjson actual "$actual" \
    '$expected - $actual | join(", ")')
  [[ -z $missing ]] || die "$agent does not see the skills: $missing"
  log "opencode-pi: $agent sees every expected skill ($(jq -r length <<<"$expected"))"
}
