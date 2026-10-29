# shellcheck shell=bash
# dotsteward install methods engine: the method semantics of the
# component contract, implemented once for the install command, the agents
# installer and anything else that installs or checks a component.
#
# Source after lib.sh and config.sh, once config_load has run:
#
#   source "$DOTSTEWARD_LIB/lib.sh"
#   source "$DOTSTEWARD_LIB/config.sh"
#   source "$DOTSTEWARD_LIB/methods.sh"
#   config_load
#   methods_manifest_load [GENERATION]
#
# Manifest
#   methods_system                   the Nix system of this machine (from
#                                    nix.systems and the running platform)
#   methods_manifest_load [GENERATION]
#                                    loads GENERATION/home-path/share/
#                                    dotsteward/manifest.json, else the
#                                    instance mirror .dotsteward/manifest.
#                                    <system>.json; sets DS_MANIFEST_FILE and
#                                    DS_MANIFEST_JSON
#   methods_components PROFILE       names of the components active in
#                                    PROFILE on this platform, in
#                                    [components] order
#   methods_component NAME           the manifest entry of NAME (JSON)
#   methods_component_method NAME    its resolved method
#   methods_is_system_level METHOD   deb and app-archive: skipped in adopt
#                                    mode
#   methods_validate NAME            the method is known and available on
#                                    this platform
# Lock and versions
#   methods_lock_get PATH COMPONENT  the value at the dotted lock PATH (JSON);
#                                    dies like pinAt when it is missing
#   methods_version_compare A B      prints -1, 0 or 1: dotted numeric parts,
#                                    a missing part sorts first, a pre-release
#                                    (after - or ~) before the release
#   methods_version_at_least V MIN
#   methods_extract_version TEXT [REGEX]
#                                    the first group of REGEX (default: the
#                                    first dotted version) on the first
#                                    matching line of TEXT
# Methods. Each sets METHODS_STATUS (satisfied, installed, failed,
# not-managed or skipped) and METHODS_DETAIL; checks return 1 when failed,
# configuration errors die.
#   methods_check NAME PROFILE       --check-only semantics of the method
#   methods_official_binary_install NAME
#                                    user-level install (fresh and adopt)
#   methods_pypi_install NAME        user-level install (fresh and adopt) of
#                                    a Python application into its own
#                                    virtual environment
#   methods_deb_transaction NAME...  the fresh-mode deb transaction of the
#                                    given deb components (Linux): their
#                                    vendor APT sources and the local APT
#                                    bridge, then one apt transaction; sets
#                                    METHODS_DEB_STATUS[name] and
#                                    METHODS_DEB_DETAIL[name]
#   app-archive dispatches to platform_app_archive_install NAME and
#   platform_app_archive_check NAME of the platform layer, which set the same
#   variables; without them the method is not available.
# Hooks
#   methods_hooks LIST PROFILE       the hooks of LIST (system_install,
#                                    post_install, forbid, ...) to run in
#                                    PROFILE, one JSON object per line: early
#                                    before main before late, then
#                                    [components] order, then declaration
#                                    order; only components active in
#                                    PROFILE and hooks whose profiles
#                                    include it
#   methods_hook_path HOOK_JSON      the executable of a hook: <instance>/ and
#                                    <dotsteward>/ paths of a mirror are
#                                    resolved, <store>/ paths need a
#                                    generation
#   methods_run_hook HOOK_JSON PROFILE CHECK_ONLY [ARG...]
#                                    runs a hook with the hook environment
#                                    and the given arguments; returns its
#                                    exit status

_DS_METHODS_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

METHODS_STATUS=''
METHODS_DETAIL=''
declare -gA METHODS_DEB_STATUS=() METHODS_DEB_DETAIL=()

# --- Manifest -------------------------------------------------------------

methods_system() {
  local platform=${DS_RUNTIME_PLATFORM:-} system joined
  [[ -n $platform ]] || platform=$(current_platform) || exit 1
  for system in "${DS_NIX_SYSTEMS[@]}"; do
    if [[ $system == *-"$platform" ]]; then
      printf '%s\n' "$system"
      return 0
    fi
  done
  joined=$(printf '%s, ' "${DS_NIX_SYSTEMS[@]}")
  die "this $platform machine is not in nix.systems (${joined%, })"
}

methods_manifest_load() {
  (($# <= 1)) || die "usage: methods_manifest_load [GENERATION]"
  local generation=${1:-} system file json version described
  system=$(methods_system) || exit 1
  if [[ -n $generation ]]; then
    file=$generation/home-path/share/dotsteward/manifest.json
    [[ -f $file ]] || die "manifest not found: $file"
  else
    file=$DS_INSTANCE_ROOT/.dotsteward/manifest.$system.json
    [[ -f $file ]] || die "manifest not found: $file (run 'dotsteward sync' to regenerate the mirrors)"
  fi
  json=$(jq -ce 'select(type == "object")' "$file" 2>/dev/null) || die "invalid manifest: $file"
  version=$(jq -r '.schema_version' <<<"$json")
  [[ $version == 1 ]] || die "unsupported manifest schema_version $version: $file"
  described=$(jq -r '.system' <<<"$json")
  [[ $described == "$system" ]] || die "manifest $file describes $described, not $system"
  DS_MANIFEST_FILE=$file
  DS_MANIFEST_JSON=$json
}

_methods_manifest() {
  [[ -n ${DS_MANIFEST_JSON:-} ]] || die "${FUNCNAME[1]}: the manifest is not loaded"
  printf '%s\n' "$DS_MANIFEST_JSON"
}

methods_components() {
  (($# == 1)) || die "usage: methods_components PROFILE"
  _methods_manifest | jq -r --arg profile "$1" --arg platform "$DS_RUNTIME_PLATFORM" '
    .components[]
    | select((.modes // {}) | has($profile))
    | select(.platforms == null or (.platforms | index($platform)))
    | .name'
}

methods_component() {
  (($# == 1)) || die "usage: methods_component NAME"
  local entry
  entry=$(_methods_manifest | jq -c --arg name "$1" 'first(.components[] | select(.name == $name)) // empty')
  [[ -n $entry ]] || die "component $1 is not in the manifest $DS_MANIFEST_FILE"
  printf '%s\n' "$entry"
}

methods_component_method() {
  methods_component "$1" | jq -r '.method'
}

methods_is_system_level() {
  [[ $1 == deb || $1 == app-archive ]]
}

methods_validate() {
  (($# == 1)) || die "usage: methods_validate NAME"
  local name=$1 method
  method=$(methods_component_method "$name") || exit 1
  case $method in
    nix | official-binary | pypi | external) ;;
    deb)
      [[ $DS_RUNTIME_PLATFORM == linux ]] ||
        die "$name (deb): the deb method is not available on $DS_RUNTIME_PLATFORM"
      ;;
    app-archive)
      if ! declare -F platform_app_archive_install >/dev/null || ! declare -F platform_app_archive_check >/dev/null; then
        die "$name (app-archive): the app-archive method is not available on $DS_RUNTIME_PLATFORM"
      fi
      ;;
    *) die "$name: unknown install method: $method" ;;
  esac
}

# _methods_install_field NAME FILTER: jq -c FILTER over the component's
# install block.
_methods_install_field() {
  methods_component "$1" | jq -c ".install | $2"
}

# _methods_install_string NAME FIELD: a string field of the install block
# (empty for null).
_methods_install_string() {
  methods_component "$1" | jq -r --arg field "$2" '.install[$field] // empty | strings'
}

# --- Lock and versions ----------------------------------------------------

methods_lock_get() {
  (($# == 2)) || die "usage: methods_lock_get PATH COMPONENT"
  local path=$1 component=$2 file name value status=0
  file=$(config_instance_path "$DS_PINS_VERSIONS_LOCK") || exit 1
  name=${DS_PINS_VERSIONS_LOCK##*/}
  [[ -f $file ]] || die "$name not found: $file"
  value=$(jq -c --arg path "$path" '
    reduce ($path | split("."))[] as $key ({ found: true, value: . };
      if .found and (.value | type) == "object" and (.value | has($key))
      then .value = .value[$key] else .found = false end)
    | if .found then .value else error("missing") end' "$file" 2>/dev/null) || status=$?
  case $status in
    0) printf '%s\n' "$value" ;;
    5) die "$name lacks $path (required by component $component)" ;;
    *) die "cannot read $file" ;;
  esac
}

# _methods_pin_entry NAME METHOD PATH: the lock entry at PATH (an object).
_methods_pin_entry() {
  local entry
  entry=$(methods_lock_get "$3" "$1") || exit 1
  [[ $(jq -r 'type' <<<"$entry") == object ]] ||
    die "$1 ($2): ${DS_PINS_VERSIONS_LOCK##*/} $3 is not an entry"
  printf '%s\n' "$entry"
}

# _methods_pin_version NAME METHOD PATH ENTRY: minimum_version, else version.
_methods_pin_version() {
  local version
  version=$(jq -r '[.minimum_version, .version] | map(strings | select(length > 0)) | first // empty' <<<"$4")
  [[ -n $version ]] || die "$1 ($2): ${DS_PINS_VERSIONS_LOCK##*/} $3 lacks minimum_version (or version)"
  printf '%s\n' "$version"
}

# _methods_pin_download NAME METHOD PATH ENTRY: "URL SIZE SHA256".
_methods_pin_download() {
  local fields
  fields=$(jq -r 'if (.url | type) == "string" and (.size | type) == "number" and (.sha256 | type) == "string"
    then "\(.url) \(.size) \(.sha256)" else empty end' <<<"$4")
  [[ -n $fields ]] || die "$1 ($2): ${DS_PINS_VERSIONS_LOCK##*/} $3 lacks url, size or sha256"
  printf '%s\n' "$fields"
}

# _methods_version_parts VERSION: sets _vp_core (array of the dotted parts)
# and _vp_pre (array of the pre-release identifiers). A leading "v" and
# build metadata after "+" are ignored.
_methods_version_parts() {
  local version=${1#v} core pre=''
  version=${version%%+*}
  core=${version%%[-~]*}
  if [[ $core != "$version" ]]; then
    pre=${version:${#core}+1}
  fi
  IFS=. read -r -a _vp_core <<<"$core"
  _vp_pre=()
  if [[ -n $pre ]]; then
    IFS=. read -r -a _vp_pre <<<"$pre"
  fi
}

# _methods_compare_ids A B: one version part or pre-release identifier;
# numbers numerically and before words, words in byte order.
_methods_compare_ids() {
  local a=$1 b=$2
  if [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]]; then
    a=$((10#$a))
    b=$((10#$b))
    ((a < b)) && printf '%s\n' -1 && return
    ((a > b)) && printf '%s\n' 1 && return
    printf '0\n'
  elif [[ $a =~ ^[0-9]+$ ]]; then
    printf '%s\n' -1
  elif [[ $b =~ ^[0-9]+$ ]]; then
    printf '1\n'
  elif [[ $a == "$b" ]]; then
    printf '0\n'
  elif [[ $(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort | head -n 1) == "$a" ]]; then
    printf '%s\n' -1
  else
    printf '1\n'
  fi
}

methods_version_compare() {
  (($# == 2)) || die "usage: methods_version_compare A B"
  local -a a_core a_pre b_core b_pre _vp_core _vp_pre
  local i result
  _methods_version_parts "$1"
  a_core=("${_vp_core[@]}")
  a_pre=("${_vp_pre[@]}")
  _methods_version_parts "$2"
  b_core=("${_vp_core[@]}")
  b_pre=("${_vp_pre[@]}")
  for ((i = 0; i < ${#a_core[@]} || i < ${#b_core[@]}; i++)); do
    if ((i >= ${#a_core[@]})); then
      printf '%s\n' -1
      return
    elif ((i >= ${#b_core[@]})); then
      printf '1\n'
      return
    fi
    result=$(_methods_compare_ids "${a_core[i]}" "${b_core[i]}")
    if [[ $result != 0 ]]; then
      printf '%s\n' "$result"
      return
    fi
  done
  # A release sorts after its pre-releases.
  if ((${#a_pre[@]} == 0 || ${#b_pre[@]} == 0)); then
    printf '%s\n' $(((${#a_pre[@]} == 0) - (${#b_pre[@]} == 0)))
    return
  fi
  for ((i = 0; i < ${#a_pre[@]} || i < ${#b_pre[@]}; i++)); do
    if ((i >= ${#a_pre[@]})); then
      printf '%s\n' -1
      return
    elif ((i >= ${#b_pre[@]})); then
      printf '1\n'
      return
    fi
    result=$(_methods_compare_ids "${a_pre[i]}" "${b_pre[i]}")
    if [[ $result != 0 ]]; then
      printf '%s\n' "$result"
      return
    fi
  done
  printf '0\n'
}

methods_version_at_least() {
  (($# == 2)) || die "usage: methods_version_at_least VERSION MINIMUM"
  [[ -n $1 ]] || return 1
  [[ $(methods_version_compare "$1" "$2") != -1 ]]
}

methods_extract_version() {
  (($# == 1 || $# == 2)) || die "usage: methods_extract_version TEXT [REGEX]"
  local text=$1 regex=${2:-([0-9]+([.][0-9]+)+(-[0-9A-Za-z.]+)?)} line
  while IFS= read -r line; do
    if [[ $line =~ $regex ]]; then
      if ((${#BASH_REMATCH[@]} > 1)); then
        printf '%s\n' "${BASH_REMATCH[1]}"
      else
        printf '%s\n' "${BASH_REMATCH[0]}"
      fi
      return 0
    fi
  done <<<"$text"
  return 1
}

# _methods_command_version COMMAND_PATH REGEX ARG...: the version the
# command prints (empty when none); its exit status is ignored, as the
# version output alone decides.
_methods_command_version() {
  local command_path=$1 regex=$2 output
  shift 2
  output=$(timeout 60 "$command_path" "$@" 2>/dev/null </dev/null) || true
  methods_extract_version "$output" "$regex" || true
}

# _methods_join WORD...: the words separated by ", ".
_methods_join() {
  local joined
  (($#)) || return 0
  joined=$(printf '%s, ' "$@")
  printf '%s\n' "${joined%, }"
}

# shellcheck disable=SC2034 # the results are read by the callers
_methods_set() {
  METHODS_STATUS=$1
  METHODS_DETAIL=$2
}

# --- Checks ---------------------------------------------------------------

# methods_check NAME PROFILE [--managed]: checks NAME by its method;
# --managed checks a system-level method in adopt mode too (a component
# named with `install --component`).
methods_check() {
  [[ $# == 2 || ($# == 3 && $3 == --managed) ]] || die "usage: methods_check NAME PROFILE [--managed]"
  local name=$1 profile=$2 managed=${3:-} method mode
  method=$(methods_component_method "$name") || exit 1
  mode=${DS_PROFILE_MODE[$profile]:-}
  [[ -n $mode ]] || die "unknown profile: $profile"
  # Not managed whatever the platform offers.
  if [[ $mode == adopt && -z $managed ]] && methods_is_system_level "$method"; then
    _methods_set not-managed "system-level method in adopt mode"
    return 0
  fi
  methods_validate "$name"
  case $method in
    nix)
      _methods_set skipped "installed by Home Manager; checked by dotsteward probes"
      ;;
    deb) _methods_deb_check "$name" ;;
    official-binary) _methods_official_binary_check "$name" "$profile" ;;
    pypi) _methods_pypi_check "$name" "$profile" ;;
    external) _methods_external_check "$name" ;;
    app-archive) platform_app_archive_check "$name" ;;
  esac
}

# --- external -------------------------------------------------------------

_methods_external_check() {
  local name=$1 command minimum_path argv_json minimum value command_path found
  local -a argv=()
  command=$(_methods_install_string "$name" command)
  minimum_path=$(_methods_install_string "$name" minimum)
  if [[ -z $command ]]; then
    [[ -z $minimum_path ]] || die "$name (external): a minimum needs a command"
    _methods_set satisfied "nothing to check"
    return 0
  fi
  if ! command_path=$(command -v -- "$command" 2>/dev/null); then
    _methods_set failed "command $command not found"
    return 1
  fi
  if [[ -z $minimum_path ]]; then
    _methods_set satisfied "$command found"
    return 0
  fi
  value=$(methods_lock_get "$minimum_path" "$name") || exit 1
  minimum=$(jq -r 'if type == "string" then . elif type == "object" then
      ([.minimum_version, .version] | map(strings | select(length > 0)) | first // empty)
    else empty end' <<<"$value")
  [[ -n $minimum ]] ||
    die "$name (external): ${DS_PINS_VERSIONS_LOCK##*/} $minimum_path is not a version (a string, or an entry with minimum_version or version)"
  argv_json=$(_methods_install_field "$name" '.versionArgv // ["--version"]')
  mapfile -t argv < <(jq -r '.[]' <<<"$argv_json")
  found=$(_methods_command_version "$command_path" '' "${argv[@]}")
  if methods_version_at_least "$found" "$minimum"; then
    _methods_set satisfied "$command $found"
    return 0
  fi
  _methods_set failed "$command $minimum or newer is required (found ${found:-no version})"
  return 1
}

# --- official-binary ------------------------------------------------------

# _methods_official_binary_state NAME: reads the install block and the pin
# and finds the installed version. Sets _ob_* variables.
_methods_official_binary_state() {
  local name=$1 component
  component=$(methods_component "$name") || exit 1
  _ob_pin=$(jq -r '.install.pin // empty' <<<"$component")
  _ob_dest=$(jq -r '.install.dest // empty' <<<"$component")
  _ob_member=$(jq -r '.install.member // empty' <<<"$component")
  _ob_regex=$(jq -r '.install.versionRegex // empty' <<<"$component")
  _ob_policy=$(jq -r '.install.policy // "at-least"' <<<"$component")
  _ob_verify=$(jq -r '.install.verify // "sha256"' <<<"$component")
  mapfile -t _ob_argv < <(jq -r '(.install.versionArgv // ["--version"])[]' <<<"$component")
  [[ -n $_ob_pin && -n $_ob_dest ]] || die "$name (official-binary): the install block needs pin and dest"
  case $_ob_policy in
    at-least | exact) ;;
    *) die "$name (official-binary): unknown policy: $_ob_policy" ;;
  esac
  case $_ob_dest in
    \~/?*) _ob_dest=$HOME/${_ob_dest#\~/} ;;
    /?*) ;;
    *) die "$name (official-binary): dest must be ~/... or absolute: $_ob_dest" ;;
  esac
  _ob_command=${_ob_dest##*/}
  _ob_entry=$(_methods_pin_entry "$name" official-binary "$_ob_pin") || exit 1
  _ob_version=$(_methods_pin_version "$name" official-binary "$_ob_pin" "$_ob_entry") || exit 1
  # The command as the user runs it, with dest's directory first on PATH.
  _ob_found=''
  local command_path
  if command_path=$(PATH="${_ob_dest%/*}:$PATH" command -v -- "$_ob_command" 2>/dev/null); then
    _ob_found=$(_methods_command_version "$command_path" "$_ob_regex" "${_ob_argv[@]}")
  fi
}

# _methods_official_binary_ok VERSION: VERSION meets the pin by policy.
_methods_official_binary_ok() {
  [[ -n $1 ]] || return 1
  if [[ $_ob_policy == exact ]]; then
    [[ $(methods_version_compare "$1" "$_ob_version") == 0 ]]
  else
    methods_version_at_least "$1" "$_ob_version"
  fi
}

_methods_official_binary_wanted() {
  if [[ $_ob_policy == exact ]]; then
    printf '%s %s exactly' "$_ob_command" "$_ob_version"
  else
    printf '%s %s or newer' "$_ob_command" "$_ob_version"
  fi
}

_methods_official_binary_check() {
  local name=$1 profile=$2
  _methods_official_binary_state "$name"
  if _methods_official_binary_ok "$_ob_found"; then
    _methods_set satisfied "$_ob_command $_ob_found"
    return 0
  fi
  _methods_set failed "$(_methods_official_binary_wanted) not found (found ${_ob_found:-none}); run 'dotsteward rebuild --profile $profile --switch'"
  return 1
}

methods_official_binary_install() {
  (($# == 1)) || die "usage: methods_official_binary_install NAME"
  local name=$1 member download url size sha256 tmp_dir status=0 installed
  [[ $(methods_component_method "$name") == official-binary ]] ||
    die "$name: not an official-binary component"
  _methods_official_binary_state "$name"
  # A declared verification is never skipped silently.
  case $_ob_verify in
    sha256) ;;
    sha256+sigstore)
      die "$name (official-binary): verify = \"sha256+sigstore\" is not supported yet; use \"sha256\""
      ;;
    *) die "$name (official-binary): unknown verify: $_ob_verify" ;;
  esac
  member=${_ob_member//\{version\}/$_ob_version}
  [[ -n $member && $member != /* && /$member/ != */../* && /$member/ != */./* ]] ||
    die "$name (official-binary): invalid archive member: $member"
  if _methods_official_binary_ok "$_ob_found"; then
    _methods_set satisfied "$_ob_command $_ob_found"
    return 0
  fi
  if [[ -e $_ob_dest || -L $_ob_dest ]]; then
    [[ -f $_ob_dest && ! -L $_ob_dest ]] ||
      die "$name (official-binary): refusing to replace a symlink or non-regular file: $_ob_dest"
  fi
  download=$(_methods_pin_download "$name" official-binary "$_ob_pin" "$_ob_entry") || exit 1
  read -r url size sha256 <<<"$download"
  [[ $url == https://* ]] || die "$name (official-binary): refusing a non-HTTPS download URL: $url"

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-official-binary.XXXXXX") ||
    die "$name (official-binary): cannot create a temporary directory"
  (
    trap 'cleanup_temp_dir "$tmp_dir"' EXIT
    _methods_official_binary_fetch "$name" "$url" "$size" "$sha256" "$member" "$tmp_dir"
  ) || status=$?
  ((status == 0)) || exit "$status"

  installed=$(_methods_command_version "$_ob_dest" "$_ob_regex" "${_ob_argv[@]}")
  _methods_official_binary_ok "$installed" ||
    die "$name (official-binary): $(_methods_official_binary_wanted) not found after the install (found ${installed:-none})"
  _methods_set installed "$_ob_command $installed"
}

# _methods_official_binary_fetch NAME URL SIZE SHA256 MEMBER TMP_DIR: runs
# in a subshell that removes TMP_DIR; downloads, extracts, backs up the old
# file and installs the member at _ob_dest. The subshell is the left operand
# of `||`, where bash ignores errexit, so every step checks its own status.
_methods_official_binary_fetch() {
  local name=$1 url=$2 size=$3 sha256=$4 member=$5 tmp_dir=$6 asset source status=0 backup_root
  asset=${url%%[?#]*}
  asset=${asset##*/}
  [[ -n $asset ]] || asset=download
  log "$name (official-binary): downloading $url"
  download_verified "$url" "$tmp_dir/$asset" "$size" "$sha256" || status=$?
  ((status == 0)) || die "$name (official-binary): download failed (curl exit $status): $url"
  mkdir -p -- "$tmp_dir/extracted" || die "$name (official-binary): cannot create $tmp_dir/extracted"
  case $asset in
    *.tar.gz | *.tgz) tar -xzf "$tmp_dir/$asset" -C "$tmp_dir/extracted" || status=$? ;;
    *.tar.xz | *.txz) tar -xJf "$tmp_dir/$asset" -C "$tmp_dir/extracted" || status=$? ;;
    *.tar.bz2 | *.tbz2) tar -xjf "$tmp_dir/$asset" -C "$tmp_dir/extracted" || status=$? ;;
    *.tar) tar -xf "$tmp_dir/$asset" -C "$tmp_dir/extracted" || status=$? ;;
    *.zip)
      require_command unzip
      unzip -q "$tmp_dir/$asset" -d "$tmp_dir/extracted" || status=$?
      ;;
    *) member='' ;;
  esac
  ((status == 0)) || die "$name (official-binary): cannot extract $asset (exit $status)"
  if [[ -n $member ]]; then
    source=$tmp_dir/extracted/$member
    [[ -f $source && ! -L $source && -x $source ]] ||
      die "$name (official-binary): archive member $member is not an executable regular file in $url"
  else
    source=$tmp_dir/$asset
  fi
  if [[ -f $_ob_dest ]]; then
    backup_root="$(state_root)/backups/$(timestamp_utc)"
    ensure_private_dir "$backup_root" || die "$name (official-binary): cannot create $backup_root"
    backup_file_private "$_ob_dest" "$backup_root" ||
      die "$name (official-binary): backup of $_ob_dest failed; nothing was replaced"
    log "$name (official-binary): previous $_ob_dest backed up in $backup_root"
  fi
  install -D -m 0755 -- "$source" "$_ob_dest" || die "$name (official-binary): cannot install $_ob_dest"
}

# --- pypi -----------------------------------------------------------------

# _methods_pypi_expand NAME FIELD VALUE: VALUE (~/... or absolute) as an
# absolute path.
_methods_pypi_expand() {
  case $3 in
    \~/?*) printf '%s\n' "$HOME/${3#\~/}" ;;
    /?*) printf '%s\n' "$3" ;;
    *) die "$1 (pypi): $2 must be ~/... or absolute: $3" ;;
  esac
}

# _methods_pypi_state NAME: reads the install block and the pin and finds the
# installed version. Sets _py_* variables.
_methods_pypi_state() {
  local name=$1 component script
  component=$(methods_component "$name") || exit 1
  _py_pin=$(jq -r '.install.pin // empty' <<<"$component")
  _py_dist=$(jq -r '.install.distribution // empty' <<<"$component")
  _py_requirements=$(jq -r '.install.requirements // empty' <<<"$component")
  _py_python=$(jq -r '.install.python // "python3"' <<<"$component")
  _py_venv_text=$(jq -r '.install.venv // empty' <<<"$component")
  _py_link_text=$(jq -r '.install.linkDir // "~/.local/bin"' <<<"$component")
  mapfile -t _py_bin < <(jq -r '(.install.bin // [])[]' <<<"$component")
  [[ -n $_py_pin && -n $_py_dist && -n $_py_requirements && -n $_py_venv_text ]] ||
    die "$name (pypi): the install block needs pin, distribution, requirements and venv"
  [[ $_py_dist =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] ||
    die "$name (pypi): invalid distribution name: $_py_dist"
  _py_venv=$(_methods_pypi_expand "$name" venv "$_py_venv_text") || exit 1
  _py_link_dir=$(_methods_pypi_expand "$name" linkDir "$_py_link_text") || exit 1
  for script in "${_py_bin[@]}"; do
    [[ $script =~ ^[A-Za-z0-9_][A-Za-z0-9_.+-]*$ ]] || die "$name (pypi): invalid console script name: $script"
  done
  _py_entry=$(_methods_pin_entry "$name" pypi "$_py_pin") || exit 1
  _py_version=$(_methods_pin_version "$name" pypi "$_py_pin" "$_py_entry") || exit 1
  _py_found=$(_methods_pypi_installed)
}

# _methods_pypi_installed: the version of the distribution in the virtual
# environment (empty when there is none or its interpreter does not run).
_methods_pypi_installed() {
  [[ -x $_py_venv/bin/python ]] || return 0
  timeout 60 "$_py_venv/bin/python" -I -c '
import importlib.metadata, sys
try:
    print(importlib.metadata.version(sys.argv[1]))
except importlib.metadata.PackageNotFoundError:
    pass' "$_py_dist" 2>/dev/null </dev/null || true
}

_methods_pypi_version_ok() {
  [[ -n $_py_found && $(methods_version_compare "$_py_found" "$_py_version") == 0 ]]
}

# _methods_pypi_links_ok: every console script link points at its script in
# the environment; else sets _py_bad_link (as written in linkDir) and
# _py_bad_target and returns 1.
_methods_pypi_links_ok() {
  local script link target
  for script in "${_py_bin[@]}"; do
    link=$_py_link_dir/$script
    target=$_py_venv/bin/$script
    if [[ ! -L $link || $(readlink -- "$link") != "$target" || ! -x $target ]]; then
      _py_bad_link=$_py_link_text/$script
      _py_bad_target=$target
      return 1
    fi
  done
}

_methods_pypi_check() {
  local name=$1 profile=$2 hint
  _methods_pypi_state "$name"
  hint="run 'dotsteward rebuild --profile $profile --switch'"
  if ! _methods_pypi_version_ok; then
    _methods_set failed "$_py_dist $_py_version not found in $_py_venv_text (found ${_py_found:-none}); $hint"
    return 1
  fi
  if ! _methods_pypi_links_ok; then
    _methods_set failed "$_py_bad_link does not link to $_py_bad_target; $hint"
    return 1
  fi
  _methods_set satisfied "$_py_dist $_py_found"
}

# _methods_pypi_pinned FILE: FILE has a requirement line that pins the
# distribution (any spelling its normalized name allows) at the pin's
# version, or a direct reference to it (`NAME @ URL`, which the required
# hash fixes to one archive; the installed version is checked afterwards).
_methods_pypi_pinned() {
  local name_re version_re
  name_re=$(sed -E 's/[-_.]+/[-_.]+/g' <<<"$_py_dist")
  version_re=${_py_version//./[.]}
  grep -qiE "^[[:space:]]*${name_re}[[:space:]]*(==[[:space:]]*${version_re}([[:space:];\\]|\$)|@[[:space:]]*[^[:space:]])" -- "$1"
}

# _methods_pypi_create NAME: creates the virtual environment with the
# interpreter of the install block, found and run on the user's PATH (a
# version-manager shim looks the real interpreter up on PATH, which must
# not reach the CLI's own toolchain); an interpreter whose base prefix is in
# the Nix store is refused, since the environment would break when that
# store path is garbage-collected.
_methods_pypi_create() {
  local name=$1 python_path base store=${NIX_STORE_DIR:-/nix/store} status=0 output
  if [[ $_py_python == /* ]]; then
    [[ -x $_py_python ]] || die "$name (pypi): $_py_python not found"
    python_path=$_py_python
  else
    python_path=$(PATH=$(user_path) command -v -- "$_py_python") ||
      die "$name (pypi): $_py_python not found on PATH"
  fi
  base=$(timeout 60 env PATH="$(user_path)" "$python_path" -I -c 'import sys; print(sys.base_prefix)' 2>/dev/null </dev/null) ||
    die "$name (pypi): the interpreter $_py_python does not run"
  case $base/ in
    "${store%/}"/*)
      die "$name (pypi): the interpreter $_py_python lives in the Nix store ($base); an environment created from it breaks when that store path is garbage-collected; set install.pypi.python to an interpreter outside the store"
      ;;
  esac
  mkdir -p -- "${_py_venv%/*}" || die "$name (pypi): cannot create ${_py_venv%/*}"
  log "$name (pypi): creating the virtual environment $_py_venv with $python_path"
  output=$(timeout 300 env PATH="$(user_path)" "$python_path" -I -m venv -- "$_py_venv" 2>&1 </dev/null) || status=$?
  ((status == 0)) ||
    die "$name (pypi): cannot create the virtual environment $_py_venv (exit $status; on Debian and Ubuntu the python3-venv package provides the venv module): $(tail -n 3 <<<"$output")"
}

methods_pypi_install() {
  (($# == 1)) || die "usage: methods_pypi_install NAME"
  local name=$1 requirements script link target status=0 output
  [[ $(methods_component_method "$name") == pypi ]] || die "$name: not a pypi component"
  _methods_pypi_state "$name"
  if _methods_pypi_version_ok && _methods_pypi_links_ok; then
    _methods_set satisfied "$_py_dist $_py_found"
    return 0
  fi
  requirements=$(_methods_manifest_path "$name (pypi): requirements" "$_py_requirements") || exit 1
  [[ -f $requirements ]] || die "$name (pypi): requirements file not found: $requirements"
  _methods_pypi_pinned "$requirements" || die "$name (pypi): $requirements does not pin $_py_dist==$_py_version"
  # A file that is not a link into the environment is never replaced.
  for script in "${_py_bin[@]}"; do
    link=$_py_link_dir/$script
    if [[ -e $link || -L $link ]] && [[ ! -L $link || $(readlink -- "$link") != "$_py_venv"/* ]]; then
      die "$name (pypi): refusing to replace $link, which is not a link into $_py_venv"
    fi
  done
  # An existing environment is kept: packages the application installed into
  # it survive a new pin.
  if [[ ! -e $_py_venv/bin/python && ! -L $_py_venv/bin/python ]]; then
    _methods_pypi_create "$name"
  elif ! timeout 60 "$_py_venv/bin/python" -I -c '' >/dev/null 2>&1 </dev/null; then
    die "$name (pypi): the virtual environment $_py_venv does not run; remove it and run 'dotsteward agents install' again"
  fi
  log "$name (pypi): installing $_py_dist $_py_version into $_py_venv"
  output=$(timeout 900 "$_py_venv/bin/python" -I -m pip install --no-input --disable-pip-version-check \
    --require-hashes -r "$requirements" 2>&1 </dev/null) || status=$?
  ((status == 0)) || die "$name (pypi): pip install failed (exit $status): $(tail -n 5 <<<"$output")"
  _py_found=$(_methods_pypi_installed)
  _methods_pypi_version_ok ||
    die "$name (pypi): $_py_dist $_py_version not found in $_py_venv after the install (found ${_py_found:-none})"
  for script in "${_py_bin[@]}"; do
    link=$_py_link_dir/$script
    target=$_py_venv/bin/$script
    [[ -f $target && -x $target ]] || die "$name (pypi): the environment has no console script $script: $target"
    [[ -L $link && $(readlink -- "$link") == "$target" ]] && continue
    mkdir -p -- "$_py_link_dir" || die "$name (pypi): cannot create $_py_link_dir"
    rm -f -- "$link"
    ln -s -- "$target" "$link" || die "$name (pypi): cannot link $link"
  done
  _methods_set installed "$_py_dist $_py_found"
}

# --- deb ------------------------------------------------------------------

# _methods_deb_block NAME: sets _deb_pin, _deb_names, _deb_arch,
# _deb_verify, _deb_apt, _deb_sources (one JSON object per vendor APT
# source), _deb_release (the githubRelease JSON object, or empty) and, with
# a pin, _deb_entry and _deb_floor.
_methods_deb_block() {
  local name=$1 component
  component=$(methods_component "$name") || exit 1
  _deb_pin=$(jq -r '.install.pin // empty' <<<"$component")
  _deb_arch=$(jq -r '.install.architecture // empty' <<<"$component")
  _deb_verify=$(jq -r 'if .install.verifyAfterInstall == false then "false" else "true" end' <<<"$component")
  mapfile -t _deb_names < <(jq -r '(.install.packageNames // [])[]' <<<"$component")
  mapfile -t _deb_apt < <(jq -r '(.install.apt // [])[]' <<<"$component")
  mapfile -t _deb_sources < <(jq -c '(.install.aptSources // [])[]' <<<"$component")
  _deb_release=$(jq -c '.install.githubRelease // empty' <<<"$component")
  _deb_entry=''
  _deb_floor=''
  if [[ -n $_deb_pin ]]; then
    ((${#_deb_names[@]})) || die "$name (deb): a pin needs packageNames"
    _deb_entry=$(_methods_pin_entry "$name" deb "$_deb_pin") || exit 1
    _deb_floor=$(_methods_pin_version "$name" deb "$_deb_pin" "$_deb_entry") || exit 1
  fi
}

# _methods_deb_floor_met: prints "PACKAGE VERSION" of the first installed
# package name at or above the floor; status 1 (printing the first
# installed version, if any) when none is. A package removed but not purged
# (dpkg state config-files) keeps its version in the dpkg database and is
# not installed.
_methods_deb_floor_met() {
  local package version first=''
  for package in "${_deb_names[@]}"; do
    dpkg_installed "$package" || continue
    version=$(dpkg_version "$package")
    [[ -n $version ]] || continue
    if dpkg --compare-versions "$version" ge "$_deb_floor"; then
      printf '%s %s\n' "$package" "$version"
      return 0
    fi
    [[ -n $first ]] || first="$package $version"
  done
  printf '%s\n' "$first"
  return 1
}

# _methods_deb_found MET: the version part of a _methods_deb_floor_met
# answer, "none" when nothing is installed.
_methods_deb_found() {
  if [[ -n $1 ]]; then
    printf '%s\n' "${1#* }"
  else
    printf 'none\n'
  fi
}

_methods_deb_requirements() {
  require_command dpkg-query
  require_command dpkg
}

# --- Vendor APT sources ----------------------------------------------------
#
# install.aptSources of a deb component: a deb822 file
# <apt>/sources.list.d/<name>.sources whose Signed-By is the keyring
# <apt>/keyrings/<name>.asc (<apt> is DOTSTEWARD_APT_DIR, else /etc/apt).
# The keyring must hold exactly one primary key, the pinned fingerprint.

_methods_apt_dir() {
  printf '%s\n' "${DOTSTEWARD_APT_DIR:-/etc/apt}"
}

# _methods_apt_source_paths SOURCE_JSON: sets _src_name, _src_file,
# _src_keyring, _src_fpr and _src_key_url.
_methods_apt_source_paths() {
  local dir
  dir=$(_methods_apt_dir)
  _src_name=$(jq -r .name <<<"$1")
  _src_file=$dir/sources.list.d/$_src_name.sources
  _src_keyring=$dir/keyrings/$_src_name.asc
  _src_fpr=$(jq -r .keyFingerprint <<<"$1")
  _src_key_url=$(jq -r .keyUrl <<<"$1")
}

# _methods_apt_source_text SOURCE_JSON: the deb822 stanza of the source;
# {codename} in a suite is VERSION_CODENAME of os-release.
_methods_apt_source_text() {
  local source=$1 codename='' keyring
  if jq -e 'any(.suites[]; contains("{codename}"))' <<<"$source" >/dev/null; then
    codename=$(os_release_value VERSION_CODENAME) || exit 1
    [[ -n $codename ]] || die "apt source $(jq -r .name <<<"$source"): os-release has no VERSION_CODENAME for {codename}"
  fi
  keyring=$(_methods_apt_dir)/keyrings/$(jq -r .name <<<"$source").asc
  jq -r --arg codename "$codename" --arg keyring "$keyring" '
    "Types: deb",
    "URIs: \(.uri)",
    "Suites: \(.suites | map(gsub("\\{codename\\}"; $codename)) | join(" "))",
    (if (.components // []) != [] then "Components: \(.components | join(" "))" else empty end),
    (if (.architectures // []) != [] then "Architectures: \(.architectures | join(" "))" else empty end),
    "Signed-By: \($keyring)"' <<<"$source"
}

# _methods_key_fingerprints FILE: the primary key fingerprints of an
# OpenPGP key file, one per line (none for a file gpg cannot read).
_methods_key_fingerprints() {
  local file=$1 home status=0
  require_command gpg
  home=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-gpg.XXXXXX") ||
    die "cannot create a temporary directory for gpg"
  gpg --batch --no-tty --homedir "$home" --with-colons --show-keys -- "$file" 2>/dev/null |
    awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print $10; primary = 0 }' ||
    status=$?
  cleanup_temp_dir "$home"
  ((status == 0)) || return 0
}

# _methods_key_is FILE FINGERPRINT: FILE holds exactly the one key.
_methods_key_is() {
  [[ -f $1 && $(_methods_key_fingerprints "$1") == "$2" ]]
}

# _methods_apt_source_check NAME: the --check-only part of the sources.
_methods_apt_source_check() {
  local name=$1 source
  for source in "${_deb_sources[@]}"; do
    _methods_apt_source_paths "$source"
    if [[ ! -f $_src_file ]]; then
      _methods_set failed "apt source $_src_name is not configured ($_src_file)"
      return 1
    fi
    if [[ $(<"$_src_file") != "$(_methods_apt_source_text "$source")" ]]; then
      _methods_set failed "apt source $_src_name differs from the component ($_src_file)"
      return 1
    fi
    if ! _methods_key_is "$_src_keyring" "$_src_fpr"; then
      _methods_set failed "the keyring of apt source $_src_name does not hold exactly the key $_src_fpr ($_src_keyring)"
      return 1
    fi
  done
}

# --- Local APT bridge ------------------------------------------------------
#
# install.githubRelease of a deb component: the vendor publishes DEBs as
# assets of GitHub releases but runs no APT repository. The DEB of the
# newest release is served from a local flat repository that the bridge
# script (cli/libexec/apt-bridge.sh) refreshes before every `apt update`,
# so the package updates with plain `apt upgrade`. The bridge consists of
# the script, one configuration per package, an APT::Update::Pre-Invoke
# hook and a trusted file: source; all files are root-owned and mode 0644.
# Paths outside <apt> are below DOTSTEWARD_SYSTEM_ROOT (default: /).

# _methods_bridge_paths: sets _bridge_script, _bridge_conf_dir,
# _bridge_repo, _bridge_hook and _bridge_source.
_methods_bridge_paths() {
  local root=${DOTSTEWARD_SYSTEM_ROOT:-} apt
  apt=$(_methods_apt_dir)
  _bridge_script=$root/usr/local/lib/dotsteward/apt-bridge.sh
  _bridge_conf_dir=$root/etc/dotsteward/apt-bridge.d
  _bridge_repo=$root/var/lib/dotsteward/apt-bridge
  _bridge_hook=$apt/apt.conf.d/60dotsteward-apt-bridge
  _bridge_source=$apt/sources.list.d/dotsteward-apt-bridge.sources
}

# The bridge script shipped with the framework.
_methods_bridge_source_script() {
  printf '%s\n' "$_DS_METHODS_LIB_DIR/../libexec/apt-bridge.sh"
}

_methods_bridge_hook_text() {
  printf '%s\n' "// Written by dotsteward: refreshes the local APT bridge before every update." \
    "APT::Update::Pre-Invoke { \"if [ -f $_bridge_script ]; then /bin/bash $_bridge_script $_bridge_conf_dir $_bridge_repo || true; fi\"; };"
}

_methods_bridge_source_text() {
  printf '%s\n' "Types: deb" "URIs: file:$_bridge_repo" "Suites: ./" "Trusted: yes"
}

# _methods_bridge_plan NAME: for the component of the last _methods_deb_block,
# sets _bridge_conf (its configuration path), _bridge_conf_text,
# _bridge_label (repository and asset) and _bridge_paths.
_methods_bridge_plan() {
  local name=$1 arch asset
  _methods_bridge_paths
  ((${#_deb_names[@]})) || die "$name (deb): githubRelease needs packageNames (the first one is served)"
  arch=$(dpkg --print-architecture) || die "$name (deb): cannot read the dpkg architecture"
  asset=$(jq -r --arg arch "$arch" '.assets[$arch] // empty' <<<"$_deb_release")
  [[ -n $asset ]] || die "$name (deb): githubRelease names no asset for architecture $arch"
  _bridge_conf=$_bridge_conf_dir/${_deb_names[0]}.conf
  _bridge_conf_text=$(jq -r --arg package "${_deb_names[0]}" --arg arch "$arch" --arg asset "$asset" '
    "package=\($package)",
    "architecture=\($arch)",
    "url=https://github.com/\(.repository)/releases/latest/download",
    "asset=\($asset)",
    "checksums=\(.checksums // "SHA256SUMS.txt")"' <<<"$_deb_release")
  _bridge_label="$(jq -r .repository <<<"$_deb_release"), $asset"
}

# _methods_bridge_differs TARGET TEXT|-: status 0 when TARGET is missing or
# differs from TEXT (- compares with the framework's bridge script).
_methods_bridge_differs() {
  [[ -f $1 ]] || return 0
  if [[ $2 == - ]]; then
    [[ $(<"$1") != "$(<"$(_methods_bridge_source_script)")" ]]
  else
    [[ $(<"$1") != "$2" ]]
  fi
}

# _methods_bridge_check NAME: the --check-only part of the bridge.
_methods_bridge_check() {
  local name=$1 target text i
  [[ -n $_deb_release ]] || return 0
  _methods_bridge_plan "$name"
  local -a targets=("$_bridge_script" "$_bridge_conf" "$_bridge_hook" "$_bridge_source")
  local -a texts=(- "$_bridge_conf_text" "$(_methods_bridge_hook_text)" "$(_methods_bridge_source_text)")
  for i in "${!targets[@]}"; do
    target=${targets[i]}
    text=${texts[i]}
    if [[ ! -f $target ]]; then
      _methods_set failed "apt bridge file $target is missing"
      return 1
    fi
    if _methods_bridge_differs "$target" "$text"; then
      _methods_set failed "apt bridge file $target differs from the component"
      return 1
    fi
  done
  if ! dpkg_installed curl; then
    _methods_set failed "apt package curl is not installed (the apt bridge runs it)"
    return 1
  fi
}

_methods_deb_check() {
  local name=$1 met package
  _methods_deb_requirements
  _methods_deb_block "$name"
  _methods_apt_source_check "$name" || return 1
  _methods_bridge_check "$name" || return 1
  if [[ -n $_deb_pin ]] && ! met=$(_methods_deb_floor_met); then
    _methods_set failed "${_deb_names[0]} $_deb_floor or newer is not installed (found $(_methods_deb_found "$met"))"
    return 1
  fi
  for package in "${_deb_apt[@]}"; do
    if ! dpkg_installed "$package"; then
      _methods_set failed "apt package $package is not installed"
      return 1
    fi
  done
  if [[ -n $_deb_pin ]]; then
    _methods_set satisfied "$met"
  else
    _methods_set satisfied "$(_methods_join "${_deb_apt[@]}")"
  fi
}

# shellcheck disable=SC2034 # METHODS_DEB_* are read by the callers
methods_deb_transaction() {
  local name package met tmp_dir status=0 queued existing download url size sha256 detail
  local -a names=("$@") apt_queue=() deb_names=() deb_urls=() deb_sizes=() deb_sha=() deb_files=()
  local -a deb_expected=() deb_arch=()
  local -a src_components=() src_json=() src_text=() src_key=()
  local -A component_apt=() component_deb=() component_src=() component_bridge=() src_seen=()
  local -a bridge_components=() bridge_targets=() bridge_files=() bridge_texts=()
  local source text bridged=0
  METHODS_DEB_STATUS=()
  METHODS_DEB_DETAIL=()
  ((${#names[@]})) || return 0
  _methods_deb_requirements
  require_command dpkg-deb

  # Plan: the DEBs below their floor and the missing apt packages, in
  # [components] order, without any change.
  for name in "${names[@]}"; do
    [[ $(methods_component_method "$name") == deb ]] || die "$name: not a deb component"
    _methods_deb_block "$name"
    if [[ -n $_deb_pin ]] && ! _methods_deb_floor_met >/dev/null; then
      download=$(_methods_pin_download "$name" deb "$_deb_pin" "$_deb_entry") || exit 1
      read -r url size sha256 <<<"$download"
      deb_names+=("$name")
      deb_urls+=("$url")
      deb_sizes+=("$size")
      deb_sha+=("$sha256")
      deb_files+=("${name}_${_deb_floor//[^A-Za-z0-9.+~-]/_}.deb")
      deb_expected+=("${_deb_names[*]}")
      deb_arch+=("$_deb_arch")
      component_deb[$name]=1
    fi
    for source in "${_deb_sources[@]}"; do
      _methods_apt_source_paths "$source"
      if [[ -n ${src_seen[$_src_name]:-} ]]; then
        [[ ${src_seen[$_src_name]} == "$source" ]] ||
          die "$name (deb): apt source $_src_name is declared again with other values"
        continue
      fi
      src_seen[$_src_name]=$source
      text=$(_methods_apt_source_text "$source") || exit 1
      if _methods_key_is "$_src_keyring" "$_src_fpr"; then
        [[ -f $_src_file && $(<"$_src_file") == "$text" ]] && continue
        src_key+=(0)
      else
        src_key+=(1)
      fi
      src_components+=("$name")
      src_json+=("$source")
      src_text+=("$text")
      component_src[$name]=1
    done
    if [[ -n $_deb_release ]]; then
      _methods_bridge_plan "$name"
      if ((!bridged)) && _methods_bridge_differs "$_bridge_script" -; then
        bridge_components+=("$name")
        bridge_targets+=("$_bridge_script")
        bridge_files+=(apt-bridge.sh)
        bridge_texts+=(-)
        component_bridge[$name]=$_bridge_label
      fi
      bridged=1
      if _methods_bridge_differs "$_bridge_conf" "$_bridge_conf_text"; then
        bridge_components+=("$name")
        bridge_targets+=("$_bridge_conf")
        bridge_files+=("${_deb_names[0]}.conf")
        bridge_texts+=("$_bridge_conf_text")
        component_bridge[$name]=$_bridge_label
      fi
      # The bridge script runs the system curl as root.
      _deb_apt+=(curl)
    fi
    for package in "${_deb_apt[@]}"; do
      dpkg_installed "$package" && continue
      component_apt[$name]+="${component_apt[$name]:+ }$package"
      queued=0
      for existing in "${apt_queue[@]}"; do
        [[ $existing == "$package" ]] && queued=1
      done
      ((queued)) || apt_queue+=("$package")
    done
  done

  # The shared hook and source of the bridge, once for every component.
  if ((bridged)); then
    text=$(_methods_bridge_hook_text)
    if _methods_bridge_differs "$_bridge_hook" "$text"; then
      bridge_components+=("")
      bridge_targets+=("$_bridge_hook")
      bridge_files+=(60dotsteward-apt-bridge)
      bridge_texts+=("$text")
    fi
    text=$(_methods_bridge_source_text)
    if _methods_bridge_differs "$_bridge_source" "$text"; then
      bridge_components+=("")
      bridge_targets+=("$_bridge_source")
      bridge_files+=(dotsteward-apt-bridge.sources)
      bridge_texts+=("$text")
    fi
  fi

  # Download and verify every signing key and DEB before the first sudo
  # call, then the sources, the bridge and one transaction. The subshell is
  # the left operand of `||`, where bash ignores errexit, so every step
  # checks its own status.
  if ((${#apt_queue[@]} || ${#deb_names[@]} || ${#src_json[@]} || ${#bridge_targets[@]})); then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-install.XXXXXX") ||
      die "cannot create a temporary directory for the deb transaction"
    (
      trap 'cleanup_temp_dir "$tmp_dir"' EXIT
      local i file field found found_keys=() paths=() shown=()
      for i in "${!src_json[@]}"; do
        name=${src_components[i]}
        _methods_apt_source_paths "${src_json[i]}"
        printf '%s\n' "${src_text[i]}" >"$tmp_dir/$_src_name.sources"
        ((src_key[i])) || continue
        file=$tmp_dir/$_src_name.asc
        log "$name (deb): downloading the signing key $_src_key_url"
        status=0
        download_https "$_src_key_url" "$file" || status=$?
        ((status == 0)) || die "$name (deb): signing key download failed (curl exit $status): $_src_key_url"
        found=$(_methods_key_fingerprints "$file")
        if [[ $found != "$_src_fpr" ]]; then
          mapfile -t found_keys <<<"${found:-none}"
          die "$name (deb): the signing key at $_src_key_url is not exactly the key $_src_fpr (found $(_methods_join "${found_keys[@]}"))"
        fi
      done
      for i in "${!deb_names[@]}"; do
        name=${deb_names[i]}
        [[ ${deb_urls[i]} == https://* ]] ||
          die "$name (deb): refusing a non-HTTPS download URL: ${deb_urls[i]}"
        file=$tmp_dir/${deb_files[i]}
        log "$name (deb): downloading ${deb_urls[i]}"
        status=0
        download_verified "${deb_urls[i]}" "$file" "${deb_sizes[i]}" "${deb_sha[i]}" || status=$?
        ((status == 0)) || die "$name (deb): download failed (curl exit $status): ${deb_urls[i]}"
        field=$(deb_field "$file" Package) || die "$name (deb): cannot read the Package field of ${deb_urls[i]}"
        [[ " ${deb_expected[i]} " == *" $field "* ]] ||
          die "$name (deb): unexpected package $field in ${deb_urls[i]} (expected ${deb_expected[i]// /, })"
        if [[ -n ${deb_arch[i]} ]]; then
          field=$(deb_field "$file" Architecture) || die "$name (deb): cannot read the Architecture field of ${deb_urls[i]}"
          [[ $field == "${deb_arch[i]}" ]] ||
            die "$name (deb): unexpected architecture $field in ${deb_urls[i]} (expected ${deb_arch[i]})"
        fi
        paths+=("$file")
        shown+=("${deb_files[i]}")
      done
      for i in "${!src_json[@]}"; do
        name=${src_components[i]}
        _methods_apt_source_paths "${src_json[i]}"
        if ((src_key[i])); then
          sudo install -D -o root -g root -m 0644 "$tmp_dir/$_src_name.asc" "$_src_keyring" ||
            die "$name (deb): cannot write the keyring $_src_keyring"
        fi
        sudo install -D -o root -g root -m 0644 "$tmp_dir/$_src_name.sources" "$_src_file" ||
          die "$name (deb): cannot write the apt source $_src_file"
        log "$name (deb): apt source $_src_name: $(sed -nE 's/^(URIs|Suites|Components): //p' <<<"${src_text[i]}" | paste -sd ' ')"
      done
      for i in "${!bridge_targets[@]}"; do
        file=$tmp_dir/${bridge_files[i]}
        if [[ ${bridge_texts[i]} == - ]]; then
          cp -- "$(_methods_bridge_source_script)" "$file" || die "cannot stage the apt bridge script"
        else
          printf '%s\n' "${bridge_texts[i]}" >"$file"
        fi
        sudo install -D -o root -g root -m 0644 "$file" "${bridge_targets[i]}" ||
          die "${bridge_components[i]:-apt bridge}${bridge_components[i]:+ (deb)}: cannot write ${bridge_targets[i]}"
      done
      for name in "${names[@]}"; do
        if [[ -n ${component_bridge[$name]:-} ]]; then
          log "$name (deb): apt bridge: ${component_bridge[$name]}"
        fi
      done
      local listing=("${apt_queue[@]}" "${shown[@]}")
      if ((${#listing[@]})); then
        log "installing system packages: ${listing[*]}"
      fi
      apt_update || die "apt-get update failed; nothing was installed"
      if ((${#listing[@]})); then
        apt_install "${apt_queue[@]}" "${paths[@]}" || die "apt-get install failed"
      fi
    ) || status=$?
    ((status == 0)) || exit "$status"
  fi

  # Verify the floors and the apt packages.
  for name in "${names[@]}"; do
    _methods_deb_block "$name"
    [[ -z $_deb_release ]] || _deb_apt+=(curl)
    detail=''
    if [[ -n $_deb_pin ]]; then
      if met=$(_methods_deb_floor_met); then
        detail=$met
      elif [[ $_deb_verify == true ]]; then
        die "$name (deb): ${_deb_names[0]} $_deb_floor or newer is not installed after the transaction (found $(_methods_deb_found "$met"))"
      else
        detail="${met:-${_deb_names[0]} none} (not verified)"
      fi
    fi
    if [[ $_deb_verify == true ]]; then
      for package in "${_deb_apt[@]}"; do
        dpkg_installed "$package" ||
          die "$name (deb): apt package $package is not installed after the transaction"
      done
    fi
    if [[ -n ${component_deb[$name]:-} || -n ${component_apt[$name]:-} || -n ${component_src[$name]:-} ||
      -n ${component_bridge[$name]:-} ]]; then
      METHODS_DEB_STATUS[$name]=installed
      if [[ -n $_deb_pin && -n ${component_apt[$name]:-} ]]; then
        detail+=", ${component_apt[$name]// /, }"
      elif [[ -z $_deb_pin && -n ${component_apt[$name]:-} ]]; then
        detail=${component_apt[$name]// /, }
      elif [[ -z $_deb_pin ]]; then
        if [[ -n $_deb_release ]]; then
          detail="apt bridge; $(_methods_join "${_deb_apt[@]}")"
        else
          detail="apt sources; $(_methods_join "${_deb_apt[@]}")"
        fi
      fi
    else
      METHODS_DEB_STATUS[$name]=satisfied
      [[ -n $_deb_pin ]] || detail=$(_methods_join "${_deb_apt[@]}")
    fi
    METHODS_DEB_DETAIL[$name]=$detail
  done
}

# --- Hooks ----------------------------------------------------------------

methods_hooks() {
  (($# == 2)) || die "usage: methods_hooks LIST PROFILE"
  local list=$1 profile=$2 active
  active=$(methods_components "$profile" | jq -R . | jq -cs .) || exit 1
  _methods_manifest | jq -c --arg list "$list" --arg profile "$profile" --argjson active "$active" '
    [(.hooks[$list] // []) | to_entries[]
      | .value as $hook
      | select($active | index($hook.component))
      | select($hook.profiles == null or ($hook.profiles | index($profile)))
      | { key: [({ early: 0, main: 1, late: 2 }[$hook.phase // "main"] // 1),
                ($active | index($hook.component)), .key],
          hook: ($hook + { list: $list }) }]
    | sort_by(.key)[] | .hook'
}

# _methods_manifest_path WHAT PATH: a file path of the manifest as a path on
# this machine: <instance>/ and <dotsteward>/ paths of a mirror are
# resolved, <store>/ paths need a generation. WHAT starts the messages.
_methods_manifest_path() {
  local what=$1 value=$2 framework
  framework=${DOTSTEWARD_FRAMEWORK_ROOT:-$(cd -- "$_DS_METHODS_LIB_DIR/../.." && pwd -P)}
  case $value in
    "<instance>/"?*) printf '%s\n' "$DS_INSTANCE_ROOT/${value#"<instance>/"}" ;;
    "<dotsteward>/"?*) printf '%s\n' "$framework/${value#"<dotsteward>/"}" ;;
    "<store>/"*)
      die "$what: $value is a Nix store path the manifest mirror does not carry; pass --generation with a built generation"
      ;;
    /?*) printf '%s\n' "$value" ;;
    *) die "$what: unsupported path: $value" ;;
  esac
}

methods_hook_path() {
  (($# == 1)) || die "usage: methods_hook_path HOOK_JSON"
  local component name script path
  component=$(jq -r '.component' <<<"$1")
  name=$(jq -r '.name' <<<"$1")
  script=$(jq -r '.script' <<<"$1")
  case $script in
    "<instance>/"?* | "<dotsteward>/"?* | "<store>/"* | /?*) ;;
    *) die "component $component hook $name: unsupported script path: $script" ;;
  esac
  path=$(_methods_manifest_path "component $component hook $name" "$script") || exit 1
  [[ -f $path && -x $path ]] || die "component $component hook $name: not an executable file: $path"
  printf '%s\n' "$path"
}

methods_run_hook() {
  (($# >= 3)) || die "usage: methods_run_hook HOOK_JSON PROFILE CHECK_ONLY [ARG...]"
  local hook=$1 profile=$2 check_only=$3 path component status=0
  shift 3
  path=$(methods_hook_path "$hook") || exit 1
  component=$(jq -r '.component' <<<"$hook")
  env DOTSTEWARD_LIB="$_DS_METHODS_LIB_DIR" \
    DOTSTEWARD_INSTANCE="$DS_INSTANCE_ROOT" \
    DOTSTEWARD_STATE_ROOT="$(state_root)" \
    DOTSTEWARD_PROFILE="$profile" \
    DOTSTEWARD_PROFILE_MODE="${DS_PROFILE_MODE[$profile]}" \
    DOTSTEWARD_PLATFORM="$DS_RUNTIME_PLATFORM" \
    DOTSTEWARD_COMPONENT="$component" \
    DOTSTEWARD_CHECK_ONLY="$check_only" \
    DOTSTEWARD_ASSUME_YES="${DOTSTEWARD_ASSUME_YES:-0}" \
    "$path" "$@" || status=$?
  return "$status"
}
