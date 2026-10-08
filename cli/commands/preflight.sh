#!/usr/bin/env bash
# summary: Read-only check of this machine against the instance fast path (exit 3: adaptive route)
#
# Read-only machine check before a bootstrap. Reads the stage-0 mirror
# .dotsteward/stage0.<platform>.env of the instance (profiles, the fast path,
# the preflight detectors of the enabled components, the remote) and prints
# facts about this machine:
#
#   schema_version "1.0", profile, route (fast or adaptive), fast_path,
#   platform { os_id, os_version, architecture, desktop, <detector>... },
#   nix_version (null without Nix), free_kib (free space of $HOME),
#   github_ssh_remote_accessible (`git ls-remote` of the instance remote in
#   SSH batch mode, at most 20 seconds), writes_performed false
#
# as the JSON document today's jq program printed (same keys, order and
# two-space layout, strings escaped like jq), or one human line. Linux:
# os_id and os_version are parsed from os-release (DOTSTEWARD_OS_RELEASE,
# else /etc/os-release), never sourced; macOS: os_id "macos" and the
# version from sw_vers (DOTSTEWARD_SW_VERS), and the remote is probed only
# when the Command Line Tools are installed (the /usr/bin/git shim would
# open the installer dialog). A detector is true when its command exits 0
# and prints its match line as a whole line; a missing command is false.
# The Linux fast path is os_id, os_version and architecture plus the
# desktop: no desktop rule, or XDG_CURRENT_DESKTOP contains desktop_contains
# (case-insensitive), or one of the fast-path detectors is true. The darwin
# fast path is a version at least min_version (dotted numbers) and the
# architecture. On the adaptive route preflight warns and exits 3.
#
# The part between the dotsteward:stage0 markers is the stage-0 body:
# tools/gen-stage0.sh copies it into template/bootstrap.sh, which runs it
# before Nix exists (bash 3.2, BSD tools, no jq). It uses only these
# helpers of its host, cli/lib/lib.sh and cli/lib/platform-linux.sh here and
# their copies in cli/lib/stage0.sh there: log, warn, die, current_platform,
# require_safe_identity, source_nix_daemon, os_release_value.
set -Eeuo pipefail

# dotsteward:stage0:begin
# --- preflight (stage-0 body of cli/commands/preflight.sh) -----------------

# preflight_parse ARG...: the preflight options. Sets PREFLIGHT_JSON (0 or
# 1), PREFLIGHT_PROFILE (empty: the bootstrap profile) and PREFLIGHT_HELP
# (1 for --help, which ends the parsing); --read-only is required.
preflight_parse() {
  local read_only=0
  PREFLIGHT_JSON=0
  PREFLIGHT_PROFILE=
  PREFLIGHT_HELP=0
  while (($#)); do
    case $1 in
      --read-only) read_only=1 ;;
      --json) PREFLIGHT_JSON=1 ;;
      --profile)
        if (($# < 2)) || [[ -z $2 ]]; then
          die "preflight: --profile requires a value"
        fi
        PREFLIGHT_PROFILE=$2
        shift
        ;;
      --profile=*)
        PREFLIGHT_PROFILE=${1#--profile=}
        [[ -n $PREFLIGHT_PROFILE ]] || die "preflight: --profile requires a value"
        ;;
      -h | --help)
        # shellcheck disable=SC2034 # read by the command (stage-0 never passes --help)
        PREFLIGHT_HELP=1
        return 0
        ;;
      *) die "preflight: unknown option: $1" ;;
    esac
    shift
  done
  ((read_only)) || die "preflight runs only with --read-only"
}

# preflight_load_env ROOT PLATFORM: sources ROOT/.dotsteward/stage0.
# PLATFORM.env, the stage-0 mirror (DS_STAGE0_* variables), and checks that
# it is schema 1 and describes PLATFORM.
preflight_load_env() {
  local file=$1/.dotsteward/stage0.$2.env
  [[ -f $file ]] || die ".dotsteward/stage0.$2.env not found in $1 (run 'dotsteward sync' and commit it)"
  # shellcheck source=/dev/null
  source "$file" || die "cannot read $file"
  [[ ${DS_STAGE0_SCHEMA_VERSION:-} == 1 ]] ||
    die "unsupported stage-0 schema_version ${DS_STAGE0_SCHEMA_VERSION:-<none>}: $file"
  [[ ${DS_STAGE0_PLATFORM:-} == "$2" ]] || die "$file describes ${DS_STAGE0_PLATFORM:-<none>}, not $2"
}

# preflight_require_profile PROFILE: PROFILE is one of the mirror's profiles.
preflight_require_profile() {
  local name joined=''
  for name in ${DS_STAGE0_PROFILES[@]+"${DS_STAGE0_PROFILES[@]}"}; do
    if [[ $1 == "$name" ]]; then
      return 0
    fi
    joined=$joined${joined:+, }$name
  done
  die "unsupported profile: $1 (profiles: $joined)"
}

# preflight_json_string VALUE: VALUE as a JSON string, escaped like jq
# (", \, \b, \f, \n, \r, \t, other control characters as \u00XX; bytes
# above 0x7f unchanged).
preflight_json_string() {
  local value=$1 out='' char code i=0
  local LC_ALL=C
  case $value in
    *'"'* | *\\* | *[[:cntrl:]]*) ;;
    *)
      printf '"%s"' "$value"
      return 0
      ;;
  esac
  while ((i < ${#value})); do
    char=${value:i:1}
    case $char in
      '"') out="$out\\\"" ;;
      \\) out="$out\\\\" ;;
      $'\b') out=$out'\b' ;;
      $'\f') out=$out'\f' ;;
      $'\n') out=$out'\n' ;;
      $'\r') out=$out'\r' ;;
      $'\t') out=$out'\t' ;;
      [[:cntrl:]])
        code=$(printf '%d' "'$char")
        out=$out$(printf '\\u%04x' "$code")
        ;;
      *) out=$out$char ;;
    esac
    i=$((i + 1))
  done
  printf '"%s"' "$out"
}

# preflight_with_timeout SECONDS COMMAND [ARG...]: COMMAND, stopped after
# SECONDS (timeout(1) when present; stock macOS has none).
preflight_with_timeout() {
  local seconds=$1 pid watcher status=0
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return
  fi
  "$@" &
  pid=$!
  (
    sleep "$seconds"
    kill -TERM "$pid"
  ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" || status=$?
  kill -TERM "$watcher" >/dev/null 2>&1 || true
  wait "$watcher" >/dev/null 2>&1 || true
  return "$status"
}

# preflight_remote_accessible PLATFORM REMOTE: `git ls-remote REMOTE`
# succeeds (SSH in batch mode unless GIT_SSH_COMMAND is set, no prompt, at
# most 20 seconds).
preflight_remote_accessible() {
  local platform=$1 remote=$2
  [[ -n $remote ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  if [[ $platform == darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
    return 1
  fi
  preflight_with_timeout 20 env \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}" \
    GIT_TERMINAL_PROMPT=0 git ls-remote "$remote" >/dev/null 2>&1 </dev/null
}

# preflight_detect INDEX: detector INDEX of the mirror; status 0 when its
# command exits 0 and prints the match line as a whole line.
preflight_detect() {
  local index=$1 match output
  local -a argv
  eval "argv=(\${DS_STAGE0_DETECTOR_${index}_ARGV[@]+\"\${DS_STAGE0_DETECTOR_${index}_ARGV[@]}\"})"
  eval "match=\${DS_STAGE0_DETECTOR_${index}_MATCH_LINE-}"
  ((${#argv[@]})) || return 1
  command -v "${argv[0]}" >/dev/null 2>&1 || return 1
  output=$("${argv[@]}" 2>/dev/null </dev/null) || return 1
  grep -Fxq -- "$match" <<<"$output"
}

# preflight_version_at_least VERSION MINIMUM: dotted numeric comparison (a
# missing part is 0; non-digits end a part).
preflight_version_at_least() {
  local version=$1 minimum=$2 left right
  while [[ -n $version || -n $minimum ]]; do
    left=${version%%.*}
    right=${minimum%%.*}
    left=${left%%[!0-9]*}
    right=${right%%[!0-9]*}
    left=$((10#${left:-0}))
    right=$((10#${right:-0}))
    if ((left > right)); then
      return 0
    elif ((left < right)); then
      return 1
    fi
    case $version in *.*) version=${version#*.} ;; *) version= ;; esac
    case $minimum in *.*) minimum=${minimum#*.} ;; *) minimum= ;; esac
  done
  return 0
}

# preflight_run: the checks, the report and the route; exits 3 on the
# adaptive route. Needs preflight_parse and preflight_load_env first.
preflight_run() {
  local profile=${PREFLIGHT_PROFILE:-$DS_STAGE0_BOOTSTRAP_PROFILE}
  local platform=$DS_STAGE0_PLATFORM os_id os_version architecture desktop desktop_lower contains
  local fast_path=false route=adaptive desktop_match=false nix_version='' nix_output free_kib
  local remote_accessible=false name wanted found index json version_json
  local -a names values
  preflight_require_profile "$profile"
  require_safe_identity

  architecture=$(uname -m)
  desktop=${XDG_CURRENT_DESKTOP:-unknown}
  case $platform in
    linux)
      os_id=$(os_release_value ID) || exit 1
      os_version=$(os_release_value VERSION_ID) || exit 1
      ;;
    darwin)
      os_id=macos
      os_version=$("${DOTSTEWARD_SW_VERS:-sw_vers}" -productVersion 2>/dev/null) || os_version=''
      ;;
    *) die "unsupported platform: $platform" ;;
  esac
  os_id=${os_id:-unknown}
  os_version=${os_version:-unknown}

  # The detectors, in the mirror's order.
  names=()
  values=()
  index=0
  for name in ${DS_STAGE0_DETECTORS[@]+"${DS_STAGE0_DETECTORS[@]}"}; do
    case $name in
      os_id | os_version | architecture | desktop)
        die "preflight detector $name has the name of a platform fact"
        ;;
    esac
    names[index]=$name
    if preflight_detect "$index"; then
      values[index]=true
    else
      values[index]=false
    fi
    index=$((index + 1))
  done

  case $platform in
    linux)
      contains=${DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS:-}
      if [[ -z $contains && ${#DS_STAGE0_FAST_PATH_DETECTORS[@]} -eq 0 ]]; then
        desktop_match=true
      fi
      if [[ -n $contains ]]; then
        desktop_lower=$(printf '%s' "$desktop" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        contains=$(printf '%s' "$contains" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        if [[ $desktop_lower == *"$contains"* ]]; then
          desktop_match=true
        fi
      fi
      for wanted in ${DS_STAGE0_FAST_PATH_DETECTORS[@]+"${DS_STAGE0_FAST_PATH_DETECTORS[@]}"}; do
        found=
        index=0
        while ((index < ${#names[@]})); do
          if [[ ${names[index]} == "$wanted" ]]; then
            found=${values[index]}
          fi
          index=$((index + 1))
        done
        [[ -n $found ]] || die "fast path detector $wanted is not a preflight detector of an enabled component"
        if [[ $found == true ]]; then
          desktop_match=true
        fi
      done
      if [[ $os_id == "$DS_STAGE0_FAST_PATH_OS_ID" && $os_version == "$DS_STAGE0_FAST_PATH_OS_VERSION" &&
        $architecture == "$DS_STAGE0_FAST_PATH_ARCHITECTURE" && $desktop_match == true ]]; then
        fast_path=true
      fi
      ;;
    darwin)
      if [[ $os_version != unknown && $architecture == "$DS_STAGE0_FAST_PATH_ARCHITECTURE" ]] &&
        preflight_version_at_least "$os_version" "$DS_STAGE0_FAST_PATH_MIN_VERSION"; then
        fast_path=true
      fi
      ;;
  esac
  if [[ $fast_path == true ]]; then
    route=fast
  fi

  source_nix_daemon
  if command -v nix >/dev/null 2>&1; then
    nix_output=$(nix --version 2>/dev/null) || nix_output=
    nix_version=$(printf '%s\n' "$nix_output" | awk 'NR == 1 { print $3 }')
  fi

  free_kib=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }') || free_kib=
  [[ $free_kib =~ ^[0-9]+$ ]] || die "cannot read the free space of $HOME"

  if preflight_remote_accessible "$platform" "$DS_STAGE0_INSTANCE_REMOTE"; then
    remote_accessible=true
  fi

  if ((PREFLIGHT_JSON)); then
    version_json=null
    if [[ -n $nix_version ]]; then
      version_json=$(preflight_json_string "$nix_version")
    fi
    json='{'$'\n'
    json=$json'  "schema_version": "1.0",'$'\n'
    json=$json'  "profile": '$(preflight_json_string "$profile")','$'\n'
    json=$json'  "route": "'$route'",'$'\n'
    json=$json'  "fast_path": '$fast_path','$'\n'
    json=$json'  "platform": {'$'\n'
    json=$json'    "os_id": '$(preflight_json_string "$os_id")','$'\n'
    json=$json'    "os_version": '$(preflight_json_string "$os_version")','$'\n'
    json=$json'    "architecture": '$(preflight_json_string "$architecture")','$'\n'
    json=$json'    "desktop": '$(preflight_json_string "$desktop")
    index=0
    while ((index < ${#names[@]})); do
      json=$json','$'\n''    '$(preflight_json_string "${names[index]}")': '${values[index]}
      index=$((index + 1))
    done
    json=$json$'\n''  },'$'\n'
    json=$json'  "nix_version": '$version_json','$'\n'
    json=$json'  "free_kib": '$free_kib','$'\n'
    json=$json'  "github_ssh_remote_accessible": '$remote_accessible','$'\n'
    json=$json'  "writes_performed": false'$'\n''}'
    printf '%s\n' "$json"
  else
    log "route=$route os=$os_id-$os_version arch=$architecture desktop=$desktop"
  fi

  if [[ $fast_path != true ]]; then
    warn "the fast path does not match this machine; continue on the adaptive route without writing to the tracked repository"
    exit 3
  fi
}
# dotsteward:stage0:end

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward preflight --read-only [--json] [--profile PROFILE]

Read-only checks of this machine against the instance's fast path, from
the stage-0 mirror .dotsteward/stage0.<platform>.env: the operating
system, architecture and desktop, the preflight detectors of the enabled
components, the Nix version, the free space of $HOME and whether the
instance remote answers. Nothing is written.

  --read-only         required
  --json              print the facts as one JSON document
  --profile PROFILE   a profile of the instance (default: profiles.bootstrap)

Exit status: 0 on the fast route, 3 on the adaptive route (after a
warning), 1 for a refusal.
EOF
}

preflight_parse "$@"
if ((PREFLIGHT_HELP)); then
  usage
  exit 0
fi
# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
preflight_load_env "$DS_INSTANCE_ROOT" "$DS_RUNTIME_PLATFORM"
preflight_run
