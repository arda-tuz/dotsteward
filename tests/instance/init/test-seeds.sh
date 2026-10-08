# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# Init merges the chosen components' seeds into the template
# locks: versions_lock into versions.lock.json and skills_lock into
# agent/skills.lock.json, deep (objects merge, equal leaves are accepted, a
# leaf two sources set differently is refused), in catalog order, written as
# the pins engine writes locks, with generated_at bumped only when the
# content changed. Invalid seeds are refused before any write.
#
# What init composed is read from the copy fake-nix.sh takes at
# `nix flake lock`; the evaluation after it fails on purpose, so these runs
# stop there and leave nothing behind.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
seeds=$DS_REPO_ROOT/modules/components

# composed CLI ARG...: runs init with ARG (stopped after the lock) and
# prints the staged copy.
composed() {
  local cli=$1 count
  shift
  count=$(init_staged_count)
  assert_exit 1 env DS_INIT_NIX_FAIL='eval *' "$cli" init --dir "$DS_TEST_ROOT/instances/station" \
    --remote "$init_remote" "$@"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: dotsteward sync --nix failed (exit 1); $DS_TEST_ROOT/instances/station was left as it was"
  assert_eq "$((count + 1))" "$(init_staged_count)" "one instance was staged"
  [[ ! -e $DS_TEST_ROOT/instances/station ]] || ds_fail "a failed init created its directory"
  init_staged
}

mkdir -p "$DS_TEST_ROOT/instances"
iso_utc='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'

# --- the real catalog seeds ------------------------------------------------------------

all=$(
  IFS=,
  echo "${init_catalog[*]}"
)
staged=$(composed "$DS_CLI" --components "$all" --allow-unfree)
catalog_seeds=()
for name in "${init_catalog[@]}"; do
  catalog_seeds+=("$seeds/$name/seed.json")
done
for pair in versions_lock:versions.lock.json skills_lock:agent/skills.lock.json; do
  field=${pair%%:*}
  lock=${pair#*:}
  # Exactly the jq deep merge, in catalog order (jq prints keys in insertion
  # order), and written as the pins engine writes it.
  assert_eq "$(seed_merge "$field" "$tpl/$lock" "${catalog_seeds[@]}")" \
    "$(jq 'del(.generated_at)' "$staged/$lock")" "$lock: the template with the seeds merged"
  assert_eq "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, ensure_ascii=False))' \
    "$staged/$lock")" "$(<"$staged/$lock")" "$lock serialization"
  # Every scalar of every seed is in the lock unchanged.
  for seed in "${catalog_seeds[@]}"; do
    jq -e --slurpfile seed "$seed" --arg field "$field" '. as $lock | ($seed[0][$field] // {})
      | [paths(scalars)] | all(. as $path | ($lock | getpath($path)) == ($seed[0][$field] | getpath($path)))' \
      "$staged/$lock" >/dev/null || ds_fail "$lock lacks a value of $seed"
  done
done
# Both locks changed, so both generated_at moved to the time of init, each
# in its file's format.
assert_jq "$staged/versions.lock.json" '.generated_at | test($re + "\\+00:00$")' --arg re "$iso_utc"
assert_jq "$staged/agent/skills.lock.json" '.generated_at | test($re + "Z$")' --arg re "$iso_utc"
assert_jq "$staged/versions.lock.json" '.generated_at != $template' \
  --arg template "$(jq -r .generated_at "$tpl/versions.lock.json")"
assert_eq '["schema_version","generated_at","policy","nix","flake_inputs","nix_packages","agent_tools","desktop_packages"]' \
  "$(jq -c keys_unsorted "$staged/versions.lock.json")" "versions.lock.json sections in order"
assert_eq '["tomlkit","starship","zsh","herdr","pi"]' "$(jq -c '.nix_packages | keys_unsorted' "$staged/versions.lock.json")" \
  "the template's package first, then the seeds' in catalog order"
assert_jq "$staged/agent/skills.lock.json" '.release_tools == { opencode: {} } and .nix_tools == {}'

# A component without lock fragments for the skills lock leaves it as the
# template has it, generated_at included.
staged=$(composed "$DS_CLI" --components shell)
cmp -s "$tpl/agent/skills.lock.json" "$staged/agent/skills.lock.json" ||
  ds_fail "the skills lock changed although no seed adds to it"
assert_jq "$staged/versions.lock.json" '.nix_packages | keys_unsorted == ["tomlkit", "starship", "zsh"]'

# --- the merge golden (synthetic seeds) --------------------------------------------------

fw=$(framework_copy)
cp "$init_fixtures/seed-merge/shell.json" "$fw/modules/components/shell/seed.json"
cp "$init_fixtures/seed-merge/codex.json" "$fw/modules/components/codex/seed.json"
# The order of --components does not matter: seeds merge in catalog order.
staged=$(composed "$fw/cli/dotsteward" --components codex,shell)
assert_eq "$(jq . "$init_fixtures/seed-merge/versions.golden.json")" \
  "$(jq 'del(.schema_version, .generated_at, .policy, .nix, .flake_inputs, .nix_packages.tomlkit)' "$staged/versions.lock.json")" \
  "versions.lock.json golden"
assert_eq "$(jq . "$init_fixtures/seed-merge/skills.golden.json")" \
  "$(jq 'del(.schema_version, .generated_at, .expected_skill_count, .layout, .skills)' "$staged/agent/skills.lock.json")" \
  "skills.lock.json golden"
# The template's own sections stay as they are.
for lock in versions.lock.json agent/skills.lock.json; do
  assert_eq "$(jq -c 'del(.generated_at, .nix_packages, .agent_tools, .desktop_packages, .nix_tools, .release_tools)' "$tpl/$lock")" \
    "$(jq -c 'del(.generated_at, .nix_packages, .agent_tools, .desktop_packages, .nix_tools, .release_tools)' "$staged/$lock")" \
    "$lock: the template sections"
done
assert_jq "$staged/versions.lock.json" '.nix_packages.tomlkit == $template' \
  --argjson template "$(jq -c .nix_packages.tomlkit "$tpl/versions.lock.json")"

# --- conflicts ------------------------------------------------------------------------------

# conflict JQ_FILTER SEED NEEDLE: the codex seed of a fresh framework copy
# changed by JQ_FILTER (after the shell seed of the golden) is refused with
# NEEDLE before any write or Nix call.
conflict() {
  local filter=$1 needle=$2 copy
  copy=$(framework_copy)
  cp "$init_fixtures/seed-merge/shell.json" "$copy/modules/components/shell/seed.json"
  jq "$filter" "$init_fixtures/seed-merge/codex.json" >"$copy/modules/components/codex/seed.json"
  : >"$DS_CALL_LOG"
  assert_exit 1 "$copy/cli/dotsteward" init --dir "$DS_TEST_ROOT/instances/station" --remote "$init_remote" \
    --components shell,codex
  assert_contains "$DS_STDERR" "$needle"
  assert_call_count 0 nix
  [[ ! -e $DS_TEST_ROOT/instances/station ]] || ds_fail "a refused init created its directory"
  assert_eq "" "$(init_temp_dirs)" "no temporary directory is left"
}

conflict '.versions_lock.agent_tools.shared.version = "1.0.1"' \
  '[dotsteward] ERROR: the seeds conflict in versions.lock.json at agent_tools.shared.version: the seed of shell sets "1.0.0", the seed of codex sets "1.0.1"'
conflict '.versions_lock.agent_tools.shared.platforms = ["linux"]' \
  'the seeds conflict in versions.lock.json at agent_tools.shared.platforms: the seed of shell sets ["linux", "darwin"], the seed of codex sets ["linux"]'
conflict '.versions_lock.agent_tools.shared = "1.0.0"' \
  'the seeds conflict in versions.lock.json at agent_tools.shared: the seed of shell sets {"version": "1.0.0", "platforms": ["linux", "darwin"]}, the seed of codex sets "1.0.0"'
conflict '.versions_lock.nix_packages.tomlkit = { expected: "locked nixpkgs package", resolved: "0.0.1" }' \
  'the seeds conflict in versions.lock.json at nix_packages.tomlkit.resolved: the template sets'
conflict '.versions_lock.agent_tools.shared.version = 1' \
  'the seeds conflict in versions.lock.json at agent_tools.shared.version: the seed of shell sets "1.0.0", the seed of codex sets 1'
conflict '.versions_lock.policy = { native_application_updates: false }' \
  'the seeds conflict in versions.lock.json at policy.native_application_updates: the template sets true, the seed of codex sets false'
conflict '.skills_lock.layout = { canonical_user_directory: "~/.skills" }' \
  'the seeds conflict in agent/skills.lock.json at layout.canonical_user_directory: the template sets "~/.agents/skills", the seed of codex sets "~/.skills"'
# Equal is equal in type too: false is not 0.
conflict '.versions_lock.policy = { persistent_agentic_updates: 0 }' \
  'the seeds conflict in versions.lock.json at policy.persistent_agentic_updates: the template sets false, the seed of codex sets 0'

# --- invalid seeds ----------------------------------------------------------------------------

# invalid_seed NAME JQ_FILTER|- NEEDLE: the seed of NAME in a fresh
# framework copy changed by JQ_FILTER ("-": removed) is refused.
invalid_seed() {
  local name=$1 filter=$2 needle=$3 copy seed
  copy=$(framework_copy)
  seed=$copy/modules/components/$name/seed.json
  if [[ $filter == - ]]; then
    rm "$seed"
  else
    jq "$filter" "$DS_REPO_ROOT/modules/components/$name/seed.json" >"$seed.tmp"
    mv "$seed.tmp" "$seed"
  fi
  : >"$DS_CALL_LOG"
  assert_exit 1 "$copy/cli/dotsteward" init --dir "$DS_TEST_ROOT/instances/station" --remote "$init_remote" \
    --components "$name"
  assert_contains "$DS_STDERR" "$needle"
  assert_call_count 0 nix
  [[ ! -e $DS_TEST_ROOT/instances/station ]] || ds_fail "a refused init created its directory"
}

invalid_seed codex - "[dotsteward] ERROR: component codex has no seed (modules/components/codex/seed.json)"
invalid_seed codex 'del(.versions_lock)' "invalid seed modules/components/codex/seed.json: missing required key versions_lock"
invalid_seed codex '.component = "herdr"' \
  "invalid seed modules/components/codex/seed.json: component 'herdr' does not match its directory codex"
invalid_seed codex '.skills_lock = { nix_tools: "x" }' "invalid seed modules/components/codex/seed.json: skills_lock.nix_tools"
invalid_seed herdr 'del(.versions_lock.flake_inputs)' \
  "invalid seed modules/components/herdr/seed.json: flake input herdr has no versions_lock.flake_inputs entry"
invalid_seed herdr '.flake_inputs = { nixpkgs: .flake_inputs.herdr } | .versions_lock.flake_inputs = { nixpkgs: .versions_lock.flake_inputs.herdr }' \
  "invalid seed modules/components/herdr/seed.json: the flake input nixpkgs belongs to the instance"
