# shellcheck shell=bash
# Maintenance transaction helpers shared by `dotsteward gate` and
# `dotsteward update prepare|publish|status` (SPEC 6.2; the transaction of
# update.sh: prepare records a base, the gate proves a tree, publish ships a
# commit whose tree is the proven tree).
#
# Source after lib.sh and config.sh, then call config_load; every function
# works on the loaded instance (DS_INSTANCE_ROOT, DS_INSTANCE_BRANCH,
# DS_INSTANCE_REMOTE, ...).
#
# State files (all below <state root>/update, directory 0700, files 0600):
#   txn_state_dir, txn_candidate_file (candidate.json, written by prepare),
#   txn_validation_file (validation.json, written by a passing gate),
#   txn_log_file (validate.log), txn_lock_file (validate.lock)
#   txn_ensure_state_dir       creates the private state directory
#   txn_write_private FILE     writes standard input to FILE atomically
#                              (a temporary file in the same directory,
#                              mode 0600, then mv -f)
#   txn_json_object FILE       prints FILE as compact JSON when it holds a
#                              JSON object; prints nothing otherwise
# Guards (each refusal is a die, exit 1):
#   txn_valid_scope SCOPE      update or maintain
#   txn_require_clone          the instance root is the top of a git work
#                              tree, on instance.branch, whose origin URL is
#                              exactly instance.remote
#   txn_require_no_untracked   no untracked, non-ignored file (Nix does not
#                              see them)
# Base and candidate:
#   txn_recorded_base          base_oid of candidate.json when its root is
#                              this instance
#   txn_resolve_base [OID]     OID, else the recorded base, else
#                              `git merge-base HEAD origin/<branch>`; it must
#                              be a full object id of a commit of the clone
#   txn_allowlist_load         fills TXN_ALLOWLIST (anchored ERE entries)
#                              and TXN_ALLOWLIST_LABELS from the framework
#                              defaults, every committed manifest mirror and
#                              gate.update_allowlist
#   txn_check_allowlist BASE   the update scope: every path changed between
#                              BASE and the working tree (renames split into
#                              both paths) matches an entry, and none is in
#                              the settings buffer
#   txn_working_tree_oid       the tree `git add -A && git write-tree` would
#                              write, computed in a throw-away index

# --- state ------------------------------------------------------------------------

txn_state_dir() {
  printf '%s/update\n' "$(state_root)"
}

txn_candidate_file() {
  printf '%s/candidate.json\n' "$(txn_state_dir)"
}

txn_validation_file() {
  printf '%s/validation.json\n' "$(txn_state_dir)"
}

txn_log_file() {
  printf '%s/validate.log\n' "$(txn_state_dir)"
}

txn_lock_file() {
  printf '%s/validate.lock\n' "$(txn_state_dir)"
}

txn_ensure_state_dir() {
  ensure_private_dir "$(txn_state_dir)" || die "cannot create the state directory: $(txn_state_dir)"
}

txn_write_private() {
  (($# == 1)) || die "usage: txn_write_private FILE"
  local file=$1 directory temporary
  directory=$(dirname -- "$file")
  temporary=$(mktemp "$directory/.${file##*/}.XXXXXX") || die "cannot write $file"
  if ! { cat >"$temporary" && chmod 0600 -- "$temporary" && mv -f -- "$temporary" "$file"; }; then
    rm -f -- "$temporary"
    die "cannot write $file"
  fi
}

txn_json_object() {
  (($# == 1)) || die "usage: txn_json_object FILE"
  [[ -f $1 && -r $1 ]] || return 0
  jq -c 'select(type == "object")' "$1" 2>/dev/null || true
}

# --- guards -------------------------------------------------------------------------

txn_valid_scope() {
  case ${1:-} in
    update | maintain) ;;
    *) die "unsupported scope: ${1:-} (expected update or maintain)" ;;
  esac
}

txn_require_clone() {
  local root=$DS_INSTANCE_ROOT top branch origin
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [[ -z $top || $(cd -P -- "$top" && pwd) != "$root" ]]; then
    die "maintenance runs only in a git clone: $root"
  fi
  if ! branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    die "maintenance branch must be $DS_INSTANCE_BRANCH, not a detached HEAD"
  fi
  [[ $branch == "$DS_INSTANCE_BRANCH" ]] || die "maintenance branch must be $DS_INSTANCE_BRANCH, not $branch"
  origin=$(git -C "$root" remote get-url origin 2>/dev/null) || origin="(none)"
  [[ $origin == "$DS_INSTANCE_REMOTE" ]] ||
    die "unexpected origin URL: $origin (expected $DS_INSTANCE_REMOTE)"
}

txn_require_no_untracked() {
  local -a files=()
  mapfile -d '' -t files < <(git -C "$DS_INSTANCE_ROOT" ls-files -z --others --exclude-standard)
  wait "$!" || die "cannot list the untracked files of $DS_INSTANCE_ROOT"
  ((${#files[@]} == 0)) || die "Nix does not see untracked files; run 'git add -A' first: ${files[*]}"
}

# --- base -----------------------------------------------------------------------------

txn_recorded_base() {
  local file
  file=$(txn_candidate_file)
  [[ -f $file && -r $file ]] || return 0
  jq -r --arg root "$DS_INSTANCE_ROOT" \
    'select(type == "object" and .root == $root) | .base_oid | strings' "$file" 2>/dev/null || true
}

txn_resolve_base() {
  local base=${1:-} root=$DS_INSTANCE_ROOT format length
  if [[ -z $base ]]; then
    base=$(txn_recorded_base)
  fi
  if [[ -z $base ]]; then
    base=$(git -C "$root" merge-base HEAD "refs/remotes/origin/$DS_INSTANCE_BRANCH" 2>/dev/null) || base=""
  fi
  format=$(git -C "$root" rev-parse --show-object-format 2>/dev/null) || format=sha1
  length=40
  [[ $format == sha256 ]] && length=64
  [[ $base =~ ^[0-9a-f]+$ && ${#base} -eq $length ]] ||
    die "no valid base OID; run 'dotsteward update prepare' first or pass --expected-base"
  git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null ||
    die "base OID is not a commit of this clone: $base"
  printf '%s\n' "$base"
}

# --- update allowlist ---------------------------------------------------------------

# _txn_ere_literal TEXT: TEXT as an extended regular expression that matches
# only TEXT.
_txn_ere_literal() {
  local text=$1 out="" char i specials=".[]()*+?{}|^\$\\"
  for ((i = 0; i < ${#text}; i++)); do
    char=${text:i:1}
    if [[ $specials == *"$char"* ]]; then
      out+="\\$char"
    else
      out+=$char
    fi
  done
  printf '%s\n' "$out"
}

# _txn_allowlist_add LABEL ENTRY...: appends valid entries, refusing an
# invalid one.
_txn_allowlist_add() {
  local label=$1 entry i=0 status
  shift
  for entry in "$@"; do
    i=$((i + 1))
    status=0
    # shellcheck disable=SC2319 # the status of =~ itself: 2 means an invalid regex
    [[ "" =~ $entry ]] || status=$?
    ((status != 2)) ||
      die "invalid update allowlist: $label entry $i is not a valid extended regular expression: $entry"
    TXN_ALLOWLIST+=("$entry")
    TXN_ALLOWLIST_LABELS+=("$label entry $i")
  done
}

txn_allowlist_load() {
  local root=$DS_INSTANCE_ROOT mirror name vendor
  local -a entries=()
  TXN_ALLOWLIST=()
  TXN_ALLOWLIST_LABELS=()
  vendor=${DS_SKILLS_VENDOR_DIR%/}
  # The files the framework itself maintains in every instance.
  entries=(
    'flake\.nix'
    'flake\.lock'
    "$(_txn_ere_literal "$DS_PINS_VERSIONS_LOCK")"
    "$(_txn_ere_literal "$DS_SKILLS_LOCK")"
    "$(_txn_ere_literal "$vendor")/[^/]+/.+"
    '\.dotsteward/(manifest\.[^/]+\.json|stage0\.[^/]+\.env|cli\.sh)'
    '(bootstrap|rebuild|rollback|update)\.sh'
  )
  _txn_allowlist_add "framework default" "${entries[@]}"
  # The component contributions (gate.updatePaths) of every system.
  for mirror in "$root"/.dotsteward/manifest.*.json; do
    [[ -f $mirror ]] || continue
    name=${mirror#"$root"/}
    if ! jq -e '(.update_allowlist // []) | type == "array" and all(type == "string")' "$mirror" >/dev/null 2>&1; then
      die "invalid update allowlist: $name is not valid JSON with an update_allowlist list of strings"
    fi
    mapfile -t entries < <(jq -r '(.update_allowlist // [])[]' "$mirror")
    _txn_allowlist_add "$name update_allowlist" "${entries[@]}"
  done
  _txn_allowlist_add gate.update_allowlist "${DS_GATE_UPDATE_ALLOWLIST[@]}"
}

# _txn_allowed PATH: PATH matches one whole allowlist entry.
_txn_allowed() {
  local entry
  for entry in "${TXN_ALLOWLIST[@]}"; do
    [[ $1 =~ ^($entry)$ ]] && return 0
  done
  return 1
}

txn_check_allowlist() {
  (($# == 1)) || die "usage: txn_check_allowlist BASE"
  local base=$1 buffer path
  local -a paths=() outside=() buffered=()
  buffer=${DS_SETTINGS_BUFFER_DIR%/}
  txn_allowlist_load
  mapfile -d '' -t paths < <(git -C "$DS_INSTANCE_ROOT" diff --name-only --no-renames -z "$base" --)
  wait "$!" || die "cannot list the changes since the base OID $base"
  for path in "${paths[@]}"; do
    if [[ $path == "$buffer" || $path == "$buffer"/* ]]; then
      buffered+=("$path")
    elif ! _txn_allowed "$path"; then
      outside+=("$path")
    fi
  done
  ((${#buffered[@]} == 0)) || die "the update scope never changes the settings buffer: ${buffered[*]}"
  ((${#outside[@]} == 0)) || die "changes outside the update allowlist: ${outside[*]}"
}

# --- candidate tree -----------------------------------------------------------------

txn_working_tree_oid() {
  local temporary oid status=0
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-index.XXXXXX") || die "could not compute the working tree id"
  oid=$(
    export GIT_INDEX_FILE=$temporary/index
    git -C "$DS_INSTANCE_ROOT" read-tree HEAD &&
      git -C "$DS_INSTANCE_ROOT" add -A &&
      git -C "$DS_INSTANCE_ROOT" write-tree
  ) || status=$?
  cleanup_temp_dir "$temporary"
  ((status == 0)) && [[ -n $oid ]] || die "could not compute the working tree id"
  printf '%s\n' "$oid"
}
