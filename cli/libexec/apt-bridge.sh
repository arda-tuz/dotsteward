# shellcheck shell=bash
# The local APT bridge: a flat APT repository fed from release downloads of
# vendors that publish DEBs but run no APT repository.
#
# Usage: bash apt-bridge.sh CONF_DIR REPO_DIR
#
# The deb method writes this file (deliberately without a shebang, so it
# never depends on an interpreter path that can disappear) next to an
# APT::Update::Pre-Invoke hook that runs it as root with /bin/bash before
# every `apt update`, and a trusted file: source over REPO_DIR. Each
# CONF_DIR/<package>.conf holds key=value lines:
#
#   package=NAME          the package the DEB must hold
#   architecture=ARCH     the dpkg architecture the DEB must be built for
#                         (or "all")
#   url=HTTPS_URL         the download directory of the newest release
#   asset=TEMPLATE        the DEB file name; {version} stands for the version
#   checksums=FILE        the release's checksum file (sha256sum format)
#
# For each package the checksum file is read; the one asset that matches
# the template is downloaded when REPO_DIR does not hold it yet, checked
# against its SHA-256 and its control fields, and kept as the only version
# of the package. The index (Packages, Release) is rewritten when the set of
# DEBs changed. Every failure prints one line, keeps the repository as it
# was and lets the update go on: the script always exits 0.

set -uo pipefail
umask 022

if (($# != 2)); then
  printf 'usage: apt-bridge.sh CONF_DIR REPO_DIR\n' >&2
  exit 0
fi
conf_dir=$1
repo=$2

say() {
  printf 'dotsteward-apt-bridge: %s\n' "$*"
}

fetch() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 2 --retry-delay 5 --speed-limit 10240 --speed-time 60 \
    --max-time "$3" --output "$2" "$1"
}

sha256_of() {
  local sum
  sum=$(sha256sum -- "$1") || return 1
  printf '%s\n' "${sum%% *}"
}

# conf_value FILE KEY: the value of KEY in FILE (empty when missing).
conf_value() {
  local key value
  while IFS='=' read -r key value; do
    if [[ $key == "$2" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <"$1"
}

# update_package CONF: brings the package of CONF to the newest release;
# status 1 with the reason in $reason when it cannot.
update_package() {
  local conf=$1 package arch url asset checksums prefix suffix
  local sums line sha name version found_sha='' found_name='' matches=0 status
  local deb field current
  package=$(conf_value "$conf" package)
  arch=$(conf_value "$conf" architecture)
  url=$(conf_value "$conf" url)
  asset=$(conf_value "$conf" asset)
  checksums=$(conf_value "$conf" checksums)
  label=${package:-$(basename -- "$conf" .conf)}
  if [[ ! $package =~ ^[a-z0-9][a-z0-9.+-]+$ || -z $arch || -z $checksums ||
    $checksums == */* || $asset != *'{version}'* || $asset == */* ]]; then
    reason="incomplete configuration $conf"
    return 1
  fi
  if [[ $url != https://* ]]; then
    reason="refusing a non-HTTPS URL: $url"
    return 1
  fi

  sums=$work/$package.sums
  status=0
  fetch "$url/$checksums" "$sums" 120 2>/dev/null || status=$?
  if ((status != 0)); then
    reason="cannot download $checksums (curl exit $status); keeping the current package"
    return 1
  fi
  prefix=${asset%%'{version}'*}
  suffix=${asset#*'{version}'}
  while read -r sha name line; do
    name=${name#\*}
    [[ -z $line && $sha =~ ^[0-9a-f]{64}$ && $name == "$prefix"*"$suffix" ]] || continue
    version=${name#"$prefix"}
    version=${version%"$suffix"}
    [[ $version =~ ^[0-9A-Za-z.+~-]+$ ]] || continue
    matches=$((matches + 1))
    found_sha=$sha
    found_name=$name
  done <"$sums"
  if ((matches == 0)); then
    reason="$checksums lists no asset $asset; keeping the current package"
    return 1
  fi
  if ((matches > 1)); then
    reason="$checksums lists more than one asset $asset; keeping the current package"
    return 1
  fi

  # Already held: nothing to do.
  for current in "$repo/${package}_"*.deb; do
    [[ -f $current ]] || continue
    [[ $(sha256_of "$current") == "$found_sha" ]] && return 0
  done

  deb=$work/$found_name
  status=0
  fetch "$url/$found_name" "$deb" 3600 2>/dev/null || status=$?
  if ((status != 0)); then
    reason="cannot download $found_name (curl exit $status); keeping the current package"
    return 1
  fi
  if [[ $(sha256_of "$deb") != "$found_sha" ]]; then
    reason="the SHA-256 of $found_name is not the one in $checksums; keeping the current package"
    return 1
  fi
  field=$(dpkg-deb -f "$deb" Package 2>/dev/null)
  if [[ $field != "$package" ]]; then
    reason="$found_name holds package ${field:-none} (expected $package); keeping the current package"
    return 1
  fi
  field=$(dpkg-deb -f "$deb" Architecture 2>/dev/null)
  if [[ $field != "$arch" && $field != all ]]; then
    reason="$found_name is built for ${field:-no architecture} (expected $arch); keeping the current package"
    return 1
  fi
  version=$(dpkg-deb -f "$deb" Version 2>/dev/null)
  if [[ ! $version =~ ^[0-9A-Za-z.+~:-]+$ ]]; then
    reason="$found_name has no valid version; keeping the current package"
    return 1
  fi

  # The new DEB becomes the only version of the package.
  name=${package}_${version//:/%3a}_${field}.deb
  mv -f -- "$deb" "$repo/$name" || {
    reason="cannot move $found_name into $repo; keeping the current package"
    return 1
  }
  for current in "$repo/${package}_"*.deb; do
    [[ -f $current && $current != "$repo/$name" ]] && rm -f -- "$current"
  done
  say "$package: $version added"
}

# write_index: Packages and Release of the flat repository, rewritten only
# when the DEBs changed (or the index is missing).
write_index() {
  local deb packages=$work/Packages release=$work/Release size
  : >"$packages"
  for deb in "$repo"/*.deb; do
    [[ -f $deb ]] || continue
    {
      dpkg-deb -f "$deb" || return 1
      printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' \
        "$(basename -- "$deb")" "$(stat -c %s -- "$deb")" "$(sha256_of "$deb")"
    } >>"$packages"
  done
  if [[ -f $repo/Release && -f $repo/Packages && $(<"$packages") == "$(<"$repo/Packages")" ]]; then
    return 0
  fi
  size=$(stat -c %s -- "$packages")
  {
    printf 'Origin: dotsteward\nLabel: dotsteward-apt-bridge\n'
    printf 'Date: %s\n' "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    printf 'SHA256:\n %s %s Packages\n' "$(sha256_of "$packages")" "$size"
  } >"$release"
  mv -f -- "$packages" "$repo/Packages" && mv -f -- "$release" "$repo/Release"
}

mkdir -p -- "$repo" || exit 0
exec 9>"$repo/.lock" || exit 0
flock -w 600 9 || {
  say "another run holds $repo/.lock; skipped"
  exit 0
}
work=$(mktemp -d "$repo/.partial.XXXXXX") || exit 0
trap 'rm -rf -- "$work"' EXIT

for conf in "$conf_dir"/*.conf; do
  [[ -f $conf ]] || continue
  reason=''
  label=''
  update_package "$conf" || say "${label:-$conf}: $reason"
done
write_index || say "cannot write the index of $repo"
exit 0
