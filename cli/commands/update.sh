#!/usr/bin/env bash
# summary: Prepare, publish and report a maintenance transaction
# Usage: dotsteward [--instance DIR] update prepare --official-sources-only
#                   [--scope update|maintain]
#        dotsteward [--instance DIR] update publish [--scope update|maintain]
#                   [--expected-base OID]
#        dotsteward [--instance DIR] update status [--json]
#
# The maintenance transaction: prepare records a base, `dotsteward gate`
# proves the candidate tree, publish ships a commit whose tree is the proven
# tree. Nothing here builds, activates or commits anything.
#
# prepare
#   Runs in the instance clone (top of a git work tree, on instance.branch,
#   origin exactly instance.remote). The update scope (default) needs an
#   entirely clean clone; the maintain scope lists the changes instead. It
#   fetches origin/<branch> (60 s), requires HEAD to equal it in both
#   scopes, and records <state>/update/candidate.json (schema_version
#   "1.1": prepared_at, base_oid, root, scope, official_sources_only,
#   persistent_agentic_updates, native_application_updates). Advisory
#   checks become warnings in the output, never refusals: the binary cache
#   (gate.cache_url) does not answer, /nix/store has less than
#   gate.prepare_warn_free_gib GiB free, gh is not logged in or not
#   installed. Output: a "prepared" line, then one JSON line {base_oid,
#   root, scope, dirty, warnings}.
#   --official-sources-only   required: the transaction takes versions
#                             only from official sources
#
# publish
#   In order: the clone guards; a clean tree; the base OID (--expected-base,
#   else base_oid of candidate.json when it was prepared for this instance,
#   else `git merge-base HEAD origin/<branch>`); at least one commit after
#   the base, which must be an ancestor of HEAD; the HEAD tree is the tree
#   of a passed validation.json, made for the same scope and without a
#   framework override; the commit subjects (update scope: the last one is
#   exactly commit.update_subject; maintain scope: every one after the base
#   is a conventional commit); a fresh fetch (60 s) finds origin/<branch>
#   still at the base; HEAD is pushed to <branch> without force (180 s) and
#   the remote branch is verified to be HEAD (60 s). When the fetch finds
#   the remote branch already at HEAD, the commit is already published:
#   nothing is pushed and the exit status is 0. Finally the canonical
#   checkout (canonical_repo of <state>/host-overrides/inventory.json, else
#   instance.checkout) is fast-forwarded when it is a clean clone of
#   instance.remote on <branch> at the base; any other state is a warning,
#   never a failure; a path that is not a git repository, or the publishing
#   clone itself, is skipped.
#   --scope S                 update (default) or maintain
#   --expected-base OID       the base OID
#
# status
#   Prints the state directory and the paths and records of candidate.json,
#   validation.json and validate.log. Reads only; works in any checkout.
#   --json                    one JSON document {schema_version: 1,
#                             instance, paths: {state_dir, candidate,
#                             validation, log}, candidate, validation}; a
#                             record is the file's object, or null when the
#                             file is absent or not a JSON object
#
# Exit status: 0 done (already published included), 1 refused or failed.
set -Eeuo pipefail

lib_dir=${DOTSTEWARD_LIB:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)}

# shellcheck source=cli/lib/lib.sh
source "$lib_dir/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$lib_dir/config.sh"
# shellcheck source=cli/lib/txn.sh
source "$lib_dir/txn.sh"

# The conventional commit types, as `dotsteward context` reports them.
CONVENTIONAL_SUBJECT='^(feat|fix|perf|refactor|docs|chore|test|build|ci|style|revert)(\([a-z0-9._/-]+\))?!?: .+'

usage() {
  sed -n '3,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

# need_value FLAG ARGC VALUE: fails unless an option that takes a value got one.
need_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "$1 requires a value"
  fi
}

# json_lines: standard input as a JSON array of its non-empty lines.
json_lines() {
  jq -Rn '[inputs | select(length > 0)]'
}

# free_gib: the whole GiB free for /nix/store; nothing when unknown.
free_gib() {
  local kib
  kib=$(df -Pk /nix/store 2>/dev/null | awk 'NR == 2 { print $4 }') || kib=""
  [[ $kib =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "$((kib / 1048576))"
}

# fetch_branch: fetches instance.branch of origin into its remote-tracking
# ref, or dies.
fetch_branch() {
  local branch=$DS_INSTANCE_BRANCH
  git_net 60 -C "$DS_INSTANCE_ROOT" fetch --quiet origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch" ||
    die "could not fetch origin/$branch within 60 s"
}

# remote_branch_oid: the fetched origin/<branch>.
remote_branch_oid() {
  git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DS_INSTANCE_BRANCH^{commit}" ||
    die "origin/$DS_INSTANCE_BRANCH is missing after the fetch"
}

# --- prepare ------------------------------------------------------------------------

cmd_prepare() {
  local scope=update official=0 root dirty base url free warn_gib warnings_json
  local -a warnings=()
  while (($#)); do
    case $1 in
      --official-sources-only)
        official=1
        shift
        ;;
      --scope)
        need_value "$1" "$#" "${2:-}"
        scope=$2
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  txn_valid_scope "$scope"
  ((official)) || die "update prepare requires --official-sources-only"

  require_command git
  require_command jq
  # shellcheck disable=SC2119 # config_load takes no argument here
  config_load
  root=$DS_INSTANCE_ROOT
  txn_require_clone

  dirty=$(git -C "$root" status --porcelain) || die "cannot read the status of $root"
  if [[ $scope == update && -n $dirty ]]; then
    die "update prepare requires a clean clone"
  fi
  fetch_branch
  base=$(remote_branch_oid)
  [[ $(git -C "$root" rev-parse HEAD) == "$base" ]] ||
    die "local HEAD differs from origin/$DS_INSTANCE_BRANCH; if behind, run 'git pull --ff-only'; if ahead, review the unpublished commits"

  # Advisory checks: the same conditions are fatal in the gate.
  require_command curl
  url=${DS_GATE_CACHE_URL%/}
  if ! curl --fail --silent --location --max-time 10 --output /dev/null "$url/nix-cache-info" 2>/dev/null; then
    warnings+=("Nix binary cache unreachable: $url")
  fi
  warn_gib=$DS_GATE_PREPARE_WARN_FREE_GIB
  free=$(free_gib)
  if [[ -z $free ]]; then
    warnings+=("cannot read the free space of /nix/store")
  elif ((free < warn_gib)); then
    warnings+=("free space for /nix/store is below $warn_gib GiB")
  fi
  if command -v gh >/dev/null 2>&1; then
    timeout 20 gh auth status </dev/null >/dev/null 2>&1 ||
      warnings+=("gh is not logged in; GitHub queries need 'gh auth login'")
  else
    warnings+=("gh not found")
  fi

  txn_ensure_state_dir
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg base "$base" --arg root "$root" --arg scope "$scope" '{
    schema_version: "1.1",
    prepared_at: $at,
    base_oid: $base,
    root: $root,
    scope: $scope,
    official_sources_only: true,
    persistent_agentic_updates: false,
    native_application_updates: true
  }' | txn_write_private "$(txn_candidate_file)"

  warnings_json='[]'
  if ((${#warnings[@]})); then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | json_lines)
  fi
  log "prepared; base OID: $base"
  jq -cn --arg base "$base" --arg root "$root" --arg scope "$scope" \
    --argjson dirty "$(json_lines <<<"$dirty")" --argjson warnings "$warnings_json" \
    '{base_oid: $base, root: $root, scope: $scope, dirty: $dirty, warnings: $warnings}'
}

# --- publish ------------------------------------------------------------------------

# canonical_checkout: the canonical checkout path (inventory.json written by
# rebuild, else instance.checkout).
canonical_checkout() {
  local inventory canonical=""
  inventory=$(state_root)/host-overrides/inventory.json
  if [[ -f $inventory && -r $inventory ]]; then
    canonical=$(jq -r 'if type == "object" then .canonical_repo // empty | strings else empty end' \
      "$inventory" 2>/dev/null) || canonical=""
  fi
  printf '%s\n' "${canonical:-$DS_INSTANCE_CHECKOUT}"
}

# sync_canonical_checkout BASE HEAD: best effort; never fails the publish.
sync_canonical_checkout() {
  local base=$1 head=$2 canonical branch=$DS_INSTANCE_BRANCH current="" origin="" at="" status=""
  canonical=$(canonical_checkout)
  [[ -n $canonical && -d $canonical ]] || return 0
  canonical=$(cd -P -- "$canonical" && pwd) || return 0
  [[ $canonical != "$DS_INSTANCE_ROOT" ]] || return 0
  [[ $(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) == "$canonical" ]] || return 0

  status=$(git -C "$canonical" status --porcelain 2>/dev/null) || status="unreadable"
  current=$(git -C "$canonical" symbolic-ref --quiet --short HEAD 2>/dev/null) || current=""
  origin=$(git -C "$canonical" remote get-url origin 2>/dev/null) || origin=""
  at=$(git -C "$canonical" rev-parse --verify --quiet HEAD 2>/dev/null) || at=""
  if [[ -z $status && $current == "$branch" && $origin == "$DS_INSTANCE_REMOTE" ]]; then
    # Already at the published commit: nothing to do.
    [[ $at != "$head" ]] || return 0
    if [[ $at == "$base" ]]; then
      if git_net 60 -C "$canonical" pull --ff-only --quiet origin "$branch" </dev/null >&2; then
        log "canonical checkout fast-forwarded to the published commit: $canonical"
      else
        warn "could not fast-forward the canonical checkout; run 'git pull --ff-only': $canonical"
      fi
      return 0
    fi
  fi
  warn "canonical checkout is not a clean clone of $DS_INSTANCE_REMOTE on $branch at the base OID $base; inspect it and run 'git pull --ff-only': $canonical"
}

cmd_publish() {
  local scope=update expected_base="" root branch base head record recorded_scope override
  local subject bad remote verified
  while (($#)); do
    case $1 in
      --scope | --expected-base)
        need_value "$1" "$#" "${2:-}"
        case $1 in
          --scope) scope=$2 ;;
          --expected-base) expected_base=$2 ;;
        esac
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  txn_valid_scope "$scope"

  require_command git
  require_command jq
  # shellcheck disable=SC2119 # config_load takes no argument here
  config_load
  root=$DS_INSTANCE_ROOT
  branch=$DS_INSTANCE_BRANCH
  txn_require_clone

  [[ -z $(git -C "$root" status --porcelain) ]] || die "update publish needs a committed, clean candidate"
  base=$(txn_resolve_base "$expected_base")
  head=$(git -C "$root" rev-parse HEAD)
  [[ $head != "$base" ]] || die "nothing to publish after the base OID $base"
  git -C "$root" merge-base --is-ancestor "$base" HEAD || die "base OID $base is not an ancestor of HEAD"

  # The validated tree, scope and framework.
  record=$(txn_json_object "$(txn_validation_file)")
  if [[ -z $record ]] || ! jq -e --arg tree "$(git -C "$root" rev-parse 'HEAD^{tree}')" \
    '.result == "passed" and .tree_oid == $tree' <<<"$record" >/dev/null; then
    die "HEAD tree is not the validated tree; run 'dotsteward gate --scope $scope' first"
  fi
  recorded_scope=$(jq -r '.scope | strings' <<<"$record")
  [[ $recorded_scope == "$scope" ]] ||
    die "the validation was made for the ${recorded_scope:-(none)} scope, not $scope; run 'dotsteward gate --scope $scope' first"
  override=$(jq -r '.framework_override // empty | tostring' <<<"$record")
  [[ -z $override ]] ||
    die "the validation used the framework override $override; run 'dotsteward gate --scope $scope' without an override first"

  # The commit subject policy.
  if [[ $scope == update ]]; then
    subject=$(git -C "$root" log -1 --format=%s HEAD)
    [[ $subject == "$DS_COMMIT_UPDATE_SUBJECT" ]] ||
      die "unexpected update commit subject: $subject (expected $DS_COMMIT_UPDATE_SUBJECT)"
  else
    bad=$(git -C "$root" log --format=%s "$base..HEAD" | grep -Ev -- "$CONVENTIONAL_SUBJECT" || true)
    [[ -z $bad ]] || die "commit subject is not a conventional commit: ${bad//$'\n'/, }"
  fi

  # The remote: still at the base, then the push, then the verification.
  fetch_branch
  remote=$(remote_branch_oid)
  if [[ $remote == "$head" ]]; then
    log "$branch is already $head on the remote; nothing to push"
    sync_canonical_checkout "$base" "$head"
    return 0
  fi
  [[ $remote == "$base" ]] || die "remote $branch changed since prepare: $remote, not the base OID $base"
  git_net 180 -C "$root" push origin "HEAD:refs/heads/$branch" </dev/null || die "push failed"
  verified=$(git_net 60 -C "$root" ls-remote origin "refs/heads/$branch" </dev/null |
    awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }') || verified=""
  [[ $verified == "$head" ]] ||
    die "could not verify the remote OID: $branch is ${verified:-missing}, expected $head"
  sync_canonical_checkout "$base" "$head"
  log "published $head to $branch without force; publishing does not activate the local system"
}

# --- status -------------------------------------------------------------------------

# status_record FILE: the record of FILE as compact JSON, or null (with a
# warning when the file exists but holds no JSON object).
status_record() {
  local record
  if [[ ! -e $1 ]]; then
    printf 'null\n'
    return 0
  fi
  record=$(txn_json_object "$1")
  if [[ -z $record ]]; then
    warn "ignoring $1: not a JSON object"
    printf 'null\n'
    return 0
  fi
  printf '%s\n' "$record"
}

cmd_status() {
  local as_json=0 state candidate validation log_file candidate_record validation_record
  while (($#)); do
    case $1 in
      --json)
        as_json=1
        shift
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_command jq
  # shellcheck disable=SC2119 # config_load takes no argument here
  config_load
  state=$(txn_state_dir)
  candidate=$(txn_candidate_file)
  validation=$(txn_validation_file)
  log_file=$(txn_log_file)
  candidate_record=$(status_record "$candidate")
  validation_record=$(status_record "$validation")

  if ((as_json)); then
    jq -cn --arg instance "$DS_INSTANCE_ROOT" --arg state "$state" --arg candidate "$candidate" \
      --arg validation "$validation" --arg log "$log_file" \
      --argjson candidate_record "$candidate_record" --argjson validation_record "$validation_record" '{
        schema_version: 1,
        instance: $instance,
        paths: {state_dir: $state, candidate: $candidate, validation: $validation, log: $log},
        candidate: $candidate_record,
        validation: $validation_record
      }'
    return 0
  fi

  log "state directory: $state"
  status_print candidate "$candidate" "$candidate_record"
  status_print validation "$validation" "$validation_record"
  if [[ -e $log_file ]]; then
    log "log: $log_file"
  else
    log "log: $log_file (none)"
  fi
}

# status_print LABEL FILE RECORD: the human form of one record.
status_print() {
  if [[ $3 == null ]]; then
    if [[ -e $2 ]]; then
      log "$1: $2 (not a JSON object)"
    else
      log "$1: $2 (none)"
    fi
    return 0
  fi
  log "$1: $2"
  jq . <<<"$3"
}

# --- dispatch -----------------------------------------------------------------------

# --help anywhere prints the usage before any check or state write.
for argument in "$@"; do
  case $argument in
    -h | --help)
      usage
      exit 0
      ;;
  esac
done

(($#)) || die "update requires a subcommand: prepare, publish or status"
subcommand=$1
shift
case $subcommand in
  prepare) cmd_prepare "$@" ;;
  publish) cmd_publish "$@" ;;
  status) cmd_status "$@" ;;
  *) die "unknown update subcommand: $subcommand (expected prepare, publish or status)" ;;
esac
