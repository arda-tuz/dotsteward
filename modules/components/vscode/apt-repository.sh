#!/usr/bin/env bash
# The vendor APT repository hook of the vscode component, declared with
# options.vendor_repository = true (Linux, deb method) as a systemInstall
# hook and as an E2E hook (checks.e2e, phase main). The code package's own
# installer owns the repository's APT source and signing key: it asks
# whether to add them (debconf question code/add-microsoft-repo) and adds
# them only while no APT source maps the repository. This hook never writes,
# rewrites or removes that source itself.
#   systemInstall (DOTSTEWARD_CHECK_ONLY=0, `dotsteward install`): when no
#     APT source maps the repository, it answers the installer's question
#     with yes (debconf-set-selections) and runs the package's
#     configuration again (dpkg-reconfigure, noninteractive), so the
#     installer writes its source; then `apt-get update` reads it.
#   E2E (DOTSTEWARD_CHECK_ONLY=1): reading only, an APT source maps the
#     repository and APT takes code from it (`apt-cache policy code`).
# A source maps the repository when one of <apt>/sources.list,
# <apt>/sources.list.d/*.list (a "deb" line) or *.sources (a URIs line)
# names it; <apt> is DOTSTEWARD_APT_DIR, else /etc/apt.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the vscode apt-repository hook runs from dotsteward (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"

repository=https://packages.microsoft.com/repos/code
pattern='packages\.microsoft\.com/repos/code/?([[:space:]]|$)'
apt_dir=${DOTSTEWARD_APT_DIR:-/etc/apt}
profile=${DOTSTEWARD_PROFILE:-PROFILE}

# mapped: the first APT source file that maps the repository, else status 1.
mapped() {
  local file
  for file in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list "$apt_dir"/sources.list.d/*.sources; do
    [[ -f $file ]] || continue
    if grep -Eiq -e "^[[:space:]]*deb[[:space:]].*https://$pattern" -e "^[[:space:]]*URIs:.*https://$pattern" "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

if [[ ${DOTSTEWARD_CHECK_ONLY:-1} == 1 ]]; then
  file=$(mapped) ||
    die "vscode: no APT source maps $repository; run 'dotsteward --instance $DOTSTEWARD_INSTANCE install --profile $profile --component vscode' (it needs sudo) so the code installer adds it"
  require_command apt-cache
  # Read whole: a reader that stops at the first match leaves apt-cache to
  # die of SIGPIPE under pipefail.
  policy=$(apt-cache policy code 2>/dev/null) || policy=''
  [[ $policy == *"$repository "* ]] ||
    die "vscode: APT does not take code from $repository yet ($file); run 'sudo apt update'"
  log "vscode: APT takes code from $repository ($file)"
  exit 0
fi

if file=$(mapped); then
  log "vscode: APT source of $repository: $file"
  exit 0
fi
require_command dpkg-query
dpkg_installed code ||
  die "vscode: the code package is not installed, so its installer cannot add $repository"
log "vscode: no APT source maps $repository; the code installer adds its own (its repository question answered with yes)"
printf 'code code/add-microsoft-repo boolean true\n' | sudo debconf-set-selections ||
  die "vscode: debconf-set-selections failed"
sudo dpkg-reconfigure --frontend=noninteractive code || die "vscode: dpkg-reconfigure code failed"
file=$(mapped) || die "vscode: the code installer added no APT source for $repository"
apt_update || die "vscode: apt-get update failed"
log "vscode: APT source of $repository: $file"
