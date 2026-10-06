#!/usr/bin/env bash
# summary: Regenerate the .dotsteward/ mirrors and the derived lock values
#
# Usage: dotsteward sync [--nix] [--skill NAME]...
#
# Evaluates the instance's dotstewardMirrors output (`nix eval --json
# --no-update-lock-file <instance>#dotstewardMirrors`), writes every mirror
# that changed to .dotsteward/<name> byte for byte (atomically), removes
# manifest.*.json and stage0.*.env mirrors the evaluation no longer
# produces, then runs `dotsteward pins sync` with the same flags against the
# fresh mirrors. Untracked, not ignored files other than those mirrors are
# refused before any Nix call, because Nix does not see them. Exit codes:
# 0 ok, 1 refusal or error, else the status of `pins sync`.
set -Eeuo pipefail

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=cli/lib/lib.sh
source "$framework_root/cli/lib/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$framework_root/cli/lib/config.sh"

usage() {
  sed -n '3,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

pins_args=()
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --nix)
      pins_args+=(--nix)
      shift
      ;;
    --skill)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "--skill requires a value"
      fi
      pins_args+=(--skill "$2")
      shift 2
      ;;
    --skill=*)
      [[ -n ${1#--skill=} ]] || die "--skill requires a value"
      pins_args+=(--skill "${1#--skill=}")
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

# shellcheck disable=SC2119 # config_load takes no argument here
config_load
root=$DS_INSTANCE_ROOT
mirror_dir=$root/.dotsteward

# The names of the mirrors under .dotsteward/ (an extended regular
# expression); keep identical to MIRROR_PATH in
# engines/pins/dotsteward_pins/instance.py.
mirror_name_pattern='^(manifest\.[A-Za-z0-9_-]+\.json|stage0\.[a-z]+\.env)$'

# Nix evaluates the git-visible tree: refuse what it would not see. The
# .dotsteward/ mirrors are outputs of the evaluation that Nix never reads, so
# an untracked mirror (for example one a previous run wrote) is not refused.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  untracked=$(git -C "$root" ls-files -z --others --exclude-standard | tr '\0' '\n' |
    grep -Ev "^\\.dotsteward/${mirror_name_pattern#^}" || true)
  if [[ -n $untracked ]]; then
    die "Nix does not see untracked files; run 'git add -A' first: $(tr '\n' ' ' <<<"$untracked" | sed 's/ $//')"
  fi
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-sync.XXXXXX")
trap 'cleanup_temp_dir "$tmp"' EXIT

if ! nix_cmd eval --json --no-update-lock-file "$root#dotstewardMirrors" >"$tmp/mirrors.json"; then
  die "cannot evaluate the mirrors of the instance (nix eval $root#dotstewardMirrors failed)"
fi
jq -e 'type == "object" and all(.[]; type == "string")' "$tmp/mirrors.json" >/dev/null 2>&1 ||
  die "dotstewardMirrors is not an object of strings"

mapfile -t names < <(jq -r 'keys[]' "$tmp/mirrors.json")
for name in "${names[@]}"; do
  [[ $name =~ $mirror_name_pattern ]] || die "unexpected mirror name from dotstewardMirrors: $name"
done

mkdir -p -- "$mirror_dir"
changed=0
for existing in "$mirror_dir"/manifest.*.json "$mirror_dir"/stage0.*.env; do
  [[ -f $existing ]] || continue
  base=${existing##*/}
  [[ $base =~ $mirror_name_pattern ]] || continue
  if ! jq -e --arg name "$base" 'has($name)' "$tmp/mirrors.json" >/dev/null; then
    rm -f -- "$existing"
    log "Removed stale mirror .dotsteward/$base"
    changed=1
  fi
done
for name in "${names[@]}"; do
  jq -j --arg name "$name" '.[$name]' "$tmp/mirrors.json" >"$tmp/$name"
  if [[ -f $mirror_dir/$name ]] && cmp -s -- "$tmp/$name" "$mirror_dir/$name"; then
    continue
  fi
  staged=$(mktemp "$mirror_dir/.$name.XXXXXX")
  cat -- "$tmp/$name" >"$staged"
  chmod 0644 -- "$staged"
  mv -f -- "$staged" "$mirror_dir/$name"
  log "Wrote mirror .dotsteward/$name"
  changed=1
done
((changed)) || log "Mirrors are current"

cleanup_temp_dir "$tmp"
trap - EXIT
exec "$framework_root/cli/dotsteward" --instance "$root" pins sync "${pins_args[@]}"
