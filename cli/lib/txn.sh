# shellcheck shell=bash
# Maintenance transaction helpers shared by `dotsteward gate`, `dotsteward
# e2e`, `dotsteward rebuild` and `dotsteward update prepare|publish|status`
# (prepare records a base, the gate proves a tree, rebuild --switch
# activates it and e2e verifies the machine, publish ships a commit whose
# tree is the proven tree).
#
# Source after lib.sh and config.sh, then call config_load; every function
# works on the loaded instance (DS_INSTANCE_ROOT, DS_INSTANCE_BRANCH,
# DS_INSTANCE_REMOTE, ...).
#
# State files (all below <state root>/update, directory 0700, files 0600):
#   txn_state_dir, txn_candidate_file (candidate.json, written by prepare),
#   txn_validation_file (validation.json, written by a passing gate),
#   txn_e2e_file (e2e.json, the result of the last `dotsteward e2e` run),
#   txn_log_file (validate.log), txn_lock_file (validate.lock),
#   txn_generation_file        generation.json, written by a passing gate:
#                              the generation its cli-probes step built
#                              (tree_oid, profile, system, username, home,
#                              generation, framework_override, root,
#                              recorded_at); rebuild reuses it for exactly
#                              that tree, profile, identity and override
#   txn_activation_file        <state root>/current/activation.json, written
#                              by rebuild --switch when it activated a
#                              generation (generation, profile, revision,
#                              tree_oid, root, framework_override,
#                              activated_at)
#   txn_ensure_state_dir       creates the private state directory
#   txn_write_private FILE     writes standard input to FILE atomically
#                              (a temporary file in the same directory,
#                              mode 0600, then mv -f)
#   txn_json_object FILE       prints FILE as compact JSON when it holds a
#                              JSON object; prints nothing otherwise
#   txn_private_file FILE      true when FILE is a regular file, no symbolic
#                              link, owned by the user and writable by
#                              nobody else
# Guards (each refusal is a die, exit 1):
#   txn_valid_scope SCOPE      update or maintain
#   txn_require_clone          the instance root is the top of a git work
#                              tree, on instance.branch, whose origin URL is
#                              exactly instance.remote (a missing origin
#                              names the `git remote add` to run)
#   txn_require_no_untracked   no untracked, non-ignored file (Nix does not
#                              see them)
# Base and candidate:
#   txn_recorded_base          base_oid of candidate.json when its root is
#                              this instance
#   txn_unpublished            true when origin/<branch> does not exist in
#                              the clone (a new instance before its first
#                              push)
#   txn_head_oid               the HEAD commit; a branch without a commit
#                              names the commit to make
#   txn_resolve_base [OID]     OID, else the recorded base, else
#                              `git merge-base HEAD origin/<branch>`; it must
#                              be a full object id of a commit of the clone.
#                              Without origin/<branch> it names the first
#                              push instead
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
# Activation:
#   txn_require_verified_activation BASE
#                              when the transaction activated a tree on this
#                              machine (the activated tree is the HEAD tree,
#                              or the activated revision is a commit after
#                              BASE), the activated tree is the HEAD tree
#                              and e2e.json records a passed run of that
#                              tree, the activated generation and the
#                              activated profile, with the repository
#                              checks; an activation of another tree outside
#                              BASE..HEAD asks for nothing

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

txn_e2e_file() {
  printf '%s/e2e.json\n' "$(txn_state_dir)"
}

txn_activation_file() {
  printf '%s/current/activation.json\n' "$(state_root)"
}

txn_log_file() {
  printf '%s/validate.log\n' "$(txn_state_dir)"
}

txn_generation_file() {
  printf '%s/generation.json\n' "$(txn_state_dir)"
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

txn_private_file() {
  (($# == 1)) || die "usage: txn_private_file FILE"
  local mode
  [[ -f $1 && ! -L $1 && -O $1 ]] || return 1
  mode=$(stat -c %a -- "$1" 2>/dev/null) || return 1
  [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 8#022) == 0))
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
  origin=$(git -C "$root" remote get-url origin 2>/dev/null) || origin=""
  [[ -n $origin ]] ||
    die "the clone has no origin remote; add it with: git -C $(printf '%q' "$root") remote add origin $(printf '%q' "$DS_INSTANCE_REMOTE")"
  [[ $origin == "$DS_INSTANCE_REMOTE" ]] ||
    die "unexpected origin URL: $origin (expected $DS_INSTANCE_REMOTE)"
}

# _txn_git_list ARRAY ARG...: the NUL-separated output of `git -C <instance>
# ARG...` as the elements of ARRAY; returns git's status. The output goes
# through a temporary file: the status of a process substitution read with
# `wait "$!"` depends on whether bash already reaped it, which made the
# callers fail at random.
_txn_git_list() {
  local -n _txn_list=$1
  local list status=0
  shift
  list=$(mktemp "${TMPDIR:-/tmp}/dotsteward-git.XXXXXX") || return 1
  git -C "$DS_INSTANCE_ROOT" "$@" >"$list" || status=$?
  _txn_list=()
  ((status != 0)) || mapfile -d '' -t _txn_list <"$list"
  rm -f -- "$list"
  return "$status"
}

txn_require_no_untracked() {
  local -a files=()
  _txn_git_list files ls-files -z --others --exclude-standard ||
    die "cannot list the untracked files of $DS_INSTANCE_ROOT"
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

txn_unpublished() {
  ! git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DS_INSTANCE_BRANCH" >/dev/null
}

txn_head_oid() {
  local root=$DS_INSTANCE_ROOT quoted
  printf -v quoted '%q' "$root"
  git -C "$root" rev-parse --verify --quiet 'HEAD^{commit}' ||
    die "$DS_INSTANCE_BRANCH has no commit yet; commit the instance first: git -C $quoted add -A && git -C $quoted commit"
}

txn_resolve_base() {
  local base=${1:-} root=$DS_INSTANCE_ROOT format length quoted
  if [[ -z $base ]]; then
    base=$(txn_recorded_base)
  fi
  if [[ -z $base ]]; then
    txn_head_oid >/dev/null
    if txn_unpublished; then
      printf -v quoted '%q' "$root"
      die "origin/$DS_INSTANCE_BRANCH does not exist in this clone; push the first commit of a new instance with: git -C $quoted push -u origin $DS_INSTANCE_BRANCH (after 'dotsteward gate --scope maintain' passed), or run 'git -C $quoted fetch origin' when the remote has $DS_INSTANCE_BRANCH already"
    fi
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
  _txn_git_list paths diff --name-only --no-renames -z "$base" -- ||
    die "cannot list the changes since the base OID $base"
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

# --- activation ---------------------------------------------------------------------

txn_require_verified_activation() {
  (($# == 1)) || die "usage: txn_require_verified_activation BASE"
  local base=$1 root=$DS_INSTANCE_ROOT record revision activated generation profile name tree e2e other
  record=$(txn_json_object "$(txn_activation_file)")
  [[ -n $record ]] || return 0
  revision=$(jq -r '.revision // empty | strings' <<<"$record")
  activated=$(jq -r '.tree_oid // empty | strings' <<<"$record")
  generation=$(jq -r '.generation // empty | strings' <<<"$record")
  profile=$(jq -r '.profile // empty | strings' <<<"$record")
  name=${profile:-PROFILE}
  tree=$(git -C "$root" rev-parse 'HEAD^{tree}') || die "cannot read the tree of HEAD in $root"
  if [[ $activated != "$tree" ]]; then
    # Another tree is active: it concerns this transaction only when its
    # revision is a commit after the base.
    [[ -n $revision && $revision != "$base" ]] || return 0
    git -C "$root" cat-file -e "$revision^{commit}" 2>/dev/null || return 0
    git -C "$root" merge-base --is-ancestor "$base" "$revision" 2>/dev/null || return 0
    git -C "$root" merge-base --is-ancestor "$revision" HEAD 2>/dev/null || return 0
    die "this transaction activated ${revision:0:12} on this machine (rebuild --switch), not the tree of HEAD; activate HEAD and run E2E for it first: dotsteward rebuild --profile $name --switch, then dotsteward e2e --profile $name --expected-remote-base $base"
  fi
  # The E2E run must have checked the activated profile too: a run of
  # another profile ran the hooks of other components.
  e2e=$(txn_json_object "$(txn_e2e_file)")
  if [[ -z $e2e ]] || ! jq -e --arg tree "$tree" --arg generation "$generation" --arg profile "$profile" '
    .result == "passed" and .tree_oid == $tree and .generation == $generation
    and .profile == $profile and .repo_checks == true' <<<"$e2e" >/dev/null; then
    other=""
    if [[ -n $e2e ]]; then
      other=$(jq -r --arg profile "$profile" '.profile // "" | strings | select(. != $profile)' <<<"$e2e")
    fi
    die "the tree of HEAD is active on this machine (generation ${generation:-unknown}, rebuild --switch) but no passing E2E is recorded for this tree and generation; run 'dotsteward e2e --profile $name --expected-remote-base $base' first${other:+ (the recorded E2E checked the profile $other, not $name)}"
  fi
}

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
