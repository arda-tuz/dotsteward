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
#   methods_deb_transaction NAME...  the fresh-mode deb transaction of the
#                                    given deb components (Linux); sets
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
    nix | official-binary | external) ;;
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

methods_check() {
  (($# == 2)) || die "usage: methods_check NAME PROFILE"
  local name=$1 profile=$2 method mode
  method=$(methods_component_method "$name") || exit 1
  mode=${DS_PROFILE_MODE[$profile]:-}
  [[ -n $mode ]] || die "unknown profile: $profile"
  # Not managed whatever the platform offers.
  if [[ $mode == adopt ]] && methods_is_system_level "$method"; then
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

# --- deb ------------------------------------------------------------------

# _methods_deb_block NAME: sets _deb_pin, _deb_names, _deb_arch,
# _deb_verify, _deb_apt and, with a pin, _deb_entry and _deb_floor.
_methods_deb_block() {
  local name=$1 component
  component=$(methods_component "$name") || exit 1
  _deb_pin=$(jq -r '.install.pin // empty' <<<"$component")
  _deb_arch=$(jq -r '.install.architecture // empty' <<<"$component")
  _deb_verify=$(jq -r 'if .install.verifyAfterInstall == false then "false" else "true" end' <<<"$component")
  mapfile -t _deb_names < <(jq -r '(.install.packageNames // [])[]' <<<"$component")
  mapfile -t _deb_apt < <(jq -r '(.install.apt // [])[]' <<<"$component")
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

_methods_deb_check() {
  local name=$1 met package
  _methods_deb_requirements
  _methods_deb_block "$name"
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
  local -A component_apt=() component_deb=()
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

  # Download and verify every DEB before the first sudo call, then one
  # transaction. The subshell is the left operand of `||`, where bash ignores
  # errexit, so every step checks its own status.
  if ((${#apt_queue[@]} || ${#deb_names[@]})); then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-install.XXXXXX") ||
      die "cannot create a temporary directory for the deb transaction"
    (
      trap 'cleanup_temp_dir "$tmp_dir"' EXIT
      local i file field paths=() shown=()
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
      local listing=("${apt_queue[@]}" "${shown[@]}")
      log "installing system packages: ${listing[*]}"
      apt_update || die "apt-get update failed; nothing was installed"
      apt_install "${apt_queue[@]}" "${paths[@]}" || die "apt-get install failed"
    ) || status=$?
    ((status == 0)) || exit "$status"
  fi

  # Verify the floors and the apt packages.
  for name in "${names[@]}"; do
    _methods_deb_block "$name"
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
    if [[ -n ${component_deb[$name]:-} || -n ${component_apt[$name]:-} ]]; then
      METHODS_DEB_STATUS[$name]=installed
      if [[ -n $_deb_pin && -n ${component_apt[$name]:-} ]]; then
        detail+=", ${component_apt[$name]// /, }"
      elif [[ -z $_deb_pin ]]; then
        detail=${component_apt[$name]// /, }
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

methods_hook_path() {
  (($# == 1)) || die "usage: methods_hook_path HOOK_JSON"
  local component name script path framework
  component=$(jq -r '.component' <<<"$1")
  name=$(jq -r '.name' <<<"$1")
  script=$(jq -r '.script' <<<"$1")
  framework=${DOTSTEWARD_FRAMEWORK_ROOT:-$(cd -- "$_DS_METHODS_LIB_DIR/../.." && pwd -P)}
  case $script in
    "<instance>/"?*) path=$DS_INSTANCE_ROOT/${script#"<instance>/"} ;;
    "<dotsteward>/"?*) path=$framework/${script#"<dotsteward>/"} ;;
    "<store>/"*)
      die "component $component hook $name: $script is a Nix store path the manifest mirror does not carry; pass --generation with a built generation"
      ;;
    /?*) path=$script ;;
    *) die "component $component hook $name: unsupported script path: $script" ;;
  esac
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
