# shellcheck shell=bash
# The skill layout engine of `dotsteward agents`: the canonical skill root,
# the legacy roots, the framework and instance skills and the sweep of
# dangling links. Source after
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
# Scoped skills. A lock entry with agents = [AGENT, ...] is for those agents
# only: it is copied into the scoped skill store
# ${XDG_DATA_HOME:-~/.local/share}/dotsteward/scoped-skills/<directory>
# (never into the canonical root or a link root) and linked from the skill
# root of each named agent (manifest skill_layout.agent_roots, AGENT ->
# root, contributed by components; a root only that agent reads):
# <agent root>/<name> -> <store>/<directory>, an absolute link. Scoped
# skills always use the native copy.
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
#       the instance skills lock: a regular file, schema_version "1.0"
#       (expected_skill_count, a copy of the number of entries that older
#       instances carry, is ignored), each entry with name,
#       directory (a plain name) and skill_sha256, optional
#       legacy_directory, directory_sha256, deployment (copy, the
#       default, or home-manager) and agents (a non-empty list of unique
#       plain agent names, copy deployment only); no dotsteward-* name
#       (framework skills are never instance lock entries); optional
#       own_plugins, a list of entries with name, directory (a plain name)
#       and directory_sha256, optional agents (a non-empty list of plain
#       agent names) and machines
#   skills_ensure_layout
#       install: creates ~/.agents and every legacy root; a canonical root
#       that is a link to a legacy root is migrated to a directory. Both
#       modes: every legacy root is a real directory, the canonical root
#       is a directory, no excluded subtree is in it.
#   skills_framework_entries, skills_instance_entries
#       one compact JSON object per line: the framework skills of the
#       manifest ({name, entry}, entry from skills.framework_manifest or
#       null) and the instance lock entries this machine does not leave out
#       (DS_SKIP_SKILLS_JSON without DS_DELETED_SKILLS_JSON), in file order
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
#       or the [skills] installer argv, after a dangling link at
#       <canonical>/<directory> whose literal target is in a managed root
#       (what the sweep removes) is removed; any other existing
#       destination is refused. Present copy skills with a
#       directory digest are refreshed when they differ (check: fatal).
#       Home-managed skills must be links with the lock digest. Then the
#       canonical entry and the link-root links. A scoped entry (agents)
#       is searched, installed and refreshed in the scoped store only, is
#       refused when it is also in a shared root or names an agent
#       without a skill root, and gets one link per named agent root.
#       An own skill (a repo-owned sentinel revision, copy deployment) is
#       different: dotsteward_cli.skills.threeway decides whether it is
#       refreshed at all, a difference is a note and never a finding, a real
#       directory in a link root moves to the canonical root (install) or is
#       a note (check), and a missing entry or link is a note for check.
#   skills_own_plugin_entries, skills_process_own_plugin ENTRY_JSON
#       the own plugins of the lock this machine does not leave out
#       (DS_SKIP_PLUGINS_JSON), one compact JSON object per line; and one of
#       them: a plugin of Claude Code (agents names claude) lives as a real
#       directory <claude-code link root>/<directory> (~/.claude/skills,
#       where Claude Code loads it as <name>@skills-dir), copied from
#       agent/plugins/<directory>, whose digest is verified against the lock
#       first. A plugin of Codex (agents names codex) lives in
#       ${CODEX_HOME:-~/.codex}/plugins/<directory> with the codex component,
#       is offered by the marketplace dotsteward-own of dotsteward (never the
#       personal marketplace of the user) and added with `codex plugin add`
#       (_skills_codex_plugin).
#       dotsteward_cli.skills.threeway decides about the copy as for an
#       own skill (records plugin:<name>): a missing one is installed, a
#       local change is never overwritten, a deleted one is not installed
#       again. Without the root of its agent it is a note.
#   skills_sweep
#       removes (install) or reports (check) every dangling link directly
#       in the canonical root, the link roots and the agent roots whose
#       literal target is in a managed root or the scoped store (relative ../../<root>/... or $HOME/<root>/...,
#       or a link-root target prefix); other links stay; check only notes the
#       dangling link of an own skill
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
#     agent-root-unknown, scoped-skill-shared,
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
SKILLS_AGENT_NAMES=()
SKILLS_AGENT_ROOTS=()
SKILLS_SCOPED_STORE=''
# Set while an own skill is laid out: what is missing is a note for check.
SKILLS_SOFT_LAYOUT=0
# What an own copy is (skill or plugin), and the file that says a copy is there.
SKILLS_OWN_KIND=skill
SKILLS_OWN_MARKER=SKILL.md
# The skill root of Claude Code, where own plugins live; empty without it.
SKILLS_PLUGIN_ROOT=''
# ${CODEX_HOME:-~/.codex}/plugins with the codex component, where own plugins of Codex live.
SKILLS_CODEX_PLUGIN_ROOT=''

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

  SKILLS_PLUGIN_ROOT=$(jq -r 'first((.skill_layout.link_roots // {}) | to_entries[]
    | select(.value.component == "claude-code") | .key) // empty' <<<"$DS_MANIFEST_JSON")
  if [[ -n $SKILLS_PLUGIN_ROOT ]]; then
    SKILLS_PLUGIN_ROOT=$(_skills_expand "$SKILLS_PLUGIN_ROOT") || exit 1
  fi
  SKILLS_CODEX_PLUGIN_ROOT=''
  if jq -e '(.components // []) | any(.name == "codex")' >/dev/null <<<"$DS_MANIFEST_JSON"; then
    SKILLS_CODEX_PLUGIN_ROOT=${CODEX_HOME:-$HOME/.codex}
    SKILLS_CODEX_PLUGIN_ROOT=${SKILLS_CODEX_PLUGIN_ROOT%/}/plugins
  fi

  SKILLS_AGENT_NAMES=()
  SKILLS_AGENT_ROOTS=()
  while IFS= read -r -d '' prefix && IFS= read -r -d '' root; do
    root=$(_skills_expand "$root") || exit 1
    SKILLS_AGENT_NAMES+=("$prefix")
    SKILLS_AGENT_ROOTS+=("$root")
  done < <(jq -j '(.skill_layout.agent_roots // {}) | to_entries | sort_by(.key)[] | .key, "\u0000", .value, "\u0000"' \
    <<<"$DS_MANIFEST_JSON")
  SKILLS_SCOPED_STORE=${XDG_DATA_HOME:-$HOME/.local/share}
  SKILLS_SCOPED_STORE=${SKILLS_SCOPED_STORE%/}/dotsteward/scoped-skills

  SKILLS_EXCLUDED=()
  while IFS= read -r -d '' root; do
    [[ -n $root && $root != /* && /$root/ != */../* ]] || die "invalid excluded skill subtree: $root"
    SKILLS_EXCLUDED+=("${root%/}")
  done < <(jq -j '(.skill_layout.excluded_subtrees // [])[] | ., "\u0000"' <<<"$DS_MANIFEST_JSON")

  SKILLS_SEARCH_ROOTS=("$SKILLS_CANONICAL" "${SKILLS_LEGACY_ROOTS[@]}")
  _skills_contains "$SKILLS_HM_ROOT" "${SKILLS_SEARCH_ROOTS[@]}" || SKILLS_SEARCH_ROOTS+=("$SKILLS_HM_ROOT")
  SKILLS_MANAGED_ROOTS=("$SKILLS_CANONICAL" "${SKILLS_LEGACY_ROOTS[@]}" "$SKILLS_SCOPED_STORE")

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
  SKILLS_SWEEP_PREFIXES+=("$SKILLS_SCOPED_STORE/")

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
           else "skill \($s.name): unknown deployment \($s.deployment)" end),
          (if $s.agents == null then empty
           elif ($s.agents | type) != "array" or ($s.agents | length) == 0
             or ($s.agents | all(plain) | not) or ($s.agents | unique | length) != ($s.agents | length) then
             "skill \($s.name): agents must be a non-empty list of plain agent names"
           elif ($s.deployment // "copy") != "copy" then "skill \($s.name): agents needs the copy deployment"
           else empty end)
        end),
     (if all(.skills[]; type == "object") then
        (.skills | map(.name) | group_by(.) | map(select(length > 1) | .[0])[]
          | "skill \(.) is listed more than once"),
        (.skills | map(.directory) | group_by(.) | map(select(length > 1) | .[0])[]
          | "directory \(.) is used by more than one skill")
      else empty end)
   end),
  (if .own_plugins == null then empty
   elif (.own_plugins | type) != "array" then "own_plugins is not a list"
   else
     (.own_plugins | to_entries[] | .key as $i | .value as $p
      | if ($p | type) != "object" or ([$p.name, $p.directory, $p.directory_sha256] | all(nonempty) | not) then
          "own plugin \($i + 1): name, directory and directory_sha256 must be non-empty strings"
        elif ($p.directory | plain) | not then "own plugin \($p.name): directory must be a plain directory name"
        elif $p.agents != null and (($p.agents | type) != "array" or ($p.agents | length) == 0
          or ($p.agents | all(plain) | not)) then
          "own plugin \($p.name): agents must be a non-empty list of plain agent names"
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
    if ((SKILLS_SOFT_LAYOUT)); then
      _skills_placement_note "canonical skill entry missing: $link"
      printf '%s\n' "$path"
      return 0
    fi
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

# _skills_link LINK TARGET ACTUAL_REAL: LINK must be a symlink resolving to
# ACTUAL_REAL; a missing one is created (install) with the literal TARGET.
_skills_link() {
  local link=$1 target=$2 actual_real=$3 link_real
  if [[ -L $link ]]; then
    link_real=$(realpath -e -- "$link" 2>/dev/null) ||
      skills_fail link-broken "$link" "broken skill link: $link"
    [[ $link_real == "$actual_real" ]] ||
      skills_fail link-foreign "$link" "skill link points to an unexpected target: $link"
  elif [[ -e $link ]]; then
    if ((SKILLS_SOFT_LAYOUT)); then
      _skills_placement_note "skill link path is not a symlink: $link"
      return 0
    fi
    skills_fail link-not-symlink "$link" "skill link path is not a symlink: $link"
  elif ((SKILLS_CHECK_ONLY)); then
    if ((SKILLS_SOFT_LAYOUT)); then
      _skills_placement_note "skill link missing: $link"
      return 0
    fi
    skills_fail link-missing "$link" "skill link missing: $link"
  else
    mkdir -p -- "${link%/*}"
    ln -s -- "$target" "$link"
  fi
}

# _skills_link_roots NAME ENTRY: <link root>/NAME -> <prefix><entry name>.
_skills_link_roots() {
  local name=$1 entry=$2 actual_real link i
  actual_real=$(realpath -e -- "$entry" 2>/dev/null) ||
    skills_fail skill-unresolvable "$entry" "cannot resolve the skill path: $entry"
  for i in "${!SKILLS_LINK_ROOTS[@]}"; do
    link=${SKILLS_LINK_ROOTS[i]}/$name
    _skills_link "$link" "${SKILLS_LINK_PREFIXES[i]}${entry##*/}" "$actual_real"
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

# _skills_copy_tree SOURCE DESTINATION: the native copy: metadata.json
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

# _skills_install NAME DIRECTORY SOURCE [ROOT]: installs a missing
# copy-deployed skill with the [skills] installer argv, else the native copy
# into <canonical>/<directory>; with ROOT (the scoped store) always the
# native copy into ROOT/<directory>.
_skills_install() {
  local name=$1 directory=$2 source=$3 root=${4:-} destination staging argument status=0
  local -a argv=()
  destination=${root:-$SKILLS_CANONICAL}/$directory
  # A dangling managed link here is what the sweep removes; it would block
  # the copy (or let an installer write through it) before the sweep runs.
  if [[ -L $destination && ! -e $destination ]] && _skills_is_managed_target "$(readlink -- "$destination")"; then
    unlink -- "$destination"
    log "removed dangling skill link: $destination"
  fi
  if [[ -z $root ]] && ((${#DS_SKILLS_INSTALLER[@]})); then
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
  if [[ -e $destination || -L $destination ]]; then
    skills_fail install-destination-exists "$destination" "skill install destination exists: $destination"
  fi
  staging=$(_skills_staging_dir)
  _skills_copy_tree "$source" "$staging"
  mkdir -p -- "${destination%/*}"
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

# _skills_refresh_third_party NAME PATH SOURCE DIGEST: _skills_refresh, unless this machine has a
# named copy that never was a pin of the lock: something of the user's under a name another
# machine brought. It stays, and `dotsteward incoming` asks.
_skills_refresh_third_party() {
  local name=$1 path=$2 expected=$4 real digest mode=install answer
  if [[ -n ${DS_MACHINE_NAME:-} ]] && real=$(realpath -e -- "$path" 2>/dev/null); then
    digest=$(directory_sha256 "$real")
    if [[ $digest != "$expected" ]]; then
      ((SKILLS_CHECK_ONLY)) && mode=check
      answer=$(ds_python dotsteward_cli.incoming clash --name "$name" --digest "$digest" --path "$real" --mode "$mode") ||
        skills_fail skill-unresolvable "$real" "cannot read the skill $name ($real)"
      if [[ $answer == clash ]]; then
        log "skill $name: a copy here has this name and never was in the lock; it stays until 'dotsteward incoming' has an answer"
        return 0
      fi
    fi
  fi
  _skills_refresh "$@"
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

skills_own_plugin_entries() {
  jq -c --argjson skip "${DS_SKIP_PLUGINS_JSON:-[]}" \
    '(.own_plugins // [])[] | select(.name as $name | $skip | index($name) | not)' "$SKILLS_LOCK"
}

skills_process_own_plugin() {
  (($# == 1)) || die "usage: skills_process_own_plugin ENTRY_JSON"
  local entry=$1 name directory digest agents source found decision root manifest
  local -a fields=()
  mapfile -d '' fields < <(jq -j '[.name, (.directory // .name), (.directory_sha256 // ""),
    ((.agents // ["claude"]) | join(" "))] | map(. + "\u0000") | add' <<<"$entry")
  name=${fields[0]}
  directory=${fields[1]}
  digest=${fields[2]}
  agents=${fields[3]}
  source=$DS_INSTANCE_ROOT/agent/plugins/$directory
  case $agents in
    claude)
      root=$SKILLS_PLUGIN_ROOT
      manifest=.claude-plugin/plugin.json
      [[ -n $root ]] || {
        log "own plugin $name: this profile has no skill root of claude-code; not installed"
        return 0
      }
      ;;
    codex)
      root=$SKILLS_CODEX_PLUGIN_ROOT
      manifest=.codex-plugin/plugin.json
      [[ -f $source/$manifest ]] || manifest=plugin.json
      [[ -n $root ]] || {
        log "own plugin $name: this profile has no codex component; not installed"
        return 0
      }
      ;;
    *)
      log "own plugin $name is for ${agents// /, }: an own plugin is for claude or for codex"
      return 0
      ;;
  esac
  [[ -f $source/$manifest && ! -L $source/$manifest ]] ||
    skills_fail source-missing "$source" "plugin source missing: $name ($source)"
  [[ $(directory_sha256 "$source") == "$digest" ]] ||
    skills_fail source-digest-mismatch "$source" "plugin source digest differs from the lock: $name ($source)"
  SKILLS_SOFT_LAYOUT=1
  SKILLS_OWN_KIND=plugin
  SKILLS_OWN_MARKER=$manifest
  # The plugin root is where this copy lives: a refresh of an incoming one may replace it.
  SKILLS_MANAGED_ROOTS+=("$root")
  found=$root/$directory
  if [[ -e $found && ! -f $found/$SKILLS_OWN_MARKER ]]; then
    # Something of this machine holds the name, a skill most likely: it stays.
    _skills_placement_note "own plugin $name: $found is no plugin and stays; the plugin is not installed (name-taken, see 'dotsteward skills status')"
    return 0
  fi
  if [[ -L $found ]]; then
    # A copy linked from elsewhere: compared by its content, never refreshed through the link.
    _skills_placement_note "own plugin $name: $found is a link to $(readlink -- "$found"); its content is compared, it is never replaced"
  fi
  [[ -f $found/$SKILLS_OWN_MARKER ]] || found=''
  decision=$(_skills_own_decision "$name" "$found" "$digest")
  ((SKILLS_CHECK_ONLY)) || mkdir -p -- "$root"
  _skills_own_apply "$name" "$directory" "$found" "$decision" "$digest" "$source" "$root"
  if [[ $agents == codex && -n $SKILLS_OWN_COPY ]]; then
    _skills_codex_plugin "$name" "$SKILLS_OWN_COPY" "$decision"
  fi
}

# _skills_codex_plugin NAME COPY DECISION: Codex runs a plugin from a marketplace, and the
# copy in its cache. dotsteward offers own plugins through a marketplace of its own,
# ${XDG_DATA_HOME:-~/.local/share}/dotsteward/codex-marketplace (.agents/plugins/marketplace.json
# named dotsteward-own, plugins/NAME a link to COPY); the personal marketplace of the user is
# never touched. A plugin a marketplace of the user installed from COPY is left to it.
# Install adds the marketplace once (`codex plugin marketplace add`) and runs `codex plugin
# add NAME@dotsteward-own` when Codex does not list it installed and enabled, and after a
# copy that changed (missing, incoming), which refreshes the cache. What cannot be done is a
# note: an own plugin never fails a check.
SKILLS_CODEX_MARKET=dotsteward-own
_skills_codex_plugin() {
  local name=$1 copy=$2 decision=$3 root market_file link listed spec updated tmp real
  root=${XDG_DATA_HOME:-$HOME/.local/share}
  root=${root%/}/dotsteward/codex-marketplace
  market_file=$root/.agents/plugins/marketplace.json
  link=$root/plugins/$name
  spec=$name@$SKILLS_CODEX_MARKET
  if ! command -v codex >/dev/null 2>&1; then
    _skills_placement_note "own plugin $name: no codex on PATH to add $spec"
    return 0
  fi
  listed=$(codex plugin list --json 2>/dev/null) || listed=''
  real=$(realpath -e -- "$copy" 2>/dev/null) || real=$copy
  # shellcheck disable=SC2016 # a jq program
  if jq -e --arg spec "$spec" --arg real "$real" --arg copy "$copy" 'any((.installed // [])[];
      .pluginId != $spec and .installed != false and .source.source == "local"
      and (.source.path == $real or .source.path == $copy))' >/dev/null 2>&1 <<<"$listed"; then
    log "own plugin $name: Codex has it from a marketplace of the user; left to it"
    return 0
  fi
  if [[ $(readlink -- "$link" 2>/dev/null) != "$copy" ]] ||
    ! jq -e --arg name "$name" 'any((.plugins // [])[]; .name == $name)' "$market_file" >/dev/null 2>&1; then
    if ((SKILLS_CHECK_ONLY)); then
      _skills_placement_note "own plugin $name is not offered to Codex yet ($market_file); $(_skills_rebuild_hint)"
      return 0
    fi
    mkdir -p -- "$root/plugins" "${market_file%/*}"
    ln -sfn -- "$copy" "$link"
    [[ -f $market_file ]] || printf '{"name": "%s", "plugins": []}\n' "$SKILLS_CODEX_MARKET" >"$market_file"
    # shellcheck disable=SC2016 # a jq program
    updated=$(jq --arg market "$SKILLS_CODEX_MARKET" --arg name "$name" '.name = $market
      | .plugins = ([(.plugins // [])[] | select(.name != $name)]
        + [{name: $name, source: {source: "local", path: ("./plugins/" + $name)}, policy: {installation: "AVAILABLE"}}])' \
      "$market_file")
    tmp=$(mktemp "$market_file.XXXXXX")
    printf '%s\n' "$updated" >"$tmp"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$market_file"
    log "own plugin $name: offered to Codex by the marketplace $SKILLS_CODEX_MARKET ($root)"
    decision=missing
  fi
  # shellcheck disable=SC2016 # a jq program
  if ! codex plugin marketplace list --json 2>/dev/null |
    jq -e --arg market "$SKILLS_CODEX_MARKET" 'any((.marketplaces // [])[]; .name == $market)' >/dev/null 2>&1; then
    if ((SKILLS_CHECK_ONLY)); then
      _skills_placement_note "the marketplace $SKILLS_CODEX_MARKET is not added to Codex; $(_skills_rebuild_hint)"
      return 0
    fi
    log "own plugin $name: codex plugin marketplace add $root"
    codex plugin marketplace add "$root" >/dev/null ||
      _skills_placement_note "own plugin $name: codex plugin marketplace add $root failed"
  fi
  if [[ $decision != missing && $decision != incoming ]] &&
    jq -e --arg spec "$spec" 'any((.installed // [])[]; .pluginId == $spec and .installed != false and .enabled == true)' \
      >/dev/null 2>&1 <<<"$listed"; then
    return 0
  fi
  if ((SKILLS_CHECK_ONLY)); then
    _skills_placement_note "codex plugin $spec is not installed and enabled; $(_skills_rebuild_hint)"
    return 0
  fi
  log "own plugin $name: codex plugin add $spec"
  codex plugin add "$spec" >/dev/null || _skills_placement_note "own plugin $name: codex plugin add $spec failed"
}

skills_instance_entries() {
  # An own skill deleted here stays: its decision says so, and removes its links.
  jq -c --argjson skip "${DS_SKIP_SKILLS_JSON:-[]}" --argjson deleted "${DS_DELETED_SKILLS_JSON:-[]}" \
    '($skip - $deleted) as $left | .skills[] | select(.name as $name | $left | index($name) | not)' "$SKILLS_LOCK"
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
  local entry=$1 name directory legacy skill_sha directory_sha deployment agents revision source found hm canonical_entry
  local -a fields=()
  mapfile -d '' fields < <(jq -j '[.name, .directory, (.legacy_directory // ""), .skill_sha256,
    (.directory_sha256 // ""), (.deployment // "copy"), ((.agents // []) | join(" ")),
    (.revision // "" | tostring)]
    | map(. + "\u0000") | add' <<<"$entry")
  name=${fields[0]}
  directory=${fields[1]}
  legacy=${fields[2]}
  skill_sha=${fields[3]}
  directory_sha=${fields[4]}
  deployment=${fields[5]}
  agents=${fields[6]}
  revision=${fields[7]}
  source=$SKILLS_VENDOR/$directory
  hm=$SKILLS_HM_ROOT/$directory

  [[ -f $source/SKILL.md && ! -L $source/SKILL.md ]] ||
    skills_fail source-missing "$source" "skill source missing: $name ($source)"
  [[ $(sha256_file "$source/SKILL.md") == "$skill_sha" ]] ||
    skills_fail source-digest-mismatch "$source/SKILL.md" "skill source digest differs from the lock: $name ($source/SKILL.md)"
  if [[ -n $directory_sha && $(directory_sha256 "$source") != "$directory_sha" ]]; then
    skills_fail source-digest-mismatch "$source" "skill source digest differs from the lock: $name ($source)"
  fi
  if [[ -n $agents ]]; then
    _skills_process_scoped "$name" "$directory" "$directory_sha" "$source" "$agents" "$revision"
    return 0
  fi
  if [[ $deployment != home-manager ]] && _skills_is_own "$revision"; then
    _skills_process_own "$name" "$directory" "$legacy" "$directory_sha" "$source"
    return 0
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
    _skills_refresh_third_party "$name" "$found" "$source" "$directory_sha"
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

# --- Own skills -----------------------------------------------------------

# _skills_is_own REVISION: whether a lock revision marks the user's own skill.
_skills_is_own() {
  [[ $1 == same-as-instance-checkout || (-n ${DS_COMPAT_REPO_OWNED_REVISION:-} && $1 == "$DS_COMPAT_REPO_OWNED_REVISION") ]]
}

# _skills_placement_note MESSAGE: a difference in the layout of an own skill,
# which `agents install` puts right. It goes to standard error: the callers
# print their answer on standard output.
_skills_placement_note() {
  printf '[dotsteward] placement of an own skill: %s\n' "$*" >&2
}

# _skills_threeway ACTION ARG...: dotsteward_cli.skills.threeway for this
# instance and this state root.
_skills_threeway() {
  local action=$1
  shift
  ds_python dotsteward_cli.skills.threeway "$action" --instance "$DS_INSTANCE_ROOT" --state-root "$(state_root)" \
    --kind "$SKILLS_OWN_KIND" "$@"
}

# _skills_incoming_waits NAME: another machine changed the own skill NAME and this
# machine has not answered (dotsteward incoming).
_skills_incoming_waits() {
  jq -e --arg name "$1" 'index($name) != null' <<<"${DS_INCOMING_SKILLS_JSON:-[]}" >/dev/null
}

# _skills_own_note NAME DECISION: says why an own skill stays as it is.
_skills_own_note() {
  local name=$1
  case $2 in
    behind) log "$SKILLS_OWN_KIND $name: behind: the copy is ahead of the lock of this checkout; left as it is" ;;
    pending-capture) log "$SKILLS_OWN_KIND $name: pending-capture: a local change waits for a capture; left as it is" ;;
    incoming)
      if [[ $SKILLS_OWN_KIND == skill ]] && _skills_incoming_waits "$name"; then
        log "$SKILLS_OWN_KIND $name: incoming: another machine changed it; the copy stays until 'dotsteward incoming' has an answer"
      elif ((SKILLS_CHECK_ONLY)); then
        log "$SKILLS_OWN_KIND $name: incoming: the lock has a newer copy; $(_skills_rebuild_hint) to take it"
      fi
      ;;
    conflict) log "$SKILLS_OWN_KIND $name: conflict: the copy and the lock both changed; left as it is; see 'dotsteward skills status'" ;;
    deleted) log "$SKILLS_OWN_KIND $name: deleted: not installed again; see 'dotsteward skills status'" ;;
  esac
}

# _skills_own_decision NAME FOUND DIGEST: the decision of an own skill on
# standard output.
_skills_own_decision() {
  local mode=install
  ((SKILLS_CHECK_ONLY)) && mode=check
  _skills_threeway decide --name "$1" --found "$2" --digest "$3" --mode "$mode" ||
    skills_fail skill-unresolvable "${2:-$1}" "cannot read the own skill $1 (${2:-no copy})"
}

# _skills_own_apply NAME DIRECTORY FOUND DECISION DIGEST SOURCE [ROOT]: says and
# does what a decision asks for; SKILLS_OWN_COPY is the copy afterwards, empty
# when there is none. ROOT: the scoped store, instead of the canonical root.
SKILLS_OWN_COPY=''
_skills_own_apply() {
  local name=$1 directory=$2 found=$3 decision=$4 digest=$5 source=$6 root=${7:-} installed kept refreshed
  SKILLS_OWN_COPY=$found
  _skills_own_note "$name" "$decision"
  case $decision in
    missing)
      if ((SKILLS_CHECK_ONLY)); then
        skills_fail skill-missing "${root:-$SKILLS_CANONICAL}/$directory" \
          "$SKILLS_OWN_KIND missing: $name; $(_skills_rebuild_hint) to install it"
      fi
      _skills_install "$name" "$directory" "$source" "$root"
      installed=${root:-$SKILLS_CANONICAL}/$directory
      [[ -f $installed/$SKILLS_OWN_MARKER ]] ||
        skills_fail install-unverified "$installed" "$SKILLS_OWN_KIND install could not be verified: $name"
      log "installed $SKILLS_OWN_KIND $name into $installed"
      if [[ $(directory_sha256 "$(realpath -e -- "$installed")") != "$digest" ]]; then
        skills_fail install-digest-mismatch "$installed" \
          "installed skill digest differs from the lock: $name ($installed); the native copy leaves out metadata.json, .git, __pycache__ and __pypackages__ and follows symlinks"
      fi
      _skills_threeway record --name "$name" --found "$installed" --digest "$digest"
      SKILLS_OWN_COPY=$installed
      ;;
    incoming)
      if ((!SKILLS_CHECK_ONLY)) && ! _skills_incoming_waits "$name"; then
        # What the repository cannot bring back stays in the live skill. b moves only
        # for a copy that took the new one: a link out of the skill roots does not.
        kept=$(_skills_staging_dir)
        _skills_threeway keep --name "$name" --found "$found" --digest "$digest" --kept "$kept" ||
          skills_fail skill-unresolvable "$found" "cannot read the own skill $name ($found)"
        _skills_refresh "$name" "$found" "$source" "$digest"
        refreshed=$(_skills_threeway refreshed --name "$name" --found "$found" --digest "$digest" --kept "$kept") ||
          skills_fail skill-unresolvable "$found" "cannot read the own skill $name ($found)"
        rm -rf -- "$kept"
        [[ $refreshed == in-sync ]] ||
          log "$SKILLS_OWN_KIND $name: conflict: this copy did not take what the repository holds; left as it is; see 'dotsteward skills status'"
      fi
      ;;
  esac
}

# _skills_in_link_root NAME DIRECTORY: the real directory of a skill in a link
# root, which is where an agent writes a new skill, under the name of the lock
# or of its directory; nothing else counts there.
_skills_in_link_root() {
  local root candidate
  for root in "${SKILLS_LINK_ROOTS[@]}"; do
    for candidate in "$1" "$2"; do
      if [[ ! -L $root/$candidate && -f $root/$candidate/SKILL.md ]]; then
        printf '%s\n' "$root/$candidate"
        return 0
      fi
    done
  done
}

# _skills_process_own NAME DIRECTORY LEGACY DIGEST SOURCE: an own skill.
_skills_process_own() {
  local name=$1 directory=$2 legacy=$3 digest=$4 source=$5 found decision destination placed=0 entry
  SKILLS_SOFT_LAYOUT=1
  [[ -n $digest ]] || digest=$(directory_sha256 "$source")
  found=$(skills_find_existing "$directory" "$legacy")
  if [[ -z $found ]]; then
    found=$(_skills_in_link_root "$name" "$directory")
    if [[ -n $found ]]; then
      destination=$SKILLS_CANONICAL/$directory
      if ((SKILLS_CHECK_ONLY)); then
        _skills_placement_note "$found moves to $destination; $(_skills_rebuild_hint)"
        placed=1
      else
        if [[ -L $destination && ! -e $destination ]] && _skills_is_managed_target "$(readlink -- "$destination")"; then
          unlink -- "$destination"
        fi
        [[ ! -e $destination && ! -L $destination ]] ||
          skills_fail install-destination-exists "$destination" "skill install destination exists: $destination"
        mkdir -p -- "${destination%/*}"
        mv -- "$found" "$destination"
        log "moved skill $name from $found to $destination"
        found=$destination
      fi
    fi
  fi
  decision=$(_skills_own_decision "$name" "$found" "$digest")
  _skills_own_apply "$name" "$directory" "$found" "$decision" "$digest" "$source"
  [[ -n $SKILLS_OWN_COPY ]] || return 0
  ((!placed)) || return 0
  entry=$(skills_canonical_entry "$SKILLS_OWN_COPY")
  _skills_link_roots "$name" "$entry"
}

# _skills_process_scoped NAME DIRECTORY DIGEST SOURCE AGENTS REVISION: a scoped
# skill (AGENTS space-separated): the copy <store>/<directory>, installed or
# refreshed like a shared copy (an own skill: as its decision says), and
# <agent root>/NAME -> that copy for each agent.
_skills_process_scoped() {
  local name=$1 directory=$2 directory_sha=$3 source=$4 agents=$5 revision=${6:-} agent root found real i known decision
  local -a roots=() names=()
  read -r -a names <<<"$agents"
  for agent in "${names[@]}"; do
    root=''
    for i in "${!SKILLS_AGENT_NAMES[@]}"; do
      [[ ${SKILLS_AGENT_NAMES[i]} == "$agent" ]] && root=${SKILLS_AGENT_ROOTS[i]}
    done
    if [[ -z $root ]]; then
      known=$(IFS=,; printf '%s' "${SKILLS_AGENT_NAMES[*]}")
      known=${known//,/, }
      skills_fail agent-root-unknown "$name" \
        "skill $name names the agent $agent, which has no skill root (known: ${known:-none})"
    fi
    roots+=("$root")
  done
  for root in "${SKILLS_SEARCH_ROOTS[@]}"; do
    if [[ -f $root/$directory/SKILL.md ]]; then
      skills_fail scoped-skill-shared "$root/$directory" \
        "skill $name is for ${agents// /, } only but is also in the shared skill root: $root/$directory; remove it there"
    fi
  done

  found=$SKILLS_SCOPED_STORE/$directory
  if _skills_is_own "$revision"; then
    SKILLS_SOFT_LAYOUT=1
    [[ -n $directory_sha ]] || directory_sha=$(directory_sha256 "$source")
    [[ -f $found/SKILL.md ]] || found=''
    decision=$(_skills_own_decision "$name" "$found" "$directory_sha")
    _skills_own_apply "$name" "$directory" "$found" "$decision" "$directory_sha" "$source" "$SKILLS_SCOPED_STORE"
    found=$SKILLS_OWN_COPY
    [[ -n $found ]] || return 0
  elif [[ ! -f $found/SKILL.md ]]; then
    if ((SKILLS_CHECK_ONLY)); then
      skills_fail skill-missing "$found" "skill missing: $name; $(_skills_rebuild_hint) to install it"
    fi
    _skills_install "$name" "$directory" "$source" "$SKILLS_SCOPED_STORE"
    [[ -f $found/SKILL.md ]] || skills_fail install-unverified "$found" "skill install could not be verified: $name"
    log "installed skill $name into $found"
    if [[ -n $directory_sha && $(directory_sha256 "$found") != "$directory_sha" ]]; then
      skills_fail install-digest-mismatch "$found" \
        "installed skill digest differs from the lock: $name ($found); the native copy leaves out metadata.json, .git, __pycache__ and __pypackages__ and follows symlinks"
    fi
  elif [[ -n $directory_sha ]]; then
    _skills_refresh_third_party "$name" "$found" "$source" "$directory_sha"
  fi

  real=$(realpath -e -- "$found" 2>/dev/null) ||
    skills_fail skill-unresolvable "$found" "cannot resolve the skill path: $found"
  for root in "${roots[@]}"; do
    _skills_link "$root/$name" "$found" "$real"
  done
}

# --- Sweep ----------------------------------------------------------------

# _skills_is_managed_target TARGET: whether the literal link TARGET points
# into a managed root (one of SKILLS_SWEEP_PREFIXES followed by a name).
_skills_is_managed_target() {
  local target=$1 prefix
  for prefix in "${SKILLS_SWEEP_PREFIXES[@]}"; do
    [[ $target == "$prefix"?* ]] && return 0
  done
  return 1
}

# _skills_names_own NAME: whether NAME is the name or the directory of an own
# skill of the lock.
_skills_names_own() {
  jq -e --arg name "$1" --arg compat "${DS_COMPAT_REPO_OWNED_REVISION:-same-as-instance-checkout}" '
    any(.skills[]; (.name == $name or .directory == $name)
      and (.revision == "same-as-instance-checkout" or .revision == $compat))' "$SKILLS_LOCK" >/dev/null 2>&1
}

skills_sweep() {
  local root link failed=0
  local -a links=()
  for root in "$SKILLS_CANONICAL" "${SKILLS_LINK_ROOTS[@]}" "${SKILLS_AGENT_ROOTS[@]}"; do
    [[ -d $root ]] || continue
    mapfile -d '' links < <(find "$root" -mindepth 1 -maxdepth 1 -xtype l -print0 | LC_ALL=C sort -z)
    for link in "${links[@]}"; do
      _skills_is_managed_target "$(readlink -- "$link")" || continue
      if ((SKILLS_CHECK_ONLY)); then
        if _skills_names_own "${link##*/}"; then
          log "dangling link of an own skill: $link; $(_skills_rebuild_hint) to remove it"
          continue
        fi
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
