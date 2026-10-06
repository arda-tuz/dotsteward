# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the probe registry tests (tests/probes). Not a test file.
#
# Sourcing this file creates the synthetic instance DS_TEST_ROOT/instance
# (tests/probes/fixtures: workstation.toml, versions.lock.json and the skills
# lock mirror agent/skills.lock.json) and an empty probe PATH prefix
# DS_TEST_ROOT/prefix.
#
#   probes_instance           the instance directory
#   probes_prefix             the empty PATH prefix directory
#   probe COMPONENT COMMAND KIND [FIELD JSON]...
#                             one manifest probe entry (compact JSON) with
#                             the contract defaults (argv ["--version"], env
#                             {}, extract first-line, expected null, needles
#                             [], profiles null), FIELD set to JSON
#   component NAME [FIELD JSON]...
#                             one manifest component entry (profiles null,
#                             platforms linux and darwin)
#   write_manifest FILE PROBE_JSON...
#                             a linux manifest with the probes; its
#                             components are PROBES_COMPONENTS (JSON list,
#                             default: example-term, example-app,
#                             claude-code, opencode-pi in this order)
#   run_probes ARG...         dotsteward --instance <instance> probes ARG...
#                             through the dispatcher, standard input empty
#   run_manifest FILE [ARG...]
#                             run_probes --manifest FILE --path-prefix
#                             <prefix> ARG...
#   in_probes_shell SCRIPT [ARG...]
#                             runs SCRIPT in a fresh bash that sourced
#                             cli/lib/lib.sh, config.sh and probes.sh and
#                             loaded the instance configuration

probes_fixtures=$DS_REPO_ROOT/tests/probes/fixtures
probes_instance=$DS_TEST_ROOT/instance
probes_prefix=$DS_TEST_ROOT/prefix

mkdir -p "$probes_instance/agent" "$probes_prefix"
cp -- "$probes_fixtures/workstation.toml" "$probes_instance/workstation.toml"
cp -- "$probes_fixtures/versions.lock.json" "$probes_instance/versions.lock.json"
cp -- "$probes_fixtures/skills.lock.json" "$probes_instance/agent/skills.lock.json"

PROBES_COMPONENTS=$(jq -cn '[
  {name: "example-term", profiles: null, platforms: ["linux", "darwin"]},
  {name: "example-app", profiles: null, platforms: ["linux", "darwin"]},
  {name: "claude-code", profiles: null, platforms: ["linux", "darwin"]},
  {name: "opencode-pi", profiles: null, platforms: ["linux", "darwin"]}
]')

_set_fields() {
  local json=$1
  shift
  while (($#)); do
    (($# >= 2)) || ds_fail "field $1 has no value"
    json=$(jq -c --arg field "$1" --argjson value "$2" '.[$field] = $value' <<<"$json")
    shift 2
  done
  printf '%s\n' "$json"
}

probe() {
  local json
  json=$(jq -cn --arg component "$1" --arg command "$2" --arg kind "$3" '{
    component: $component, command: $command, kind: $kind, argv: ["--version"],
    env: {}, extract: "first-line", expected: null, needles: [], profiles: null
  }')
  shift 3
  _set_fields "$json" "$@"
}

component() {
  local json
  json=$(jq -cn --arg name "$1" '{name: $name, profiles: null, platforms: ["linux", "darwin"]}')
  shift
  _set_fields "$json" "$@"
}

write_manifest() {
  local file=$1
  shift
  printf '%s\n' "$@" | jq -s --argjson components "$PROBES_COMPONENTS" '{
    schema_version: 1, system: "x86_64-linux", platform: "linux",
    components: $components, probes: .
  }' >"$file"
}

run_probes() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$probes_instance" probes "$@" </dev/null
}

run_manifest() {
  local file=$1
  shift
  run_probes --manifest "$file" --path-prefix "$probes_prefix" "$@"
}

in_probes_shell() {
  local script=$1
  shift
  bash --noprofile --norc -c '
    source "$DS_REPO_ROOT/cli/lib/lib.sh"
    source "$DS_REPO_ROOT/cli/lib/config.sh"
    source "$DS_REPO_ROOT/cli/lib/probes.sh"
    config_load "$0"
    script=$1
    shift
    eval "$script"
  ' "$probes_instance" "$script" "$@" </dev/null
}
