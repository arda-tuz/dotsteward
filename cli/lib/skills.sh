# shellcheck shell=bash
# The skill layout engine of `dotsteward agents` (SPEC 8.1, D2, D7): the
# generic port of the skill part of the agents installer. Source after
# lib.sh, config.sh and methods.sh, once config_load and
# methods_manifest_load have run; sourcing defines functions only.
#
# Layout. The canonical skill root is ~/.agents/skills, a physical
# directory every agent discovers. Components contribute (manifest
# skill_layout): legacy roots (searched after the canonical root, created by
# install, never moved), link roots with a target prefix (one link per skill,
# named by the lock name: <root>/<name> -> <prefix><canonical entry name>)
# and excluded subtrees (names that must never appear in the canonical
# root). Home Manager links skills under ~/<skills.hm_root>.
#
#   skills_init PROFILE CHECK_ONLY [GENERATION]
#       reads the layout, the Home Manager root and the instance skills lock
#       paths; GENERATION (a built or active Home Manager generation) is
#       what framework skill links must resolve into
#   skills_active_generation
#       prints the active Home Manager generation that carries a dotsteward
#       manifest (<XDG state>/home-manager/gcroots/current-home, then the
#       home-manager profile in <XDG state>/nix/profiles and in
#       /nix/var/nix/profiles/per-user/$USER), nothing when there is none
#   skills_validate_lock
#       the instance skills lock: a regular file, schema_version "1.0",
#       expected_skill_count equal to its entries, each entry with name,
#       directory (a plain name) and skill_sha256, optional
#       legacy_directory, directory_sha256 and deployment (copy, the
#       default, or home-manager); no dotsteward-* name (framework skills
#       are never instance lock entries)
#   skills_ensure_layout
#       install: creates ~/.agents and every legacy root; a canonical root
#       that is a link to a legacy root is migrated to a directory. Both
#       modes: every legacy root is a real directory, the canonical root
#       is a directory, no excluded subtree is in it.
#   skills_framework_entries, skills_instance_entries
#       one compact JSON object per line: the framework skills of the
#       manifest ({name, entry}, entry from skills.framework_manifest or
#       null) and the instance lock entries in file order
#   skills_process_framework NAME ENTRY_JSON
#       a framework skill: ~/<hm_root>/<directory> must be a link that
#       resolves to the generation's home-files/<hm_root>/<directory> (the
#       framework source) with the SKILL.md and directory digests of the
#       framework skills manifest; never installed or refreshed; then the
#       canonical entry and the link-root links
#   skills_process_instance ENTRY_JSON
#       an instance skill: the vendored source (<skills.vendor_dir>/
#       <directory>) is verified against the lock first; the installed copy
#       is searched (canonical root, legacy roots, the Home Manager root;
#       directory before legacy_directory). Missing: home-managed skills are
#       fatal, copy skills are installed (install mode) with the native copy
#       or the [skills] installer argv. Present copy skills with a
#       directory digest are refreshed when they differ (check: fatal).
#       Home-managed skills must be links with the lock digest. Then the
#       canonical entry and the link-root links.
#   skills_sweep
#       removes (install) or reports (check) every dangling link directly
#       in the canonical root and the link roots whose literal target is
#       in a managed root (relative ../../<root>/... or $HOME/<root>/...,
#       or a link-root target prefix); other links stay
#   skills_find_existing DIRECTORY LEGACY_DIRECTORY
#   skills_canonical_entry PATH
#       prints the canonical entry of a found skill (the path itself under
#       the canonical root, else <canonical>/<found name>, a link
#       ../../<root>/<found name> for a root in the home directory or the
#       absolute path otherwise); prints nothing else on standard output
#
# Failures. skills_fail CODE PATH MESSAGE records a finding and exits 1 (the
# caller runs each unit in a subshell); skills_finding records and returns.
# A finding is one JSON line { step, path, code, message } appended to
# SKILLS_FINDINGS_FILE when it is set (SKILLS_STEP names the step) and an
# "[dotsteward] ERROR: MESSAGE" line on standard error. Codes:
#   setup: lock-invalid
#   layout: skill-root-missing, skill-root-invalid, canonical-link-broken,
#     canonical-link-foreign, canonical-not-migrated,
#     canonical-create-failed, canonical-not-directory, canonical-missing,
#     excluded-subtree-present
#   framework skills: framework-manifest-missing, framework-skill-missing,
#     framework-skill-not-link, framework-skill-broken,
#     framework-skill-unverifiable, framework-skill-not-in-generation,
#     framework-skill-foreign, framework-skill-digest-mismatch
#   skills: source-missing, source-digest-mismatch, skill-missing,
#     home-managed-missing, home-managed-not-link,
#     home-managed-digest-mismatch, skill-unresolvable, skill-drift,
#     skill-not-directory, refresh-digest-mismatch,
#     install-destination-exists, install-source-invalid,
#     installer-missing, installer-failed, install-unverified,
#     install-digest-mismatch
#   entries and links (both skill steps): entry-broken, entry-foreign,
#     entry-shadowed, entry-missing, link-broken, link-foreign,
#     link-not-symlink, link-missing
#   sweep: dangling-link
# Messages that ask for a change name 'dotsteward rebuild --profile
# <profile> --switch', which runs `agents install` after activation.

SKILLS_CHECK_ONLY=0
SKILLS_KEEP_GOING=${SKILLS_KEEP_GOING:-0}
SKILLS_PROFILE=''
SKILLS_GENERATION=''
SKILLS_STEP=${SKILLS_STEP:-agents}
SKILLS_CANONICAL=''
SKILLS_HM_ROOT=''
SKILLS_HM_ROOT_REL=''
SKILLS_LOCK=''
SKILLS_VENDOR=''
SKILLS_LEGACY_ROOTS=()
SKILLS_SEARCH_ROOTS=()
SKILLS_MANAGED_ROOTS=()
SKILLS_LINK_ROOTS=()
SKILLS_LINK_PREFIXES=()
SKILLS_EXCLUDED=()
SKILLS_SWEEP_PREFIXES=()

# --- Findings -------------------------------------------------------------

skills_finding() {
  local code=$1 path=$2
  shift 2
  if [[ -n ${SKILLS_FINDINGS_FILE:-} ]]; then
    jq -cn --arg step "${SKILLS_STEP:-agents}" --arg path "$path" --arg code "$code" --arg message "$*" \
      '{ step: $step, path: $path, code: $code, message: $message }' >>"$SKILLS_FINDINGS_FILE"
  fi
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
}

skills_fail() {
  skills_finding "$@"
  exit 1
}

_skills_rebuild_hint() {
  printf "run 'dotsteward rebuild --profile %s --switch'" "$SKILLS_PROFILE"
}

# --- Setup ----------------------------------------------------------------

# _skills_expand PATH: ~/x -> $HOME/x; absolute paths unchanged; without a
# trailing slash.
_skills_expand() {
  local path=$1
  case $path in
    \~/?*) path=$HOME/${path#\~/} ;;
    /?*) ;;
    *) die "invalid skill root (expected ~/... or an absolute path): $path" ;;
  esac
  printf '%s\n' "${path%/}"
}

_skills_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

skills_init() {
  (($# == 2 || $# == 3)) || die "usage: skills_init PROFILE CHECK_ONLY [GENERATION]"
  [[ -n ${DS_MANIFEST_JSON:-} ]] || die "skills_init: the manifest is not loaded"
  local root prefix rel
  SKILLS_PROFILE=$1
  SKILLS_CHECK_ONLY=$2
  SKILLS_GENERATION=${3:-}
  SKILLS_CANONICAL=$HOME/.agents/skills
  SKILLS_HM_ROOT_REL=$(jq -r '.skills.hm_root // empty' <<<"$DS_MANIFEST_JSON")
  [[ -n $SKILLS_HM_ROOT_REL ]] || SKILLS_HM_ROOT_REL=${DS_SKILLS_HM_ROOT:-.agents/skills}
  SKILLS_HM_ROOT_REL=${SKILLS_HM_ROOT_REL%/}
  [[ $SKILLS_HM_ROOT_REL != /* && $SKILLS_HM_ROOT_REL != \~* && /$SKILLS_HM_ROOT_REL/ != */../* ]] ||
    die "invalid skills.hm_root (expected a path relative to the home directory): $SKILLS_HM_ROOT_REL"
  SKILLS_HM_ROOT=$HOME/$SKILLS_HM_ROOT_REL

  SKILLS_LEGACY_ROOTS=()
  while IFS= read -r -d '' root; do
    root=$(_skills_expand "$root") || exit 1
    [[ $root == "$SKILLS_CANONICAL" ]] && continue
    _skills_contains "$root" "${SKILLS_LEGACY_ROOTS[@]}" || SKILLS_LEGACY_ROOTS+=("$root")
  done < <(jq -j '(.skill_layout.legacy_roots // [])[] | ., "\u0000"' <<<"$DS_MANIFEST_JSON")

  SKILLS_LINK_ROOTS=()
  SKILLS_LINK_PREFIXES=()
  while IFS= read -r -d '' root && IFS= read -r -d '' prefix; do
    root=$(_skills_expand "$root") || exit 1
    [[ -n $prefix ]] || die "skill link root $root has an empty target prefix"
    SKILLS_LINK_ROOTS+=("$root")
    SKILLS_LINK_PREFIXES+=("$prefix")
  done < <(jq -j '(.skill_layout.link_roots // {}) | to_entries[] | .key, "\u0000", (.value.target_prefix // ""), "\u0000"' \
    <<<"$DS_MANIFEST_JSON")

  SKILLS_EXCLUDED=()
  while IFS= read -r -d '' root; do
    [[ -n $root && $root != /* && /$root/ != */../* ]] || die "invalid excluded skill subtree: $root"
    SKILLS_EXCLUDED+=("${root%/}")
  done < <(jq -j '(.skill_layout.excluded_subtrees // [])[] | ., "\u0000"' <<<"$DS_MANIFEST_JSON")

  SKILLS_SEARCH_ROOTS=("$SKILLS_CANONICAL" "${SKILLS_LEGACY_ROOTS[@]}")
  _skills_contains "$SKILLS_HM_ROOT" "${SKILLS_SEARCH_ROOTS[@]}" || SKILLS_SEARCH_ROOTS+=("$SKILLS_HM_ROOT")
  SKILLS_MANAGED_ROOTS=("$SKILLS_CANONICAL" "${SKILLS_LEGACY_ROOTS[@]}")

  # Literal link targets that point into a managed root.
  SKILLS_SWEEP_PREFIXES=()
  for root in "${SKILLS_SEARCH_ROOTS[@]}"; do
    if [[ $root == "$HOME"/* ]]; then
      rel=${root#"$HOME"/}
      SKILLS_SWEEP_PREFIXES+=("../../$rel/")
    fi
    SKILLS_SWEEP_PREFIXES+=("$root/")
  done
  for prefix in "${SKILLS_LINK_PREFIXES[@]}"; do
    _skills_contains "$prefix" "${SKILLS_SWEEP_PREFIXES[@]}" || SKILLS_SWEEP_PREFIXES+=("$prefix")
  done

  SKILLS_LOCK=$(config_instance_path "${DS_SKILLS_LOCK:-agent/skills.lock.json}") || exit 1
  SKILLS_VENDOR=$(config_instance_path "${DS_SKILLS_VENDOR_DIR:-agent/skills}") || exit 1
}

skills_active_generation() {
  local state=${XDG_STATE_HOME:-$HOME/.local/state} candidate
  for candidate in \
    "$state/home-manager/gcroots/current-home" \
    "$state/nix/profiles/home-manager" \
    "${NIX_STATE_DIR:-/nix/var/nix}/profiles/per-user/${USER:-}/home-manager"; do
    if [[ -f $candidate/home-path/share/dotsteward/manifest.json ]]; then
      realpath -e -- "$candidate"
      return 0
    fi
  done
}

# shellcheck disable=SC2016 # a jq program: jq expands its $names
_SKILLS_LOCK_JQ='
def nonempty: type == "string" and length > 0;
def plain: nonempty and (test("/") | not) and . != "." and . != "..";
if type != "object" then "not a JSON object"
else
  (if .schema_version != "1.0" then "schema_version is not \"1.0\"" else empty end),
  (if (.skills | type) != "array" then "skills is not a list"
   else
     (if .expected_skill_count != (.skills | length) then
        "expected_skill_count is \(.expected_skill_count), the lock has \(.skills | length) skills"
      else empty end),
     (.skills | to_entries[] | .key as $i | .value as $s
      | if ($s | type) != "object" or ([$s.name, $s.directory, $s.skill_sha256] | all(nonempty) | not) then
          "skill \($i + 1): name, directory and skill_sha256 must be non-empty strings"
        else
          (if $s.name | startswith("dotsteward-") then
             "the instance skills lock lists \($s.name); dotsteward-* names belong to the framework"
           else empty end),
          (if $s.directory | plain then empty
           else "skill \($s.name): directory must be a plain directory name" end),
          (if $s.legacy_directory == null or ($s.legacy_directory | plain) then empty
           else "skill \($s.name): legacy_directory must be a plain directory name" end),
          (if $s.directory_sha256 == null or ($s.directory_sha256 | nonempty) then empty
           else "skill \($s.name): directory_sha256 must be a non-empty string" end),
          (if $s.deployment == null or $s.deployment == "copy" or $s.deployment == "home-manager" then empty
           else "skill \($s.name): unknown deployment \($s.deployment)" end)
        end),
     (if all(.skills[]; type == "object") then
        (.skills | map(.name) | group_by(.) | map(select(length > 1) | .[0])[]
          | "skill \(.) is listed more than once"),
        (.skills | map(.directory) | group_by(.) | map(select(length > 1) | .[0])[]
          | "directory \(.) is used by more than one skill")
      else empty end)
   end)
end'

skills_validate_lock() {
  local lock=$SKILLS_LOCK errors=() error
  [[ -f $lock && ! -L $lock ]] || skills_fail lock-invalid "$lock" "skills lock is not a regular file: $lock"
  jq empty "$lock" >/dev/null 2>&1 || skills_fail lock-invalid "$lock" "invalid skills lock $lock: not valid JSON"
  mapfile -t errors < <(jq -r "$_SKILLS_LOCK_JQ" "$lock")
  ((${#errors[@]} == 0)) && return 0
  for error in "${errors[@]}"; do
    skills_finding lock-invalid "$lock" "invalid skills lock $lock: $error"
  done
  exit 1
}

# --- Layout ---------------------------------------------------------------

skills_ensure_layout() {
  local root canonical=$SKILLS_CANONICAL real root_real matched=0 text excluded
  if ((!SKILLS_CHECK_ONLY)); then
    mkdir -p -- "${canonical%/*}" 2>/dev/null || true
    for root in "${SKILLS_LEGACY_ROOTS[@]}"; do
      mkdir -p -- "$root" 2>/dev/null || true
    done
  fi
  for root in "${SKILLS_LEGACY_ROOTS[@]}"; do
    if [[ ! -e $root && ! -L $root ]]; then
      skills_fail skill-root-missing "$root" "skill root missing: $root"
    fi
    [[ -d $root && ! -L $root ]] || skills_fail skill-root-invalid "$root" "skill root is not a directory: $root"
  done

  if [[ -L $canonical ]]; then
    real=$(realpath -e -- "$canonical" 2>/dev/null) ||
      skills_fail canonical-link-broken "$canonical" "broken canonical skill root link: $canonical"
    for root in "${SKILLS_LEGACY_ROOTS[@]}"; do
      root_real=$(realpath -e -- "$root")
      [[ $root_real == "$real" ]] && matched=1
    done
    ((matched)) ||
      skills_fail canonical-link-foreign "$canonical" "canonical skill root links to an unexpected target: $canonical"
    if ((SKILLS_CHECK_ONLY)); then
      skills_fail canonical-not-migrated "$canonical" \
        "canonical skill root is still a link to a legacy skill root: $canonical; $(_skills_rebuild_hint) to migrate it"
    fi
    log "migrating the canonical skill root link to a directory: $canonical"
    text=$(readlink -- "$canonical")
    unlink -- "$canonical"
    if ! mkdir -- "$canonical"; then
      ln -s -- "$text" "$canonical" || true
      skills_fail canonical-create-failed "$canonical" "cannot create the canonical skill directory: $canonical"
    fi
  elif [[ -e $canonical ]]; then
    [[ -d $canonical ]] ||
      skills_fail canonical-not-directory "$canonical" "canonical skill root is not a directory: $canonical"
  elif ((SKILLS_CHECK_ONLY)); then
    skills_fail canonical-missing "$canonical" "canonical skill directory missing: $canonical"
  else
    mkdir -- "$canonical"
  fi

  for excluded in "${SKILLS_EXCLUDED[@]}"; do
    if [[ -e $canonical/$excluded || -L $canonical/$excluded ]]; then
      skills_fail excluded-subtree-present "$canonical/$excluded" \
        "excluded skill subtree present in the canonical skill root: $canonical/$excluded"
    fi
  done
}

# --- Entries and links ----------------------------------------------------

skills_find_existing() {
  (($# == 2)) || die "usage: skills_find_existing DIRECTORY LEGACY_DIRECTORY"
  local root candidate
  for root in "${SKILLS_SEARCH_ROOTS[@]}"; do
    for candidate in "$1" "$2"; do
      [[ -n $candidate ]] || continue
      if [[ -f $root/$candidate/SKILL.md ]]; then
        printf '%s\n' "$root/$candidate"
        return 0
      fi
    done
  done
}

skills_canonical_entry() {
  (($# == 1)) || die "usage: skills_canonical_entry PATH"
  local path=$1 canonical=$SKILLS_CANONICAL entry link actual_real link_real target
  actual_real=$(realpath -e -- "$path" 2>/dev/null) ||
    skills_fail skill-unresolvable "$path" "cannot resolve the skill path: $path"
  case $path in
    "$canonical"/*)
      printf '%s\n' "$path"
      return 0
      ;;
  esac
  entry=${path##*/}
  link=$canonical/$entry
  if [[ -L $link ]]; then
    link_real=$(realpath -e -- "$link" 2>/dev/null) ||
      skills_fail entry-broken "$link" "broken canonical skill entry: $link"
    [[ $link_real == "$actual_real" ]] ||
      skills_fail entry-foreign "$link" "canonical skill entry points to an unexpected target: $link"
  elif [[ -e $link ]]; then
    skills_fail entry-shadowed "$link" "canonical skill path shadows an existing skill: $link"
  elif ((SKILLS_CHECK_ONLY)); then
    skills_fail entry-missing "$link" "canonical skill entry missing: $link"
  else
    if [[ $path == "$HOME"/* ]]; then
      target=../../${path#"$HOME"/}
    else
      target=$path
    fi
    ln -s -- "$target" "$link"
  fi
  printf '%s\n' "$link"
}

# _skills_link_roots NAME ENTRY: <link root>/NAME -> <prefix><entry name>.
_skills_link_roots() {
  local name=$1 entry=$2 actual_real link_real link i
  actual_real=$(realpath -e -- "$entry" 2>/dev/null) ||
    skills_fail skill-unresolvable "$entry" "cannot resolve the skill path: $entry"
  for i in "${!SKILLS_LINK_ROOTS[@]}"; do
    link=${SKILLS_LINK_ROOTS[i]}/$name
    if [[ -L $link ]]; then
      link_real=$(realpath -e -- "$link" 2>/dev/null) ||
        skills_fail link-broken "$link" "broken skill link: $link"
      [[ $link_real == "$actual_real" ]] ||
        skills_fail link-foreign "$link" "skill link points to an unexpected target: $link"
    elif [[ -e $link ]]; then
      skills_fail link-not-symlink "$link" "skill link path is not a symlink: $link"
    elif ((SKILLS_CHECK_ONLY)); then
      skills_fail link-missing "$link" "skill link missing: $link"
    else
      mkdir -p -- "${SKILLS_LINK_ROOTS[i]}"
      ln -s -- "${SKILLS_LINK_PREFIXES[i]}${entry##*/}" "$link"
    fi
  done
}

# --- Copies ---------------------------------------------------------------

# _skills_staging_dir: a new private directory in <state>/staging.
_skills_staging_dir() {
  local staging_root
  staging_root="$(state_root)/staging"
  ensure_private_dir "$staging_root"
  mktemp -d "$staging_root/skill.XXXXXX"
}

# _skills_copy_tree SOURCE DESTINATION: the native copy (D2): metadata.json
# files and .git, __pycache__ and __pypackages__ directories are left out,
# symlinks are followed, each mode is the source mode & 0777. DESTINATION
# exists and is empty.
_skills_copy_tree() {
  local source=$1 destination=$2 list rel mode i
  local -a entries=() directories=()
  list=$(mktemp "${destination%/*}/list.XXXXXX")
  if ! (cd -- "$source" && find -L . -mindepth 1 \
    \( -type d \( -name .git -o -name __pycache__ -o -name __pypackages__ \) -prune \) \
    -o \( -type f -name metadata.json \) -o -print0) >"$list"; then
    rm -f -- "$list"
    skills_fail install-source-invalid "$source" "cannot list the skill source: $source"
  fi
  mapfile -d '' entries <"$list"
  rm -f -- "$list"
  for rel in "${entries[@]}"; do
    rel=${rel#./}
    if [[ -d $source/$rel ]]; then
      mkdir -- "$destination/$rel"
      directories+=("$rel")
    elif [[ -f $source/$rel ]]; then
      mode=$(stat -L -c %a -- "$source/$rel")
      cp -L -- "$source/$rel" "$destination/$rel"
      chmod "$(printf '%o' $((8#$mode & 8#777)))" -- "$destination/$rel"
    else
      skills_fail install-source-invalid "$source/$rel" \
        "skill source holds a broken link or a special file: $source/$rel"
    fi
  done
  # Directory modes last, so a read-only directory does not block its copy.
  for ((i = ${#directories[@]} - 1; i >= 0; i--)); do
    rel=${directories[i]}
    chmod "$(printf '%o' $((8#$(stat -L -c %a -- "$source/$rel") & 8#777)))" -- "$destination/$rel"
  done
  chmod "$(printf '%o' $((8#$(stat -L -c %a -- "$source") & 8#777)))" -- "$destination"
}

# _skills_install NAME DIRECTORY SOURCE: installs a missing copy-deployed
# skill with the [skills] installer argv, else the native copy into
# <canonical>/<directory>.
_skills_install() {
  local name=$1 directory=$2 source=$3 destination staging argument status=0
  local -a argv=()
  if ((${#DS_SKILLS_INSTALLER[@]})); then
    for argument in "${DS_SKILLS_INSTALLER[@]}"; do
      argument=${argument//\{source\}/$source}
      argument=${argument//\{name\}/$name}
      argument=${argument//\{home\}/$HOME}
      argv+=("$argument")
    done
    if [[ ${argv[0]} == */* ]]; then
      [[ -f ${argv[0]} && -x ${argv[0]} ]] ||
        skills_fail installer-missing "${argv[0]}" "skill installer not found: ${argv[0]}"
    else
      command -v -- "${argv[0]}" >/dev/null 2>&1 ||
        skills_fail installer-missing "${argv[0]}" "skill installer not found: ${argv[0]}"
    fi
    "${argv[@]}" </dev/null || status=$?
    ((status == 0)) || skills_fail installer-failed "$source" "skill installer failed: $name (exit $status)"
    return 0
  fi
  destination=$SKILLS_CANONICAL/$directory
  if [[ -e $destination || -L $destination ]]; then
    skills_fail install-destination-exists "$destination" "skill install destination exists: $destination"
  fi
  staging=$(_skills_staging_dir)
  _skills_copy_tree "$source" "$staging"
  mv -- "$staging" "$destination"
}

# _skills_refresh NAME PATH SOURCE DIGEST: replaces a drifted copy-deployed
# skill with the vendored copy, after a backup.
_skills_refresh() {
  local name=$1 path=$2 source=$3 expected=$4 real root root_real managed=0 backup_root staging
  real=$(realpath -e -- "$path" 2>/dev/null) ||
    skills_fail skill-unresolvable "$path" "cannot resolve the skill path: $path"
  [[ $(directory_sha256 "$real") != "$expected" ]] || return 0
  if ((SKILLS_CHECK_ONLY)); then
    skills_fail skill-drift "$real" \
      "installed skill differs from the lock: $name ($real); $(_skills_rebuild_hint) to back it up and refresh it"
  fi
  for root in "${SKILLS_MANAGED_ROOTS[@]}"; do
    root_real=$(realpath -e -- "$root" 2>/dev/null) || root_real=$root
    if [[ $real == "$root"/* || $real == "$root_real"/* ]]; then
      managed=1
    fi
  done
  if ((!managed)); then
    warn "skill outside the managed skill roots not refreshed: $name ($real)"
    return 0
  fi
  [[ -d $real && ! -L $real ]] || skills_fail skill-not-directory "$real" "skill is not a directory: $real"

  backup_root="$(state_root)/backups/$(timestamp_utc)-skills"
  ensure_private_dir "$backup_root"
  backup_file_private "$real" "$backup_root"
  # Staged on the state file system; the replacement is one rename when the
  # home shares it.
  staging=$(_skills_staging_dir)
  cp -a -- "$source/." "$staging/"
  chmod --reference="$real" -- "$staging"
  rm -rf -- "$real"
  mv -- "$staging" "$real"
  [[ $(directory_sha256 "$real") == "$expected" ]] ||
    skills_fail refresh-digest-mismatch "$real" "refreshed skill digest differs from the lock: $name ($real)"
  log "skill differed from the lock; backed up and refreshed: $name (backup: $backup_root)"
}

# --- Entries --------------------------------------------------------------

skills_framework_entries() {
  jq -c '(.skills.framework_manifest // null) as $manifest
    | (.skills.framework // [])[] as $name
    | { name: $name,
        entry: (if $manifest == null then null
                else first(($manifest.skills // [])[] | select(.name == $name)) // null end) }' \
    <<<"$DS_MANIFEST_JSON"
}

skills_instance_entries() {
  jq -c '.skills[]' "$SKILLS_LOCK"
}

skills_process_framework() {
  (($# == 2)) || die "usage: skills_process_framework NAME ENTRY_JSON"
  local name=$1 entry=$2 directory skill_sha directory_sha hm real expected generated canonical_entry
  [[ $entry != null ]] ||
    skills_fail framework-manifest-missing "$name" "framework skill $name is not in the framework skills manifest"
  directory=$(jq -r '.directory // .name' <<<"$entry")
  skill_sha=$(jq -r '.skill_sha256 // empty' <<<"$entry")
  directory_sha=$(jq -r '.directory_sha256 // empty' <<<"$entry")
  hm=$SKILLS_HM_ROOT/$directory
  if [[ ! -L $hm ]]; then
    if [[ -e $hm ]]; then
      skills_fail framework-skill-not-link "$hm" "framework skill is not a Home Manager link: $hm"
    fi
    skills_fail framework-skill-missing "$hm" "framework skill missing: $name ($hm); Home Manager activation links it"
  fi
  real=$(realpath -e -- "$hm" 2>/dev/null) ||
    skills_fail framework-skill-broken "$hm" "broken framework skill link: $hm"
  if [[ -z $SKILLS_GENERATION ]]; then
    skills_fail framework-skill-unverifiable "$hm" \
      "no Home Manager generation to verify framework skill $name against; pass --generation"
  fi
  generated=$SKILLS_GENERATION/home-files/$SKILLS_HM_ROOT_REL/$directory
  expected=$(realpath -e -- "$generated" 2>/dev/null) ||
    skills_fail framework-skill-not-in-generation "$hm" "the generation has no framework skill $name: $generated"
  [[ $real == "$expected" ]] ||
    skills_fail framework-skill-foreign "$hm" "framework skill does not resolve to the generation's framework source: $hm"
  if [[ ! -f $real/SKILL.md || $(sha256_file "$real/SKILL.md") != "$skill_sha" ||
    $(directory_sha256 "$real") != "$directory_sha" ]]; then
    skills_fail framework-skill-digest-mismatch "$hm" \
      "framework skill digest differs from the framework skills manifest: $name ($hm)"
  fi
  canonical_entry=$(skills_canonical_entry "$hm")
  _skills_link_roots "$name" "$canonical_entry"
}

skills_process_instance() {
  (($# == 1)) || die "usage: skills_process_instance ENTRY_JSON"
  local entry=$1 name directory legacy skill_sha directory_sha deployment source found hm canonical_entry
  local -a fields=()
  mapfile -d '' fields < <(jq -j '[.name, .directory, (.legacy_directory // ""), .skill_sha256,
    (.directory_sha256 // ""), (.deployment // "copy")] | map(. + "\u0000") | add' <<<"$entry")
  name=${fields[0]}
  directory=${fields[1]}
  legacy=${fields[2]}
  skill_sha=${fields[3]}
  directory_sha=${fields[4]}
  deployment=${fields[5]}
  source=$SKILLS_VENDOR/$directory
  hm=$SKILLS_HM_ROOT/$directory

  [[ -f $source/SKILL.md && ! -L $source/SKILL.md ]] ||
    skills_fail source-missing "$source" "skill source missing: $name ($source)"
  [[ $(sha256_file "$source/SKILL.md") == "$skill_sha" ]] ||
    skills_fail source-digest-mismatch "$source/SKILL.md" "skill source digest differs from the lock: $name ($source/SKILL.md)"
  if [[ -n $directory_sha && $(directory_sha256 "$source") != "$directory_sha" ]]; then
    skills_fail source-digest-mismatch "$source" "skill source digest differs from the lock: $name ($source)"
  fi

  found=$(skills_find_existing "$directory" "$legacy")
  if [[ -z $found ]]; then
    if [[ $deployment == home-manager ]]; then
      skills_fail home-managed-missing "$hm" "home-managed skill missing: $name ($hm); Home Manager activation links it"
    fi
    if ((SKILLS_CHECK_ONLY)); then
      skills_fail skill-missing "$SKILLS_CANONICAL/$directory" \
        "skill missing: $name; $(_skills_rebuild_hint) to install it"
    fi
    _skills_install "$name" "$directory" "$source"
    found=$(skills_find_existing "$directory" "$legacy")
    [[ -n $found ]] || skills_fail install-unverified "$SKILLS_CANONICAL/$directory" "skill install could not be verified: $name"
    log "installed skill $name into $found"
    if [[ -n $directory_sha && $(directory_sha256 "$(realpath -e -- "$found")") != "$directory_sha" ]]; then
      skills_fail install-digest-mismatch "$found" \
        "installed skill digest differs from the lock: $name ($found); the native copy leaves out metadata.json, .git, __pycache__ and __pypackages__ and follows symlinks"
    fi
  elif [[ $deployment != home-manager && -n $directory_sha ]]; then
    _skills_refresh "$name" "$found" "$source" "$directory_sha"
  fi

  canonical_entry=$(skills_canonical_entry "$found")
  if [[ $deployment == home-manager ]]; then
    [[ -L $hm ]] || skills_fail home-managed-not-link "$hm" "home-managed skill is not a Home Manager link: $name ($hm)"
    if [[ -n $directory_sha && $(directory_sha256 "$canonical_entry") != "$directory_sha" ]]; then
      skills_fail home-managed-digest-mismatch "$hm" "home-managed skill digest differs from the lock: $name ($hm)"
    fi
  fi
  _skills_link_roots "$name" "$canonical_entry"
}

# --- Sweep ----------------------------------------------------------------

skills_sweep() {
  local root link target prefix managed failed=0
  local -a links=()
  for root in "$SKILLS_CANONICAL" "${SKILLS_LINK_ROOTS[@]}"; do
    [[ -d $root ]] || continue
    mapfile -d '' links < <(find "$root" -mindepth 1 -maxdepth 1 -xtype l -print0 | LC_ALL=C sort -z)
    for link in "${links[@]}"; do
      target=$(readlink -- "$link")
      managed=0
      for prefix in "${SKILLS_SWEEP_PREFIXES[@]}"; do
        if [[ $target == "$prefix"?* ]]; then
          managed=1
          break
        fi
      done
      ((managed)) || continue
      if ((SKILLS_CHECK_ONLY)); then
        skills_finding dangling-link "$link" "dangling skill link not removed: $link"
        ((SKILLS_KEEP_GOING)) || exit 1
        failed=1
        continue
      fi
      unlink -- "$link"
      log "removed dangling skill link: $link"
    done
  done
  ((failed == 0)) || exit 1
}
