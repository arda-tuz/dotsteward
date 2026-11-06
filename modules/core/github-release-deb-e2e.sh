#!/usr/bin/env bash
# E2E hook of the catalog components built by github-release-deb.nix
# (checks.e2e, phase main, every profile). The component named by
# DOTSTEWARD_COMPONENT is also its DEB package and the name of its pin
# desktop_packages.<name>. It checks, reading only:
#   - the installed package version is at least the pin's minimum_version
#     (dpkg --compare-versions);
#   - the package ships at least one desktop entry
#     (/usr/share/applications/*.desktop in `dpkg-query -L`), and every one
#     of them exists (below DOTSTEWARD_SYSTEM_ROOT, default /, which only
#     tests set);
#   - <name>-cli --version answers, run from the user's PATH (user_run);
#   - APT takes the package from the local APT bridge
#     (file:/var/lib/dotsteward/apt-bridge in `apt-cache policy`); the failure
#     names the step, which is another install when a first refresh left the
#     repository without the package.
# A machine can pass all of this and still wait for one step: the bridge's
# timer comes with `dotsteward install --component`, which needs sudo and which
# no rebuild runs in an adopt-mode profile. Until then the package only misses
# later releases, so the hook reports the step and stays green. The same goes
# for the APT hook of an older framework that is still in place.
# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"

name=${DOTSTEWARD_COMPONENT:-}
[[ -n $name ]] || die "github-release-deb E2E: DOTSTEWARD_COMPONENT is not set"

require_command dpkg
require_command dpkg-query
require_command apt-cache

minimum=$(pin_value "$name" minimum_version)
installed=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null) || installed=""
[[ -n $installed ]] || die "$name: the package is not installed"
dpkg --compare-versions "$installed" ge "$minimum" ||
  die "$name: the installed package $installed is below the floor $minimum"

entries=()
while IFS= read -r file; do
  [[ $file == /usr/share/applications/*.desktop ]] && entries+=("$file")
done < <(dpkg-query -L "$name" 2>/dev/null)
((${#entries[@]})) || die "$name: the package ships no desktop entry"
for file in "${entries[@]}"; do
  [[ -f ${DOTSTEWARD_SYSTEM_ROOT:-}$file ]] || die "$name: the desktop entry $file is missing"
done

user_run "$name-cli" --version </dev/null >/dev/null 2>&1 || die "$name: $name-cli --version does not answer"

# Read the whole policy first: a reader that stops at the first match (grep -q)
# leaves apt-cache to die of SIGPIPE under pipefail when more output follows,
# as it does while a newer version waits in the bridge.
policy=$(apt-cache policy "$name" 2>/dev/null) || policy=""
step="run dotsteward install --profile ${DOTSTEWARD_PROFILE:-<profile>} --component $name"
if [[ $policy != *'file:/var/lib/dotsteward/apt-bridge'* ]]; then
  if grep -qxF -- "Package: $name" "${DOTSTEWARD_SYSTEM_ROOT:-}/var/lib/dotsteward/apt-bridge/Packages" 2>/dev/null; then
    die "$name: APT does not take the package from the local APT bridge yet: the bridge holds it, run sudo apt-get update"
  fi
  die "$name: APT does not take the package from the local APT bridge: the bridge holds no release of it yet (journalctl -t dotsteward-apt-bridge): $step"
fi

units=${DOTSTEWARD_SYSTEM_ROOT:-}/etc/systemd/system
old_hook=${DOTSTEWARD_APT_DIR:-/etc/apt}/apt.conf.d/60dotsteward-apt-bridge
if command -v systemctl >/dev/null 2>&1 && [[ ! -f $units/dotsteward-apt-bridge.timer ||
  ! -L $units/timers.target.wants/dotsteward-apt-bridge.timer ]]; then
  warn "$name: bridge timer not installed: $step"
elif [[ -e $old_hook ]]; then
  warn "$name: obsolete bridge hook $old_hook: $step"
fi

log "$name $installed: floor $minimum, desktop entry, CLI and the local APT bridge"
