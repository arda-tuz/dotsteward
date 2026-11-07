#!/usr/bin/env bash
# summary: Fake install of the apply tests: --check-only says what is installed, the phase installs
#
# $UP_CONTROL/installed-NAME: the system-level component NAME is installed. $UP_CONTROL/install-fails:
# the phase fails. Without --component the check and the phase cover nothing and pass.
set -euo pipefail
printf 'install %s root=%s\n' "$*" "$DOTSTEWARD_INSTANCE" >>"$UP_LOG"
check_only=0
components=()
while (($#)); do
  case $1 in
    --check-only) check_only=1 ;;
    --component)
      components+=("$2")
      shift
      ;;
  esac
  shift
done
if ((check_only)); then
  for name in ${components[@]+"${components[@]}"}; do
    [[ -e $UP_CONTROL/installed-$name ]] || {
      printf '[dotsteward] ERROR: %s is not installed\n' "$name" >&2
      exit 1
    }
  done
  exit 0
fi
[[ ! -e $UP_CONTROL/install-fails ]] || exit 1
for name in ${components[@]+"${components[@]}"}; do
  : >"$UP_CONTROL/installed-$name"
done
