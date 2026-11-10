#!/usr/bin/env bash
# summary: Validate the candidate tree of a maintenance transaction (the gate)
# Usage: dotsteward [--instance DIR] gate [--scope update|maintain] [--force]
#                   [--expected-base OID] [--framework-override REF]
#
# Proves the tree that `git add -A && git commit` would record in the
# instance clone, without committing, pushing or activating anything. Order:
# the arguments; the clone (top of a git work tree, on instance.branch,
# origin exactly instance.remote); the lock <state>/update/validate.lock (a
# running gate is refused at once); untracked files (refused, Nix does not
# see them); the base OID; in the update scope the allowlist of changed
# paths; the candidate tree id; the writer classes (on a machine that is not
# the producer of the base, no pin of the base moves, and no machine writes
# the host file of another: `writer-class` lines, docs/machines.md); `nix
# --version`; the memo; then five quiet
# steps, each with its output in <state>/update/validate.log:
#   preflight    the binary cache answers (gate.cache_url) and /nix/store
#                has gate.min_free_gib GiB free; never fall back to mirrors
#   static       the static checks that need this machine: dotsteward
#                static --only scripts (the [gate] static scripts with
#                DOTSTEWARD_SANDBOX=0, so their parts outside the sandbox
#                run), with --only privacy first when [privacy] names a
#                denylist (a file outside the instance, which the sandbox
#                never reads); every other static check runs once, in the
#                sandbox, in checks.<system>.instance-contract of the flake
#                check
#   pins         dotsteward pins check --nix
#   flake-check  nix flake check with gate.nix_max_jobs and gate.nix_cores
#                (derived from the memory and CPUs of the machine when
#                workstation.toml sets none; see `dotsteward context --json`)
#   cli-probes   nix build checks.<primary system>.home, then dotsteward
#                probes --generation <built path>
# and records <state>/update/validation.json and the hand-off
# <state>/update/generation.json. Every Nix call keeps the lock file as it
# is (--no-update-lock-file).
#
# Options:
#   --scope S          update (default): every path changed since the base
#                      must match the update allowlist (framework defaults,
#                      the component paths of .dotsteward/manifest.*.json,
#                      gate.update_allowlist) and the settings buffer never
#                      changes; maintain: no path restriction
#   --force            ignore the memo (every other check still runs)
#   --expected-base OID
#                      the base OID; default: base_oid of candidate.json
#                      when it was prepared for this instance, else
#                      `git merge-base HEAD origin/<branch>`, else, in a
#                      clone whose branch was never pushed (no
#                      origin/<branch>, as right after `dotsteward init`),
#                      HEAD, so the first tree is validated before the
#                      first push
#   --framework-override REF
#                      evaluate the instance with its dotsteward input
#                      replaced by the flake reference REF, in memory
#                      (--override-input dotsteward REF
#                      --no-write-lock-file); the steps see
#                      DOTSTEWARD_FRAMEWORK_OVERRIDE=REF. Default: the
#                      DOTSTEWARD_FRAMEWORK_OVERRIDE environment variable
#
# Memo: a passed record answers without running a step when the tree id,
# `nix --version`, the gate version (the framework VERSION), the framework
# override, the sha256 of the configured privacy denylist and the scope all
# equal the record's (txn publish takes a record of its own scope only); the
# root is not part of the key. A memo answer for another base records that
# base, which the writer classes and the update allowlist were checked
# against first; txn publish takes a record of its own base only. A failed
# run keeps the previous record.
#
# validation.json (schema_version "1.1"): result, tree_oid, base_oid, scope,
# nix_version, gate_version, framework_override (or null), denylist_sha256
# (or null), root, validated_at, total_seconds, step_seconds (preflight,
# static, pins, flake-check, cli-probes), log.
#
# generation.json (schema_version "1.0"), the hand-off to `dotsteward
# rebuild`: tree_oid, profile (profiles.check), system (the primary
# system), username and home (the check identity: identity.username and
# identity.home, identity.darwin_home on darwin), generation (the store path
# the cli-probes step built and probed), framework_override (or null), root
# and recorded_at. rebuild activates that generation instead of evaluating
# and building again when the tree of HEAD, its profile and system, $USER,
# $HOME, its framework override and its checkout are the same; a memo
# answer and a failed run keep the previous record.
#
# Output: one "ok" line per step, then one JSON line {result, tree_oid,
# scope, total_seconds, step_seconds}; a memo answer prints {result,
# tree_oid, scope, validated_at, total_seconds, memo: true}. A failed step
# prints its FAILED line and the last 60 log lines on stderr.
#
# Exit status: 0 passed (or answered from the memo), 1 refused or failed.
set -Eeuo pipefail

lib_dir=${DOTSTEWARD_LIB:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)}
framework_root=$(cd -P -- "${DOTSTEWARD_FRAMEWORK_ROOT:-$lib_dir/../..}" && pwd)

# shellcheck source=cli/lib/lib.sh
source "$lib_dir/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$lib_dir/config.sh"
# shellcheck source=cli/lib/txn.sh
source "$lib_dir/txn.sh"
# shellcheck source=cli/lib/python.sh
source "$lib_dir/python.sh"

STEPS=(preflight static pins flake-check cli-probes)

usage() {
  sed -n '3,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

# need_value FLAG ARGC VALUE: fails unless an option that takes a value got one.
need_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "$1 requires a value"
  fi
}

scope=update
force=0
expected_base=""
override_flag=""
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --force)
      force=1
      shift
      ;;
    --scope | --expected-base | --framework-override)
      need_value "$1" "$#" "${2:-}"
      case $1 in
        --scope) scope=$2 ;;
        --expected-base) expected_base=$2 ;;
        --framework-override) override_flag=$2 ;;
      esac
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
txn_valid_scope "$scope"
override=${override_flag:-${DOTSTEWARD_FRAMEWORK_OVERRIDE:-}}

require_command git
require_command jq
# shellcheck disable=SC2119 # config_load takes no argument here
config_load
root=$DS_INSTANCE_ROOT
txn_require_clone

# The lock is held for the life of the process, a memo answer included.
require_command flock
txn_ensure_state_dir
lock_file=$(txn_lock_file)
(umask 077 && : >>"$lock_file") || die "cannot create the lock file: $lock_file"
exec 9>>"$lock_file"
flock -n 9 || die "another gate is running; wait for it to finish"

txn_require_no_untracked
if [[ -z $expected_base && -z $(txn_recorded_base) ]] && txn_unpublished; then
  expected_base=$(txn_head_oid)
  log "origin/$DS_INSTANCE_BRANCH does not exist yet (the instance was never pushed); the base is HEAD $expected_base"
fi
base=$(txn_resolve_base "$expected_base")
if [[ $scope == update ]]; then
  txn_check_allowlist "$base"
fi
tree_oid=$(txn_working_tree_oid)
# Who writes what, in every scope and before the memo, whose key names no machine.
ds_python dotsteward_cli.writers check --instance "$root" --base "$base" --tree "$tree_oid" --scope "$scope" ||
  die "this machine does not write what the tree changes (docs/machines.md, \"Who writes what\")"
nix_version=$(nix_cmd --version)
nix_version=${nix_version%%$'\n'*}
[[ -n $nix_version ]] || die "nix --version printed nothing"

version_file=$framework_root/VERSION
[[ -f $version_file ]] || die "framework VERSION file not found: $version_file"
gate_version=$(<"$version_file")
gate_version=${gate_version//[[:space:]]/}

denylist_sha256=""
if [[ -n $DS_PRIVACY_DENYLIST && -f $DS_PRIVACY_DENYLIST && -r $DS_PRIVACY_DENYLIST ]]; then
  denylist_sha256=$(sha256_file "$DS_PRIVACY_DENYLIST")
fi

validation_file=$(txn_validation_file)
generation_file=$(txn_generation_file)
log_file=$(txn_log_file)

# --- memo -------------------------------------------------------------------------

# The memo key as JSON: absent values are null.
memo_key=$(jq -cn --arg tree "$tree_oid" --arg nix "$nix_version" --arg gate "$gate_version" \
  --arg override "$override" --arg denylist "$denylist_sha256" --arg scope "$scope" '{
    tree_oid: $tree, nix_version: $nix, gate_version: $gate, scope: $scope,
    framework_override: (if $override == "" then null else $override end),
    denylist_sha256: (if $denylist == "" then null else $denylist end)}')

if ((!force)); then
  record=$(txn_json_object "$validation_file")
  if [[ -n $record ]] && jq -e --argjson key "$memo_key" '
    . as $record | .schema_version == "1.1" and .result == "passed"
    and all($key | keys[]; $record[.] == $key[.])' <<<"$record" >/dev/null 2>&1; then
    log "this tree already passed the gate; skipped (use --force to rerun)"
    # The writer classes and the allowlist above held for this base: the record says so.
    if [[ $(jq -r '.base_oid // ""' <<<"$record") != "$base" ]]; then
      jq --arg base "$base" '.base_oid = $base' <<<"$record" | txn_write_private "$validation_file"
    fi
    jq -c '{result, tree_oid, scope, validated_at, total_seconds, memo: true}' <<<"$record"
    exit 0
  fi
fi

# --- steps ------------------------------------------------------------------------

(umask 077 && : >"$log_file") || die "cannot write the log: $log_file"
chmod 0600 -- "$log_file"
# The cli-probes step runs in a subshell; it leaves the built path here.
built_note=$(mktemp "$(txn_state_dir)/.built-generation.XXXXXX") || die "cannot write in $(txn_state_dir)"
trap 'rm -f -- "$built_note"' EXIT

if [[ -n $override ]]; then
  export DOTSTEWARD_FRAMEWORK_OVERRIDE=$override
  override_args=(--override-input dotsteward "$override" --no-write-lock-file)
else
  unset DOTSTEWARD_FRAMEWORK_OVERRIDE
  override_args=()
fi
parallelism=(--max-jobs "$DS_GATE_NIX_MAX_JOBS" --cores "$DS_GATE_NIX_CORES")
dotsteward=$framework_root/cli/dotsteward
probe_attribute="$root#checks.$DS_NIX_PRIMARY_SYSTEM.home"
flake_check_args=(flake check "$root" --no-update-lock-file --keep-going -L "${parallelism[@]}" "${override_args[@]}")

step_preflight() {
  local url=${DS_GATE_CACHE_URL%/} free_kib
  require_command curl
  curl --fail --silent --show-error --location --max-time 10 --output /dev/null "$url/nix-cache-info" ||
    die "Nix binary cache unreachable: $url. Do not use mirrors or extra substituters; rerun when the network is back."
  free_kib=$(df -Pk /nix/store | awk 'NR == 2 { print $4 }')
  [[ $free_kib =~ ^[0-9]+$ ]] || die "cannot read the free space of /nix/store"
  # Whole GiB, so a large threshold cannot overflow.
  if ((free_kib / 1048576 < DS_GATE_MIN_FREE_GIB)); then
    die "free space for /nix/store is below $DS_GATE_MIN_FREE_GIB GiB; free space first"
  fi
  log "binary cache reachable; /nix/store has $((free_kib / 1048576)) GiB free"
}

# The static checks outside the sandbox: instance-contract runs all of them
# in the sandbox, without the denylist and with DOTSTEWARD_SANDBOX=1.
static_args=(static)
[[ -z $DS_PRIVACY_DENYLIST ]] || static_args+=(--only privacy)
static_args+=(--only scripts)

step_static() {
  "$dotsteward" --instance "$root" "${static_args[@]}"
}

step_pins() {
  "$dotsteward" --instance "$root" pins check --nix
}

step_flake_check() {
  nix_cmd "${flake_check_args[@]}"
}

# host_configuration: whether the flake has the configuration of this machine. A framework
# pin older than the CLI has no such output, which is no failure here.
host_configuration() {
  local names
  [[ -n $DS_HOST_BUILD_NAME ]] || return 1
  names=$(nix_cmd eval --json "$root#hostConfigurations" --apply builtins.attrNames --no-update-lock-file \
    "${override_args[@]}" 2>/dev/null) || return 1
  jq -e --arg name "$DS_HOST_BUILD_NAME" 'index($name) != null' <<<"$names" >/dev/null
}

step_cli_probes() {
  local output generation attribute=$probe_attribute host=''
  if host_configuration; then
    host=$DS_HOST_BUILD_NAME
    attribute="$root#hostConfigurations.$host.activationPackage"
  fi
  output=$(nix_cmd build "$attribute" --no-link --no-update-lock-file --print-out-paths \
    "${parallelism[@]}" "${override_args[@]}")
  generation=${output##*$'\n'}
  [[ -n $generation ]] || die "the candidate build printed no output path"
  [[ -d $generation/home-path/bin ]] || die "candidate profile bin directory missing: $generation/home-path/bin"
  "$dotsteward" --instance "$root" probes --generation "$generation"
  printf '%s\n%s\n' "$generation" "$host" >"$built_note"
}

declare -A step_seconds=()

# run_step NAME DESCRIPTION FUNCTION: runs FUNCTION with errexit, its output
# appended to the log; the first failure ends the gate.
run_step() {
  local name=$1 description=$2 function=$3 started status
  printf '\n== %s: %s\n' "$name" "$description" >>"$log_file"
  started=$SECONDS
  # errexit applies inside the subshell only when its status is not tested.
  set +e
  (
    set -e
    "$function"
  ) </dev/null >>"$log_file" 2>&1
  status=$?
  set -e
  step_seconds[$name]=$((SECONDS - started))
  if ((status != 0)); then
    printf '[dotsteward] %-12s FAILED (%ss)\n' "$name" "${step_seconds[$name]}" >&2
    tail -n 60 -- "$log_file" >&2
    die "gate step failed: $name; full log: $log_file"
  fi
  printf '[dotsteward] %-12s ok (%ss)\n' "$name" "${step_seconds[$name]}"
}

# quoted ARG...: the arguments as one shell-quoted line.
quoted() {
  local out
  printf -v out '%q ' "$@"
  printf '%s\n' "${out% }"
}

source_nix_daemon
started=$SECONDS
run_step preflight "curl $DS_GATE_CACHE_URL/nix-cache-info, df /nix/store (at least $DS_GATE_MIN_FREE_GIB GiB free)" \
  step_preflight
run_step static "dotsteward ${static_args[*]}" step_static
run_step pins "dotsteward pins check --nix" step_pins
run_step flake-check "$(quoted nix "${flake_check_args[@]}")" step_flake_check
run_step cli-probes "nix build $probe_attribute, dotsteward probes --generation <built>" step_cli_probes
total_seconds=$((SECONDS - started))

# --- record -----------------------------------------------------------------------

seconds_json=$(for step in "${STEPS[@]}"; do
  printf '%s\t%s\n' "$step" "${step_seconds[$step]}"
done | jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')

jq -n --argjson key "$memo_key" --arg base "$base" --arg scope "$scope" --arg root "$root" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson total "$total_seconds" \
  --argjson steps "$seconds_json" --arg log "$log_file" '{
    schema_version: "1.1",
    result: "passed",
    tree_oid: $key.tree_oid,
    base_oid: $base,
    scope: $scope,
    nix_version: $key.nix_version,
    gate_version: $key.gate_version,
    framework_override: $key.framework_override,
    denylist_sha256: $key.denylist_sha256,
    root: $root,
    validated_at: $at,
    total_seconds: $total,
    step_seconds: $steps,
    log: $log
  }' | txn_write_private "$validation_file"

# The hand-off: the generation of the check profile and identity.
built_generation=''
built_host=''
{
  read -r built_generation || true
  read -r built_host || true
} <"$built_note"
[[ -n $built_generation ]] || die "the cli-probes step recorded no generation"
check_home=$DS_IDENTITY_HOME
[[ $DS_NIX_PRIMARY_SYSTEM != *-darwin ]] || check_home=$DS_IDENTITY_DARWIN_HOME
built_profile=$DS_PROFILES_CHECK
built_tags=$(printf '' | sha256sum | cut -d' ' -f1)
if [[ -n $built_host ]]; then
  built_profile=$DS_HOST_BUILD_PROFILE
  built_tags=$DS_HOST_BUILD_TAGS_SHA256
fi
jq -n --arg tree "$tree_oid" --arg profile "$built_profile" --arg system "$DS_NIX_PRIMARY_SYSTEM" \
  --arg username "$DS_IDENTITY_USERNAME" --arg home "$check_home" --arg generation "$built_generation" \
  --argjson key "$memo_key" --arg root "$root" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg host "$built_host" --arg tags "$built_tags" '{
    schema_version: "1.0", tree_oid: $tree, profile: $profile, system: $system, username: $username,
    home: $home, generation: $generation, framework_override: $key.framework_override, root: $root,
    host: (if $host == "" then null else $host end), tags_sha256: $tags,
    recorded_at: $at}' | txn_write_private "$generation_file"

log "candidate validated; nothing committed or pushed"
jq -c '{result, tree_oid, scope, total_seconds, step_seconds}' "$validation_file"
