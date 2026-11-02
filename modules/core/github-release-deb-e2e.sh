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
#     (file:/var/lib/dotsteward/apt-bridge in `apt-cache policy`).
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

apt-cache policy "$name" 2>/dev/null | grep -qF 'file:/var/lib/dotsteward/apt-bridge' ||
  die "$name: APT does not take the package from the local APT bridge"

log "$name $installed: floor $minimum, desktop entry, CLI and the local APT bridge"
