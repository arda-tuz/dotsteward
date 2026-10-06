#!/usr/bin/env bash
# Installs the pinned Nix on a GitHub-hosted Linux runner (multi-user, with
# the daemon), verified before anything runs.
#
# Usage: tests/ci/install-nix.sh [--download-only DIR]
#
# The pin (version, installer URL, size and sha256) is the "nix" section of
# template/versions.lock.json, the pin every new instance starts from. The
# installer script is downloaded over HTTPS, its size and sha256 are checked, and only then is it
# run; it verifies the Nix release tarball it fetches against the hash it
# carries. Flakes and the nix command are enabled. On GitHub Actions the Nix
# profile is added to GITHUB_PATH and NIX_SSL_CERT_FILE to GITHUB_ENV.
# Finally `nix --version` must report exactly the pinned version.
#
# The installation uses sudo and changes the system, so it runs only on a
# GitHub Actions runner (GITHUB_ACTIONS=true). --download-only DIR stops
# after the verified download into DIR and works anywhere. A Nix that is
# already installed with the pinned version is accepted as is; any other
# version is an error.
set -Eeuo pipefail

die() {
  printf '[dotsteward] ERROR: install-nix: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] install-nix: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

download_dir=""
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --download-only)
      (($# >= 2)) && [[ -n $2 ]] || die "--download-only requires a directory"
      download_dir=$2
      shift 2
      ;;
    *) die "usage: install-nix.sh [--download-only DIR]" ;;
  esac
done

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lock=$framework_root/template/versions.lock.json

[[ -f $lock ]] || die "template/versions.lock.json is missing"
command -v jq >/dev/null 2>&1 || die "jq is required to read template/versions.lock.json"
pin=$(jq -er '.nix | [.version, .installer_url, (.installer_size | tostring), .installer_sha256] | @tsv' "$lock") ||
  die "template/versions.lock.json has no complete nix section"
IFS=$'\t' read -r version url size sha256 <<<"$pin"
log "pin from template/versions.lock.json: Nix $version"
[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid pinned Nix version"
[[ $url == https://* && $url != *[[:space:]]* ]] || die "the pinned installer URL must be https"
[[ $size =~ ^[1-9][0-9]*$ ]] || die "invalid pinned installer size"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "invalid pinned installer sha256"

expected_version="nix (Nix) $version"

if [[ -z $download_dir ]]; then
  [[ ${GITHUB_ACTIONS:-} == true ]] || die "installs only on GitHub Actions runners; use --download-only elsewhere"
  [[ $(uname -s) == Linux ]] || die "installs only on Linux runners"
  if command -v nix >/dev/null 2>&1; then
    found=$(nix --version)
    [[ $found == "$expected_version" ]] || die "found $found, expected $expected_version"
    log "$found is already installed"
    exit 0
  fi
fi

# --- verified download --------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-nix.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
installer=$work/install
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 5 --retry-all-errors --max-filesize "$size" --output "$installer" "$url" ||
  die "downloading the Nix installer failed"
actual_size=$(wc -c <"$installer")
actual_size=${actual_size//[[:space:]]/}
[[ $actual_size == "$size" ]] || die "installer size $actual_size, expected $size"
actual_sha256=$(sha256sum "$installer")
actual_sha256=${actual_sha256%% *}
[[ $actual_sha256 == "$sha256" ]] || die "installer sha256 mismatch"
log "verified the Nix $version installer (size and sha256)"

if [[ -n $download_dir ]]; then
  if ! { mkdir -p -- "$download_dir" && cp -- "$installer" "$download_dir/install"; }; then
    die "cannot save the installer to $download_dir"
  fi
  log "saved the verified installer to $download_dir/install"
  exit 0
fi

# --- installation ----------------------------------------------------------------

conf=$work/nix.conf
cat >"$conf" <<'EOF'
experimental-features = nix-command flakes
max-jobs = auto
EOF
sh "$installer" --daemon --yes --nix-extra-conf-file "$conf" </dev/null ||
  die "the Nix installer failed"

profile_bin=/nix/var/nix/profiles/default/bin
[[ -x $profile_bin/nix ]] || die "nix is missing from $profile_bin after the installation"
cert_file=/etc/ssl/certs/ca-certificates.crt
if [[ -n ${GITHUB_PATH:-} ]]; then
  printf '%s\n' "$profile_bin" >>"$GITHUB_PATH"
fi
if [[ -n ${GITHUB_ENV:-} && -f $cert_file ]]; then
  printf 'NIX_SSL_CERT_FILE=%s\n' "$cert_file" >>"$GITHUB_ENV"
fi
found=$("$profile_bin/nix" --version)
[[ $found == "$expected_version" ]] || die "installed $found, expected $expected_version"
log "installed $found"
