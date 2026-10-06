#!/usr/bin/env bash
# summary: Check the static contracts of an instance or of the framework source
#
# Usage: dotsteward [--instance DIR] static [--sandbox] [--only CHECK]...
#
# Checks the instance found like every instance command (--instance,
# DOTSTEWARD_INSTANCE, then the nearest workstation.toml above the working
# directory). Without an instance, inside the framework source, it checks the
# framework itself. Every failure of every selected check is reported before
# the command exits.
#
# Instance checks, in this order:
#   shell          bash -n over every shell file (*.sh, or a sh or bash
#                  shebang); a file with a shebang is executable, one without
#                  declares "# shellcheck shell="; ShellCheck, when installed,
#                  at the version versions.lock.json pins
#                  (nix_packages.shellcheck.resolved) and without findings
#   bans           shell and Nix files outside tests/ never pipe a download
#                  into a shell, force a git push or allow package downgrades
#   launcher       .dotsteward/cli.sh equals the framework's template copy
#   bootstrap      bootstrap.sh equals the framework's template copy, when the
#                  framework ships one
#   skills         vendored skills match the skills lock: schema, counts,
#                  names, digests, licenses, no symbolic links and no
#                  framework skills
#   versions-lock  versions.lock.json: schema_version "1.0", no persistent
#                  agentic updates, native application updates kept
#   allowlist      no update allowlist entry (gate.update_allowlist and the
#                  committed manifest mirrors) matches the settings buffer
#   protected      byte-protected files keep their sha256 ([protected])
#   overlays       declared overlay files exist; agent/overlays holds only
#                  overlays of framework skills (and its README.md)
#   privacy        the privacy scan with the instance policy: generic secret
#                  rules, [privacy] forbidden_paths and file_rules, and the
#                  [privacy] denylist outside the sandbox
#   scripts        every [gate] static script exists and is executable; when
#                  every selected check passed they run in order from the
#                  instance root (shell scripts with bash, other scripts
#                  through their shebang) with DOTSTEWARD_INSTANCE_ROOT,
#                  DOTSTEWARD_SANDBOX (0 or 1) and DOTSTEWARD_STATIC_HELPER (a
#                  file to source that defines fail MESSAGE); the first
#                  failing script ends the run with its exit status
# Framework checks: shell, bans, command-names (the command-name rule: stub
# file names, arguments of require_command and of command -v, and fenced
# shell blocks of Markdown files name only catalog commands, the platform
# tools of tests/static/allowed-commands.txt and the fixture names), seeds
# (modules/components/*/seed.json against schema/seed.schema.json) and
# privacy (privacy/policy.toml, no denylist).
#
# Options:
#   --sandbox     the context of a Nix check: every file below the root is
#                 listed (no git) and nothing outside the root is read (no
#                 denylist). Outside a git work tree the files are listed
#                 the same way without this option.
#   --only CHECK  run only the named checks (repeatable; comma-separated
#                 names are accepted)
#
# Exit status: 0 when every check passed, 1 on a failed check or a usage
# error, otherwise the exit status of the failing instance script.
set -Eeuo pipefail

lib_dir=${DOTSTEWARD_LIB:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)}
framework_root=$(cd -P -- "${DOTSTEWARD_FRAMEWORK_ROOT:-$lib_dir/../..}" && pwd)

# shellcheck source=cli/lib/lib.sh
source "$lib_dir/lib.sh"
# Only defines functions and empty tables; the scan runs in a subshell.
# shellcheck source=cli/lib/privacy.sh
source "$lib_dir/privacy.sh"

error() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
}

trap 'status=$?; error "static failed unexpectedly at line $LINENO (exit $status)"' ERR

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  die "static needs bash 4.4 or newer (found $BASH_VERSION)"
fi

usage() {
  sed -n '3,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

INSTANCE_CHECKS=(shell bans launcher bootstrap skills versions-lock allowlist protected overlays privacy scripts)
FRAMEWORK_CHECKS=(shell bans command-names seeds privacy)

sandbox=0
only=()
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --sandbox)
      sandbox=1
      shift
      ;;
    --only)
      (($# >= 2)) && [[ -n $2 ]] || die "--only requires a value"
      IFS=, read -r -a names <<<"$2"
      only+=("${names[@]}")
      shift 2
      ;;
    --only=*)
      [[ -n ${1#--only=} ]] || die "--only requires a value"
      IFS=, read -r -a names <<<"${1#--only=}"
      only+=("${names[@]}")
      shift
      ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

# --- target ------------------------------------------------------------------

# True when a workstation.toml exists in the working directory or above.
instance_above() {
  local dir
  dir=$(pwd -P)
  while :; do
    [[ ! -f $dir/workstation.toml ]] || return 0
    [[ $dir != / ]] || return 1
    dir=$(dirname -- "$dir")
  done
}

# True inside the framework source tree (not the installed package, which
# has no tests/).
in_framework_source() {
  local here
  here=$(pwd -P)
  [[ $here == "$framework_root" || $here == "$framework_root"/* ]] &&
    [[ -f $framework_root/privacy/policy.toml && -f $framework_root/tests/static/allowed-commands.txt ]]
}

if [[ -z ${DOTSTEWARD_INSTANCE:-} ]] && ! instance_above && in_framework_source; then
  target=framework
  root=$framework_root
  checks=("${FRAMEWORK_CHECKS[@]}")
  target_label="the framework"
else
  target=instance
  # shellcheck source=cli/lib/config.sh
  source "$lib_dir/config.sh"
  # shellcheck disable=SC2119 # discovery without an explicit directory
  config_load
  root=$(cd -P -- "$DS_INSTANCE_ROOT" && pwd)
  checks=("${INSTANCE_CHECKS[@]}")
  target_label="an instance"
fi

declare -A selected=()
if ((${#only[@]})); then
  for name in "${only[@]}"; do
    known=0
    for check in "${checks[@]}"; do
      [[ $check != "$name" ]] || known=1
    done
    ((known)) || die "unknown check for $target_label: $name"
    selected[$name]=1
  done
else
  for check in "${checks[@]}"; do
    selected[$check]=1
  done
fi

# --- shared state and helpers ----------------------------------------------------

declare -A failed=()
current=""

# fail MESSAGE: one failure of the running check.
fail() {
  error "static $current: $*"
  failed[$current]=1
}

# Git context: the files git would carry; otherwise (sandbox, no git) every
# file below the root.
git_context=0
if ((!sandbox)) && [[ $(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null || true) == true ]]; then
  git_context=1
fi

FILES=()
list_files() {
  if ((git_context)); then
    git -C "$root" -c core.quotePath=false ls-files -z -co --exclude-standard
  else
    (cd "$root" && find . -name .git -prune -o \( -type f -o -type l \) -print0) | sed -z 's|^\./||'
  fi
}
while IFS= read -r -d '' path; do
  [[ -e $root/$path || -L $root/$path ]] && FILES+=("$path")
done < <(list_files | LC_ALL=C sort -z -u)

# Paths below these prefixes are vendored or generated: no shell or ban
# checks.
SKIP_PREFIXES=()
if [[ $target == instance ]]; then
  SKIP_PREFIXES+=("${DS_SKILLS_VENDOR_DIR%/}/")
fi

skipped() {
  local prefix
  for prefix in "${SKIP_PREFIXES[@]}"; do
    [[ $1 != "$prefix"* ]] || return 0
  done
  return 1
}

SHELL_SHEBANG='^#![[:space:]]*(/usr/bin/env[[:space:]]+)?(/[^[:space:]]*/)?(ba)?sh([[:space:]]|$)'

# Shell files: *.sh without a foreign shebang, or any file with a sh or bash
# shebang; regular files only.
SHELL_FILES=()
NIX_FILES=()
MD_FILES=()
for path in "${FILES[@]}"; do
  case $path in
    *.nix) NIX_FILES+=("$path") ;;
    *.md) MD_FILES+=("$path") ;;
  esac
  [[ -f $root/$path && ! -L $root/$path ]] || continue
  skipped "$path" && continue
  first=""
  IFS= read -r first <"$root/$path" 2>/dev/null || true
  if [[ $first == '#!'* ]]; then
    [[ $first =~ $SHELL_SHEBANG ]] && SHELL_FILES+=("$path")
  elif [[ $path == *.sh ]]; then
    SHELL_FILES+=("$path")
  fi
done

# --- shell -------------------------------------------------------------------

check_shell() {
  local path first output version pinned lock jobs status=0
  for path in "${SHELL_FILES[@]}"; do
    if ! output=$(bash -n -- "$root/$path" 2>&1); then
      fail "$path: bash -n failed"
      printf '%s\n' "$output" >&2
    fi
    first=""
    IFS= read -r first <"$root/$path" || true
    if [[ $first == '#!'* ]]; then
      [[ -x $root/$path ]] || fail "$path: has a shebang but is not executable"
    elif ! head -n 5 -- "$root/$path" | grep -q '^# shellcheck shell='; then
      fail "$path: has neither a shebang nor a '# shellcheck shell=' directive"
    fi
  done
  ((${#SHELL_FILES[@]})) || return 0
  if ! command -v shellcheck >/dev/null 2>&1; then
    warn "shellcheck is not installed; the ShellCheck part of the shell check was skipped"
    return 0
  fi
  version=$(shellcheck --version | awk '$1 == "version:" { print $2; exit }')
  if [[ $target == instance ]]; then
    lock=$root/$DS_PINS_VERSIONS_LOCK
    pinned=$(jq -r '.nix_packages.shellcheck.resolved // empty' "$lock" 2>/dev/null || true)
    if [[ -n $pinned && $pinned != "$version" ]]; then
      fail "ShellCheck $pinned is pinned in $DS_PINS_VERSIONS_LOCK but $version is installed"
      return 0
    fi
  fi
  jobs=$(nproc 2>/dev/null || printf 2)
  ((jobs <= 8)) || jobs=8
  (cd "$root" && printf '%s\0' "${SHELL_FILES[@]}" | xargs -0 -r -n 16 -P "$jobs" shellcheck -x -e SC1091) || status=$?
  ((status == 0)) || fail "shellcheck reported findings"
}

# --- bans --------------------------------------------------------------------

# The ban patterns; this block is exempt from the check itself.
# dotsteward:bans:begin
BAN_RULES=(
  'a download piped into a shell' 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([^[:alnum:]_.-]|$)'
  'a forced git push' 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+(--force[^[:space:]]*|-f)([[:space:]]|$)'
  'a package downgrade flag' '--allow-downgrades'
)
# dotsteward:bans:end
BAN_SELF=cli/commands/static.sh

check_bans() {
  local path i rest file line from=0 to=0 hits
  local -a files=()
  for path in "${SHELL_FILES[@]}" "${NIX_FILES[@]}"; do
    [[ $path != tests/* ]] || continue
    skipped "$path" && continue
    files+=("$path")
  done
  ((${#files[@]})) || return 0
  if [[ $target == framework && -f $root/$BAN_SELF ]]; then
    from=$(grep -n -x -F -m 1 '# dotsteward:bans:begin' "$root/$BAN_SELF" | cut -d: -f1 || true)
    to=$(grep -n -x -F -m 1 '# dotsteward:bans:end' "$root/$BAN_SELF" | cut -d: -f1 || true)
  fi
  for ((i = 0; i < ${#BAN_RULES[@]}; i += 2)); do
    hits=$(cd "$root" && grep -H -n -I -E -e "${BAN_RULES[i + 1]}" -- "${files[@]}" || true)
    [[ -n $hits ]] || continue
    while IFS= read -r rest; do
      file=${rest%%:*}
      rest=${rest#*:}
      line=${rest%%:*}
      if [[ $file == "$BAN_SELF" && -n $from && -n $to ]] && ((line >= from && line <= to)); then
        continue
      fi
      fail "$file:$line: ${BAN_RULES[i]}"
    done <<<"$hits"
  done
  return 0
}

# --- launcher and bootstrap ----------------------------------------------------

# same_as_template PATH: PATH of the instance equals template/PATH of the
# framework.
same_as_template() {
  local path=$1 source=$framework_root/template/$1
  if [[ ! -f $source ]]; then
    fail "the framework copy template/$path is missing"
  elif [[ ! -f $root/$path ]]; then
    fail "$path is missing"
  elif [[ $(sha256_file "$source") != "$(sha256_file "$root/$path")" ]]; then
    fail "$path differs from the framework's template/$path"
  fi
}

check_launcher() {
  same_as_template .dotsteward/cli.sh
}

check_bootstrap() {
  [[ ! -f $framework_root/template/bootstrap.sh ]] || same_as_template bootstrap.sh
}

# --- skills ------------------------------------------------------------------

check_skills() {
  local lock=$DS_SKILLS_LOCK vendor=${DS_SKILLS_VENDOR_DIR%/} name directory sha dsha declared listed
  local entry link
  local -a expected=() found=() problems=()
  if [[ ! -e $root/$lock ]]; then
    if [[ -e $root/$vendor ]] && [[ -n $(find "$root/$vendor" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      fail "$lock is missing but $vendor holds vendored skills"
    fi
    return 0
  fi
  if ! jq -e 'type == "object"' "$root/$lock" >/dev/null 2>&1; then
    fail "$lock is not a valid JSON object"
    return 0
  fi
  mapfile -t problems < <(jq -r --arg lock "$lock" '
    (if .schema_version != "1.0" then "\($lock): schema_version must be \"1.0\"" else empty end),
    (if (.skills | type) != "array" then "\($lock): skills must be a list" else
      (if .expected_skill_count != (.skills | length) then
        "\($lock): expected_skill_count is \(.expected_skill_count), the lock lists \(.skills | length)"
      else empty end),
      ((.skills | map(.name) | group_by(.) | map(select(length > 1) | .[0]))[] | "\($lock): duplicate skill name \(.)"),
      ((.skills | map(.directory) | group_by(.) | map(select(length > 1) | .[0]))[] | "\($lock): duplicate skill directory \(.)"),
      (.skills[] | select((.name | type) != "string" or (.directory | type) != "string")
        | "\($lock): every skill needs a name and a directory")
    end)' "$root/$lock")
  for entry in "${problems[@]}"; do
    fail "$entry"
  done
  jq -e '(.skills | type) == "array"' "$root/$lock" >/dev/null || return 0

  if [[ -L $root/$vendor ]]; then
    fail "$vendor: the vendored skills directory must not be a symbolic link"
    return 0
  fi
  if [[ -d $root/$vendor ]]; then
    while IFS= read -r -d '' link; do
      fail "${link#"$root"/}: vendored skills must not contain symbolic links"
    done < <(find "$root/$vendor" -type l -print0 | LC_ALL=C sort -z)
    mapfile -t found < <(find "$root/$vendor" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
  fi
  mapfile -t expected < <(jq -r '.skills[].directory | strings' "$root/$lock" | LC_ALL=C sort)
  if [[ "${expected[*]}" != "${found[*]}" ]]; then
    fail "$vendor: directories do not match the lock (expected ${expected[*]:-nothing}, found ${found[*]:-nothing})"
  fi

  while IFS=$'\t' read -r name directory sha dsha; do
    [[ $name != dotsteward-* ]] || fail "$name: framework skills never appear in $lock"
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || fail "$name: skill_sha256 is not a sha256 hex digest"
    [[ $dsha == - || $dsha =~ ^[0-9a-f]{64}$ ]] || fail "$name: directory_sha256 is not a sha256 hex digest"
    if [[ -z $directory || $directory == *'/'* || $directory == . || $directory == .. ]]; then
      fail "$name: invalid directory $directory"
      continue
    fi
    [[ -d $root/$vendor/$directory && ! -L $root/$vendor/$directory ]] || continue
    entry=$root/$vendor/$directory/SKILL.md
    if [[ ! -f $entry || -L $entry ]]; then
      fail "$name: SKILL.md is missing"
      continue
    fi
    [[ $(sha256_file "$entry") == "$sha" ]] || fail "$name: SKILL.md digest does not match $lock"
    if [[ $dsha != - && $(directory_sha256 "$root/$vendor/$directory") != "$dsha" ]]; then
      fail "$name: directory digest does not match $lock"
    fi
    listed=$(find "$root/$vendor/$directory" -maxdepth 1 -type f -iname 'license*' -print -quit)
    [[ -n $listed ]] || fail "$name: no license file"
    declared=$(sed -n 's/^name:[[:space:]]*//p' "$entry" | head -n 1)
    declared=${declared%"${declared##*[![:space:]]}"}
    declared=${declared#[\"\']}
    declared=${declared%[\"\']}
    [[ $declared == "$name" ]] || fail "$name: SKILL.md declares name ${declared:-nothing}"
  done < <(jq -r '.skills[] | select((.name | type) == "string" and (.directory | type) == "string")
    | [.name, .directory, (.skill_sha256 // "" | tostring), (.directory_sha256 // "-" | tostring)] | @tsv' "$root/$lock")
  return 0
}

# --- versions lock -----------------------------------------------------------

check_versions_lock() {
  local lock=$DS_PINS_VERSIONS_LOCK entry
  local -a problems=()
  if [[ ! -f $root/$lock ]]; then
    fail "$lock is missing"
    return 0
  fi
  if ! jq -e 'type == "object"' "$root/$lock" >/dev/null 2>&1; then
    fail "$lock is not valid JSON"
    return 0
  fi
  mapfile -t problems < <(jq -r --arg lock "$lock" '
    (if .schema_version != "1.0" then "\($lock): schema_version must be \"1.0\"" else empty end),
    (if .policy.persistent_agentic_updates != false then
      "\($lock): policy.persistent_agentic_updates must be false" else empty end),
    (if .policy.native_application_updates != true then
      "\($lock): policy.native_application_updates must be true" else empty end)' "$root/$lock")
  for entry in "${problems[@]}"; do
    fail "$entry"
  done
  return 0
}

# --- update allowlist ----------------------------------------------------------

# allowlist_entries LABEL ENTRY...: no entry may match a settings buffer path.
allowlist_entries() {
  local label=$1 entry candidate i=0 status
  shift
  for entry in "$@"; do
    i=$((i + 1))
    status=0
    # shellcheck disable=SC2319 # the status of =~ itself: 2 means an invalid regex
    [[ "" =~ $entry ]] || status=$?
    if ((status == 2)); then
      fail "$label entry $i is not a valid extended regular expression"
      continue
    fi
    for candidate in "${BUFFER_CANDIDATES[@]}"; do
      if [[ $candidate =~ ^($entry)$ ]]; then
        fail "$label entry $i matches the settings buffer path $candidate"
        break
      fi
    done
  done
  return 0
}

check_allowlist() {
  local buffer=${DS_SETTINGS_BUFFER_DIR%/} path mirror name
  local -a entries=()
  BUFFER_CANDIDATES=("$buffer" "$buffer/buffer.toml" "$buffer/files/" "$buffer/files/example")
  for path in "${FILES[@]}"; do
    [[ $path != "$buffer/"* ]] || BUFFER_CANDIDATES+=("$path")
  done
  allowlist_entries gate.update_allowlist "${DS_GATE_UPDATE_ALLOWLIST[@]}"
  for mirror in "$root"/.dotsteward/manifest.*.json; do
    [[ -f $mirror ]] || continue
    name=${mirror#"$root"/}
    if ! mapfile -t entries < <(jq -r '(.update_allowlist // [])[]' "$mirror" 2>/dev/null) ||
      ! jq -e '(.update_allowlist // []) | type == "array"' "$mirror" >/dev/null 2>&1; then
      fail "$name is not valid JSON with an update_allowlist list"
      continue
    fi
    allowlist_entries "$name update_allowlist" "${entries[@]}"
  done
  return 0
}

# --- protected files ---------------------------------------------------------

check_protected() {
  local path
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    if [[ ! -f $root/$path ]]; then
      fail "$path: protected file is missing"
    elif [[ $(sha256_file "$root/$path") != "${DS_PROTECTED[$path],,}" ]]; then
      fail "$path: bytes changed (sha256 does not match [protected])"
    fi
  done < <(printf '%s\n' "${!DS_PROTECTED[@]}" | LC_ALL=C sort)
  return 0
}

# --- overlays ----------------------------------------------------------------

check_overlays() {
  local skill path file name
  local -A framework_skills=()
  while IFS= read -r skill; do
    framework_skills[$skill]=1
  done < <(jq -r '.properties.skills.properties.overlays.propertyNames.enum[]' \
    "$framework_root/schema/workstation.schema.json")
  while IFS= read -r skill; do
    [[ -n $skill ]] || continue
    path=${DS_SKILLS_OVERLAYS[$skill]}
    [[ -f $(config_instance_path "$path") ]] || fail "$path: overlay of $skill is missing"
  done < <(printf '%s\n' "${!DS_SKILLS_OVERLAYS[@]}" | LC_ALL=C sort)
  [[ -d $root/agent/overlays ]] || return 0
  for file in "$root"/agent/overlays/*; do
    [[ -e $file || -L $file ]] || continue
    name=${file##*/}
    # README.md documents the directory (the template ships one).
    [[ $name != README.md ]] || continue
    if [[ $name != *.md || -z ${framework_skills[${name%.md}]:-} ]]; then
      fail "agent/overlays/$name: ${name%.md} is not a framework skill"
    fi
  done
  return 0
}

# --- privacy -----------------------------------------------------------------

# Runs in a subshell (the scanner keeps global state); prints its findings
# and returns 1 on findings or errors.
run_privacy() (
  trap - ERR
  local rule message pattern shown denylist noun
  local -a globs=()
  if [[ $target == framework ]]; then
    ds_privacy_load_policy "$root/privacy/policy.toml" || exit 1
    ds_privacy_load_allowlist "$root/privacy/allowlist.txt"
  else
    ds_privacy_load_instance_policy
    for rule in "${DS_PRIVACY_FORBIDDEN_PATHS_CONFIG[@]}"; do
      ds_privacy_add_forbidden_path "$rule" || exit 1
    done
    while IFS= read -r rule; do
      [[ -n $rule ]] || continue
      message=$(jq -r '.message' <<<"$rule")
      pattern=$(jq -r '.pattern' <<<"$rule")
      mapfile -t globs < <(jq -r '.files[]' <<<"$rule")
      ds_privacy_add_file_rule "$message" "$pattern" "${globs[@]}" || exit 1
    done < <(jq -c '.[]' <<<"$DS_PRIVACY_FILE_RULES_JSON")
    if ((!sandbox)) && [[ -n $DS_PRIVACY_DENYLIST ]]; then
      shown=$(jq -r '.privacy.denylist // empty' <<<"$DS_CONFIG_JSON")
      denylist=$DS_PRIVACY_DENYLIST
      if [[ ! -f $denylist || ! -r $denylist ]]; then
        error "static privacy: denylist file is missing or unreadable: ${shown:-$denylist}"
        exit 1
      fi
      ds_privacy_load_terms denylist "$denylist" || exit 1
    fi
  fi
  trap ds_privacy_end EXIT
  ds_privacy_begin || exit 1
  ds_privacy_collect_tree "$root" "$git_context" || exit 1
  ds_privacy_report 1 0 || exit 1
  if ((DS_PRIVACY_FINDINGS == 0)); then
    log "scan clean: $DS_PRIVACY_FILES files, $DS_PRIVACY_COMMITS commits"
    exit 0
  fi
  noun=findings
  ((DS_PRIVACY_FINDINGS != 1)) || noun=finding
  error "static privacy: the scan found $DS_PRIVACY_FINDINGS $noun"
  exit 1
)

check_privacy() {
  if [[ $target == instance ]]; then
    # The configuration's list, kept apart from the scanner's own variable.
    DS_PRIVACY_FORBIDDEN_PATHS_CONFIG=("${DS_PRIVACY_FORBIDDEN_PATHS[@]}")
  fi
  run_privacy || failed[privacy]=1
}

# --- command-name rule (framework) --------------------------------------------

CATALOG_COMMANDS=(claude codex herdr zsh starship opencode pi code)
FIXTURE_NAMES=(example-app example-term alpha beta gamma delta)
SHELL_WORDS=(alias bg bind break builtin caller cd command compgen complete compopt continue declare
  dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill let
  local logout mapfile popd printf pushd pwd read readarray readonly return set shift shopt source
  suspend test times trap true type typeset ulimit umask unalias unset wait . : '[' '[[' ']]' dotsteward)
# Words after which the next word is a command, and words that end a
# command position.
LEAD_WORDS=('if' 'then' 'else' 'elif' 'do' 'while' 'until' '!' '{' 'time')
STOP_WORDS=('fi' 'done' 'esac' '}' 'for' 'case' 'select' 'function' 'in')
PREFIX_WORDS=(sudo env exec xargs nohup nice timeout command)

declare -A ALLOWED_WORDS=() LEAD=() STOP=() PREFIX=()
NAME_ERRORS=0

# word_allowed WORD: true when WORD is allowed or is not a literal command
# name (variables, substitutions, repository-relative paths).
word_allowed() {
  local word=$1
  word=${word#[\"\']}
  word=${word%[\"\']}
  [[ -n $word ]] || return 0
  [[ $word != *[\$\`\{\}\<\>\*=]* ]] || return 0
  if [[ $word == /* ]]; then
    word=${word##*/}
  elif [[ $word == */* ]]; then
    return 0
  fi
  [[ -z ${ALLOWED_WORDS[$word]:-} ]] || return 0
  [[ $word =~ ^[A-Za-z0-9_.+-]+$ ]] || return 0
  return 1
}

name_error() {
  NAME_ERRORS=$((NAME_ERRORS + 1))
  fail "$1: $2 names a command outside the catalog, tests/static/allowed-commands.txt and the fixture names"
}

# command_segment LOCATION SEGMENT CONTINUED: checks the command word of one
# simple command; CONTINUED=1 means the segment continues a previous line.
command_segment() {
  local location=$1 continued=$3 token prefix=0
  local -a tokens=()
  read -r -a tokens <<<"$2" || true
  ((continued)) && return 0
  for token in "${tokens[@]}"; do
    if ((prefix)); then
      [[ $token == -* || $token =~ ^[0-9]+[smhd]?$ || $token =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    else
      [[ $token =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
      [[ -z ${LEAD[$token]:-} ]] || continue
      [[ -z ${STOP[$token]:-} ]] || return 0
    fi
    word_allowed "$token" || {
      name_error "$location" "a fenced shell block"
      return 0
    }
    if [[ -n ${PREFIX[$token]:-} ]]; then
      prefix=1
      continue
    fi
    return 0
  done
}

# markdown_blocks FILE: the command lines of its fenced shell blocks.
markdown_blocks() {
  local file=$1 line number=0 in_block=0 lang="" fence="" continued=0 text segment
  local fence_re='^[[:space:]]*(```+|~~~+)[[:space:]]*([A-Za-z0-9_-]*)'
  local close_re='^[[:space:]]*(```+|~~~+)[[:space:]]*$'
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    if ((!in_block)); then
      if [[ $line =~ $fence_re ]]; then
        in_block=1
        fence=${BASH_REMATCH[1]}
        lang=${BASH_REMATCH[2],,}
        continued=0
      fi
      continue
    fi
    if [[ $line =~ $close_re && ${BASH_REMATCH[1]} == "$fence"* ]]; then
      in_block=0
      continue
    fi
    case $lang in
      sh | bash | shell | zsh) text=$line ;;
      console | shell-session)
        if [[ $line == '$ '* ]]; then
          text=${line#'$ '}
        elif ((continued)); then
          text=$line
        else
          continue
        fi
        ;;
      *) continue ;;
    esac
    [[ ! $text =~ ^[[:space:]]*# ]] || continue
    text=${text%%[[:space:]]#*}
    local was_continued=$continued
    continued=0
    [[ $text != *\\ ]] || continued=1
    text=${text//"\$("/$'\n'}
    text=${text//'&&'/$'\n'}
    text=${text//'||'/$'\n'}
    text=${text//[|;()\`]/$'\n'}
    local first=1
    while IFS= read -r segment; do
      if ((first)); then
        command_segment "$file:$number" "$segment" "$was_continued"
        first=0
      else
        command_segment "$file:$number" "$segment" 0
      fi
    done <<<"$text"
  done <"$root/$file"
  return 0
}

# argument_words FILE KEYWORD REGEX SOURCE: every literal command word that
# the last group of REGEX captures on the non-comment lines of FILE that
# contain the fixed string KEYWORD.
argument_words() {
  local file=$1 keyword=$2 regex=$3 source=$4 hits rest number text word
  hits=$(cd "$root" && grep -n -F -e "$keyword" -- "$file" || true)
  [[ -n $hits ]] || return 0
  while IFS= read -r rest; do
    number=${rest%%:*}
    text=${rest#*:}
    [[ ! $text =~ ^[[:space:]]*# ]] || continue
    while [[ $text =~ $regex ]]; do
      word=${BASH_REMATCH[${#BASH_REMATCH[@]} - 1]}
      text=${text#*"${BASH_REMATCH[0]}"}
      word_allowed "$word" || name_error "$file:$number" "$source"
    done
  done <<<"$hits"
  return 0
}

check_command_names() {
  local list=$root/tests/static/allowed-commands.txt word path n=0
  local -a words=() stubs=()
  for word in "${CATALOG_COMMANDS[@]}" "${FIXTURE_NAMES[@]}" "${SHELL_WORDS[@]}"; do
    ALLOWED_WORDS[$word]=1
  done
  while IFS= read -r path; do
    path=${path%%#*}
    read -r -a words <<<"$path" || true
    for word in "${words[@]}"; do
      ALLOWED_WORDS[$word]=1
    done
  done <"$list"
  for word in "${LEAD_WORDS[@]}"; do LEAD[$word]=1; done
  for word in "${STOP_WORDS[@]}"; do STOP[$word]=1; done
  for word in "${PREFIX_WORDS[@]}"; do PREFIX[$word]=1; done

  for path in "${FILES[@]}"; do
    [[ $path == tests/lib/stubs/* && $path != tests/lib/stubs/*/* ]] && stubs+=("${path#tests/lib/stubs/}")
  done
  for word in "${stubs[@]}"; do
    n=$((n + 1))
    word_allowed "$word" || name_error "tests/lib/stubs (entry $n)" "a stub file name"
  done
  for path in "${SHELL_FILES[@]}" "${NIX_FILES[@]}"; do
    argument_words "$path" require_command \
      'require_command[[:space:]]+([^[:space:];|&)]+)' "an argument of require_command"
    argument_words "$path" command \
      'command[[:space:]]+-v[[:space:]]+(--[[:space:]]+)?([^[:space:];|&)]+)' "an argument of command -v"
  done
  for path in "${MD_FILES[@]}"; do
    [[ -f $root/$path ]] && markdown_blocks "$path"
  done
  ((NAME_ERRORS == 0)) || fail "$NAME_ERRORS command names outside the allowed sets"
}

# --- seeds (framework) ---------------------------------------------------------

check_seeds() {
  local line status=0 output
  output=$(PYTHONPATH=$root/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "$root" <<'PY'
import json
import pathlib
import sys

from dotsteward_cli.config import _Validator

root = pathlib.Path(sys.argv[1])
schema = json.loads((root / "schema" / "seed.schema.json").read_text(encoding="utf-8"))
validator = _Validator(schema)
components = root / "modules" / "components"
directories = sorted(path for path in components.iterdir() if path.is_dir()) if components.is_dir() else []
for directory in directories:
    relative = f"modules/components/{directory.name}"
    seed = directory / "seed.json"
    if not seed.is_file():
        print(f"{relative}: missing seed.json")
        continue
    try:
        document = json.loads(seed.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, ValueError):
        print(f"{relative}/seed.json: invalid JSON")
        continue
    messages = validator.validate([], schema, document)
    if not messages:
        if document["component"] != directory.name:
            messages.append(f'component "{document["component"]}" does not match its directory {directory.name}')
        inputs = set(document["flake_inputs"])
        locked = set(document["versions_lock"].get("flake_inputs", {}))
        messages += [f"flake input {name} has no versions_lock.flake_inputs entry" for name in sorted(inputs - locked)]
        messages += [f"versions_lock.flake_inputs.{name} has no flake_inputs entry" for name in sorted(locked - inputs)]
    for message in messages:
        print(f"{relative}/seed.json: {message}")
PY
  ) || status=$?
  if [[ -n $output ]]; then
    while IFS= read -r line; do
      fail "$line"
    done <<<"$output"
  fi
  ((status == 0)) || fail "the seed check failed (exit $status)"
}

# --- instance scripts ----------------------------------------------------------

SCRIPTS=()
check_scripts() {
  local script path
  for script in "${DS_GATE_STATIC[@]}"; do
    path=$(config_instance_path "$script")
    if [[ ! -f $path ]]; then
      fail "$script: instance script is missing"
    elif [[ ! -x $path ]]; then
      fail "$script: instance script is not executable"
    else
      SCRIPTS+=("$script")
    fi
  done
  return 0
}

# run_scripts: runs the validated scripts; exits with the first failure.
run_scripts() {
  local script status base work path first
  local -a command=()
  ((${#SCRIPTS[@]})) || return 0
  base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  work=$(mktemp -d "$base/dotsteward-static.XXXXXX")
  # shellcheck disable=SC2064 # the directory is fixed now
  trap "cleanup_temp_dir '$work'" EXIT
  printf '%s\n' '# shellcheck shell=bash' \
    '# Sourced by instance static scripts: fail MESSAGE reports and exits 1.' \
    "fail() {" "  printf '[dotsteward] ERROR: %s\\n' \"\$*\" >&2" "  exit 1" "}" >"$work/helper.sh"
  for script in "${SCRIPTS[@]}"; do
    status=0
    path=$(config_instance_path "$script")
    # Shell scripts run with bash, which needs no interpreter path (the Nix
    # sandbox has no /usr/bin/env); other scripts run through their shebang.
    command=("$path")
    first=""
    IFS= read -r first <"$path" || true
    if [[ $path == *.sh || $first =~ $SHELL_SHEBANG ]]; then
      command=(bash "$path")
    fi
    (cd "$root" && DOTSTEWARD_INSTANCE_ROOT=$root DOTSTEWARD_SANDBOX=$sandbox \
      DOTSTEWARD_STATIC_HELPER=$work/helper.sh "${command[@]}") || status=$?
    if ((status != 0)); then
      error "static: instance script $script failed (exit $status)"
      exit "$status"
    fi
    log "static: instance script $script passed"
  done
}

# --- run -----------------------------------------------------------------------

ran=()
for check in "${checks[@]}"; do
  [[ -n ${selected[$check]:-} ]] || continue
  current=$check
  ran+=("$check")
  case $check in
    shell) check_shell ;;
    bans) check_bans ;;
    launcher) check_launcher ;;
    bootstrap) check_bootstrap ;;
    skills) check_skills ;;
    versions-lock) check_versions_lock ;;
    allowlist) check_allowlist ;;
    protected) check_protected ;;
    overlays) check_overlays ;;
    privacy) check_privacy ;;
    scripts) check_scripts ;;
    command-names) check_command_names ;;
    seeds) check_seeds ;;
  esac
done

failed_names=()
for check in "${ran[@]}"; do
  [[ -z ${failed[$check]:-} ]] || failed_names+=("$check")
done
if ((${#failed_names[@]})); then
  error "static checks failed ($target): ${failed_names[*]}"
  if [[ -n ${selected[scripts]:-} ]] && ((${#DS_GATE_STATIC[@]})); then
    error "instance scripts were not run because a check failed"
  fi
  exit 1
fi

if [[ -n ${selected[scripts]:-} ]]; then
  run_scripts
fi
log "static checks passed ($target): ${ran[*]}"
