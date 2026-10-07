#!/usr/bin/env bash
# summary: Run the version, presence and feature probes of a generation's manifest
#
# Usage: dotsteward probes (--generation PATH | --manifest FILE --path-prefix DIR)
#
# Runs the probe registry (SPEC 8.2) of the instance's check profile
# (profiles.check, the profile of checks.<system>.home that the gate builds):
#   --generation PATH   a built generation: its manifest
#                       PATH/home-path/share/dotsteward/manifest.json, its
#                       commands from PATH/home-path/bin
#   --manifest FILE     a manifest file, with
#   --path-prefix DIR   the directory searched first for the probe commands
# The prefix applies to the probe commands only. Expected versions come from
# the instance's lock files (pins.versions_lock and skills.lock), so the
# command needs the instance (--instance, DOTSTEWARD_INSTANCE or the working
# directory). Exit 0 when every probe passes, 1 on the first failure or an
# invalid manifest or argument.
set -Eeuo pipefail

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=cli/lib/lib.sh
source "$framework_root/cli/lib/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$framework_root/cli/lib/config.sh"
# shellcheck source=cli/lib/probes.sh
source "$framework_root/cli/lib/probes.sh"

usage() {
  sed -n '4,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

# need_value FLAG ARGC VALUE: fails unless an option that takes a value got one.
need_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "$1 requires a value"
  fi
}

generation=""
manifest=""
prefix=""
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --generation | --manifest | --path-prefix)
      need_value "$1" "$#" "${2:-}"
      case $1 in
        --generation) generation=$2 ;;
        --manifest) manifest=$2 ;;
        --path-prefix) prefix=$2 ;;
      esac
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n $generation && -n $manifest ]]; then
  die "--generation and --manifest exclude each other"
elif [[ -n $prefix && -z $manifest ]]; then
  die "--path-prefix requires --manifest"
elif [[ -n $manifest && -z $prefix ]]; then
  die "--manifest requires --path-prefix"
elif [[ -z $generation && -z $manifest ]]; then
  die "one of --generation or --manifest is required"
fi

if [[ -n $generation ]]; then
  manifest=$generation/home-path/share/dotsteward/manifest.json
  prefix=$generation/home-path/bin
  [[ -f $manifest ]] || die "generation manifest not found: $manifest"
  [[ -d $prefix ]] || die "generation has no command directory: $prefix"
else
  [[ -f $manifest ]] || die "manifest not found: $manifest"
  [[ -d $prefix ]] || die "path prefix is not a directory: $prefix"
fi

# The instance comes from --instance (DOTSTEWARD_INSTANCE) or discovery, never
# from this command's arguments.
# shellcheck disable=SC2119 # config_load takes no argument here
config_load
profile=$DS_PROFILES_CHECK

run_cli_probes "$manifest" "$profile" "$prefix"

summary=$(probes_select "$manifest" "$profile" | jq -rs '
  [("version", "presence", "features") as $kind | "\(map(select(.kind == $kind)) | length) \($kind)"]
  | join(", ")')
log "probes passed: $summary (profile $profile)"
