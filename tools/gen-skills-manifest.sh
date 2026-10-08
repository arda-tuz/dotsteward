#!/usr/bin/env bash
# Regenerates skills/manifest.json, the digests of the framework skills that
# instances verify their deployed copies against.
#
# Usage: tools/gen-skills-manifest.sh [--check] [--root DIR]
#
# Every directory of DIR/skills (default: the framework checkout holding
# this script) is a skill and needs a regular SKILL.md. The manifest lists
# them sorted by name:
#
#   { "schema_version": 1,
#     "skills": [ { "name", "directory", "skill_sha256", "directory_sha256" } ] }
#
# skill_sha256 is the sha256 of SKILL.md and directory_sha256 the directory
# digest of cli/lib/lib.sh (__pycache__ and *.pyc excluded). Symlinks are
# refused anywhere in a skill, because the directory digest ignores them.
# Regular files next to the skill directories are ignored.
#
# Without --check the file is written (atomically, mode 0644) when its bytes
# change. --check only compares and exits 1 when the file is missing or
# stale.
set -Eeuo pipefail

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=cli/lib/lib.sh
source "$script_root/cli/lib/lib.sh"

usage() {
  sed -n '5s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

check=0
root=$script_root
while (($#)); do
  case $1 in
    --check)
      check=1
      shift
      ;;
    --root)
      (($# >= 2)) || die "--root requires a directory"
      root=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 ($(usage))" ;;
  esac
done

skills_dir=$root/skills
[[ -d $skills_dir ]] || die "no skills directory: $skills_dir"
manifest=$skills_dir/manifest.json

entries=()
while IFS= read -r -d '' path; do
  name=${path##*/}
  [[ ! -L $path ]] || die "skills/$name: a skill directory must not be a symlink"
  [[ -d $path ]] || continue
  [[ -f $path/SKILL.md && ! -L $path/SKILL.md ]] || die "skills/$name: SKILL.md is missing or not a regular file"
  link=$(cd "$path" && find . -type l -print -quit)
  [[ -z $link ]] || die "skills/$name/${link#./}: symlinks are not allowed in a skill (directory digests ignore them)"
  entries+=("$(jq -cn --arg name "$name" --arg skill "$(sha256_file "$path/SKILL.md")" \
    --arg dir "$(directory_sha256 "$path")" \
    '{name: $name, directory: $name, skill_sha256: $skill, directory_sha256: $dir}')")
done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)

count=${#entries[@]}
if ((count)); then
  document=$(printf '%s\n' "${entries[@]}" | jq -s '{schema_version: 1, skills: .}')
else
  document=$(jq -n '{schema_version: 1, skills: []}')
fi

if [[ -f $manifest && $(<"$manifest") == "$document" && $(tail -c 1 "$manifest" | od -An -tx1 | tr -d ' ') == 0a ]]; then
  log "skills/manifest.json is up to date ($count skills)"
  exit 0
fi
if ((check)); then
  if [[ -f $manifest ]]; then
    die "skills/manifest.json is stale; run tools/gen-skills-manifest.sh"
  fi
  die "skills/manifest.json is missing; run tools/gen-skills-manifest.sh"
fi

temp=$(mktemp "$skills_dir/.manifest.json.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
printf '%s\n' "$document" >"$temp"
chmod 0644 "$temp"
mv -f -- "$temp" "$manifest"
trap - EXIT
log "wrote skills/manifest.json ($count skills)"
