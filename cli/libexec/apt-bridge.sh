# shellcheck shell=bash
# The local APT bridge: a flat APT repository fed from release downloads of
# vendors that publish DEBs but run no APT repository.
#
# Usage: bash apt-bridge.sh CONF_DIR REPO_DIR
#
# The deb method writes this file (deliberately without a shebang, so it
# never depends on an interpreter path that can disappear) next to a system
# timer and the oneshot service it starts, which runs it as root with
# /bin/bash, and a trusted file: source over REPO_DIR. It runs outside any apt
# lock, and it can run on its own, right before an `apt-get update` of the
# caller. One run at a time holds REPO_DIR/.lock; another one waits for it, at
# most DOTSTEWARD_APT_BRIDGE_LOCK_WAIT seconds (600), then gives up. Each
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
# against its SHA-256 and its control fields, and becomes the only version
# the index (Packages, Release) lists, which is written when the listed DEBs
# changed. Every failure prints one line (the service sends it to the
# journal), keeps the repository as it was and goes on: the script always
# exits 0. With DOTSTEWARD_CHECK_ONLY=1 it changes nothing.
#
# APT may read the repository at any moment of a run, or be killed with it:
#   - A valid index exists before the first download.
#   - A DEB is downloaded into a work directory inside REPO_DIR and lands by
#     rename; the index that lists it follows.
#   - The rename of Release commits an index. APT reads Release first and
#     then takes Packages by the hash it read (Acquire-By-Hash) from
#     by-hash/SHA256/, which keeps the indexes of before the commit for a day:
#     Packages and Release in two renames alone would fail an update that falls
#     between them with "Hash Sum mismatch".
#   - What a commit names reaches the disk before Release does, and a power
#     cut that still empties a file is taken for no index by the next run.
#   - A DEB the index no longer lists stays, marked <deb>.superseded, until
#     the next version of the package lands: `apt upgrade` still finds what
#     lists from before the commit promise.
#   - A Release is dated after the one it replaces whatever the clock says:
#     APT silently ignores a Release older than the one it holds.

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

# The lock stays with this script: a download that outlives it must not keep
# the next run out.
fetch() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 2 --retry-delay 5 --speed-limit 10240 --speed-time 60 \
    --max-time "$3" --output "$2" "$1" 9>&-
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

# list_only PACKAGE DEB: DEB becomes the listed version of PACKAGE. The one
# listed until now stays on disk, marked as superseded; one that was already
# marked goes.
list_only() {
  local package=$1 deb=$2 other
  rm -f -- "$deb.superseded"
  for other in "$repo/${package}_"*.deb; do
    [[ -f $other && $other != "$deb" ]] || continue
    if [[ -e $other.superseded ]]; then
      rm -f -- "$other" "$other.superseded"
    else
      : >"$other.superseded"
    fi
  done
}

# update_package CONF: brings the package of CONF to the newest release and
# sets $landed when the listed version changed; status 1 with the reason in
# $reason when it cannot.
update_package() {
  local conf=$1 package arch url asset checksums prefix suffix
  local sums line sha name version found_sha='' found_name='' matches=0 status
  local deb field current other stray
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

  # Already held: nothing to download. A superseded DEB is listed again: the
  # vendor went back to that release. Another DEB that is not marked comes from
  # a run killed between the rename of this one and marking that one.
  for current in "$repo/${package}_"*.deb; do
    [[ -f $current ]] || continue
    [[ $(sha256_of "$current") == "$found_sha" ]] || continue
    stray=0
    for other in "$repo/${package}_"*.deb; do
      [[ $other != "$current" && ! -e $other.superseded ]] && stray=1
    done
    if [[ -e $current.superseded ]]; then
      say "$package: back to $found_name"
    elif ((!stray)); then
      return 0
    fi
    list_only "$package" "$current"
    landed=1
    return 0
  done

  deb=$work/$found_name
  say "$package: downloading $found_name"
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

  # The new DEB becomes the only listed version of the package.
  name=${package}_${version//:/%3a}_${field}.deb
  sync -- "$deb"
  mv -f -- "$deb" "$repo/$name" || {
    reason="cannot move $found_name into $repo; keeping the current package"
    return 1
  }
  list_only "$package" "$repo/$name"
  landed=1
  say "$package: $version added"
}

# write_index: commits Packages and Release of the listed DEBs, unless Release
# already commits that index.
write_index() {
  local deb packages=$work/Packages release=$work/Release copy=$work/by-hash
  local sha size stamp previous kept
  : >"$packages"
  for deb in "$repo"/*.deb; do
    [[ -f $deb && ! -e $deb.superseded ]] || continue
    {
      dpkg-deb -f "$deb" || return 1
      printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' \
        "$(basename -- "$deb")" "$(stat -c %s -- "$deb")" "$(sha256_of "$deb")"
    } >>"$packages" || return 1
  done
  sha=$(sha256_of "$packages") || return 1
  size=$(stat -c %s -- "$packages") || return 1
  kept=''
  if [[ -f $repo/Release ]]; then
    kept=$(sed -n 's/^ \([0-9a-f]\{64\}\) [0-9]* Packages$/\1/p' "$repo/Release")
  fi
  if [[ $kept == "$sha" && $(sha256_of "$repo/by-hash/SHA256/$sha" 2>/dev/null) == "$sha" &&
    $(sha256_of "$repo/Packages" 2>/dev/null) == "$sha" ]]; then
    return 0
  fi

  # Dated after the Release it replaces, whatever the clock says.
  stamp=$(date -u +%s) || return 1
  if [[ -f $repo/Release ]]; then
    previous=$(sed -n 's/^Date: //p' "$repo/Release")
    if previous=$(date -u -d "$previous" +%s 2>/dev/null) && ((previous >= stamp)); then
      stamp=$((previous + 1))
    fi
  fi
  {
    printf 'Origin: dotsteward\nLabel: dotsteward-apt-bridge\n'
    printf 'Date: %s\n' "$(LC_ALL=C date -u -d "@$stamp" '+%a, %d %b %Y %H:%M:%S UTC')"
    printf 'Acquire-By-Hash: yes\n'
    printf 'SHA256:\n %s %s Packages\n' "$sha" "$size"
  } >"$release" || return 1

  # by-hash keeps what Release names until now and what a day of commits named,
  # for an APT that read one of them, and gets the new index; the rename of
  # Release is the commit.
  mkdir -p -- "$repo/by-hash/SHA256" || return 1
  find "$repo/by-hash/SHA256" -type f -mtime +0 ! -name "$kept" ! -name "$sha" -delete
  cp -- "$packages" "$copy" || return 1
  mv -f -- "$copy" "$repo/by-hash/SHA256/$sha" || return 1
  mv -f -- "$packages" "$repo/Packages" || return 1
  sync -- "$repo/by-hash/SHA256/$sha" "$repo/by-hash/SHA256" "$repo/Packages" "$release" "$repo"
  mv -f -- "$release" "$repo/Release"
}

if [[ ${DOTSTEWARD_CHECK_ONLY:-0} == 1 ]]; then
  say "check only: $repo stays as it is"
  exit 0
fi

mkdir -p -- "$repo" || exit 0
exec 9>"$repo/.lock" || exit 0
if ! flock -n 9; then
  say "another run holds $repo/.lock; waiting for it"
  flock -w "${DOTSTEWARD_APT_BRIDGE_LOCK_WAIT:-600}" 9 || {
    say "another run holds $repo/.lock; skipped"
    exit 0
  }
fi
# Holding the lock, whatever is still there comes from a run that was killed.
rm -rf -- "$repo"/.partial.*
# timeout signals this shell and then its whole group. Without a trap, bash ends
# at once on a second signal while it handles the first, before its EXIT trap
# runs; and that trap must not lose its cleanup to a signal either. The traps
# come first: a signal right after mktemp would leave the directory behind.
work=''
trap 'exit 143' HUP INT TERM
trap 'trap "" HUP INT TERM; [[ -z $work ]] || rm -rf -- "$work"' EXIT
work=$(mktemp -d "$repo/.partial.XXXXXX") || exit 0

if [[ ! -f $repo/Release ]]; then
  write_index || say "cannot write the index of $repo"
fi
for conf in "$conf_dir"/*.conf; do
  [[ -f $conf ]] || continue
  reason=''
  label=''
  landed=0
  update_package "$conf" || say "${label:-$conf}: $reason"
  if ((landed)); then
    write_index || say "cannot write the index of $repo"
  fi
done
# Also what a killed run did not commit, and the form an older framework wrote.
write_index || say "cannot write the index of $repo"
exit 0
