#!/usr/bin/env bash
# E2E of apt-policy: what apt makes of 52dotsteward-unattended-upgrades, read the way
# unattended-upgrades reads it (apt-config), so another file of apt.conf.d that sets the
# keys back is found too. The bytes are `dotsteward install --check-only`. A machine that has
# not run the install yet is told the step and stays green.
set -euo pipefail

apt_dir=${DOTSTEWARD_APT_DIR:-/etc/apt}
file=$apt_dir/apt.conf.d/52dotsteward-unattended-upgrades
step="dotsteward install --profile ${DOTSTEWARD_PROFILE:-PROFILE} --component apt-policy"

if [[ ! -f $file ]]; then
  printf '[dotsteward] apt-policy: %s is not installed yet; run: %s\n' "$file" "$step"
  exit 0
fi
command -v apt-config >/dev/null 2>&1 || {
  printf '[dotsteward] ERROR: apt-policy: apt-config is missing\n' >&2
  exit 1
}

failed=0
for key in Unattended-Upgrade::Remove-Unused-Kernel-Packages Unattended-Upgrade::Remove-New-Unused-Dependencies; do
  value=''
  eval "$(apt-config shell value "$key")"
  if [[ $value != false ]]; then
    printf '[dotsteward] ERROR: apt-policy: apt reads %s as "%s", not "false"; a file of %s/apt.conf.d after %s sets it, or the file differs (%s)\n' \
      "$key" "$value" "$apt_dir" "${file##*/}" "$step" >&2
    failed=1
  fi
done
exit "$failed"
