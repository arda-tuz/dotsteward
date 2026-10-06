# shellcheck shell=bash
# HTTP adapters against the loopback server: apt-index (index location from
# dist, component and [pins] apt_arch, holdbacks, a package missing from the
# index), deb-url (Content-Disposition file names, declared redirect
# patterns, unreadable versions) and official-manifest (format changes are
# error rows with the row id, never a silent pass).
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
url=$DS_HTTPFIX_URL

# --- apt-index ---------------------------------------------------------------

mkdir -p "$www/apt/dists/noble/contrib/binary-arm64"
cat >"$www/apt/dists/noble/contrib/binary-arm64/Packages" <<'EOF'
Package: example-other
Version: 9.0.0
Architecture: arm64
Filename: pool/contrib/e/example-other/example-other_9.0.0_arm64.deb
Size: 300
SHA256: 18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4

Package: example-app
Version: 1.4.0
Architecture: arm64
Filename: pool/contrib/e/example-app/example-app_1.4.0_arm64.deb
Size: 200
SHA256: 3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea
Description: Synthetic package
 with a continuation line: Version: 99.0.0

Package: example-app
Version: 1.3.9
Architecture: arm64
Filename: pool/contrib/e/example-app/example-app_1.3.9_arm64.deb
Size: 199
SHA256: 252f10c83610ebca1a059c0bae8255eba2f95be4d1d7bcfa89d7248a82d9f111
EOF
printf '\n[pins]\napt_arch = "arm64"\n' >>"$inst/workstation.toml"
# The APT component is apt_component: "component" names the declaring
# dotsteward component in the manifest.
declare_latest "{\"component\":\"example-app\",\"id\":\"desktop_packages.example-app\",\"adapter\":\"apt-index\",\"at\":\"desktop_packages.example-app\",\"base\":\"$url/apt\",\"package\":\"example-app\",\"dist\":\"noble\",\"apt_component\":\"contrib\"}"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"desktop_packages.example-app\",\"kind\":\"apt-index\",\"current\":\"1.1.0\",\"latest\":\"1.4.0\",\"status\":\"update\",\"source\":\"$url/apt\",\"details\":{\"url\":\"$url/apt/pool/contrib/e/example-app/example-app_1.4.0_arm64.deb\",\"size\":200,\"sha256\":\"3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea\"}}" \
  "$(row desktop_packages.example-app)"
assert_contains "$(<"$DS_HTTPFIX_LOG")" "GET /apt/dists/noble/contrib/binary-arm64/Packages"$'\n'

# The declared arch wins over [pins] apt_arch; dist defaults to stable and
# the component to main.
declare_latest "{\"component\":\"example-app\",\"id\":\"desktop_packages.example-app\",\"adapter\":\"apt-index\",\"base\":\"$url/apt\",\"package\":\"example-app\",\"arch\":\"amd64\"}"
assert_exit 0 latest --out "$report"
assert_eq '["1.1.0","1.2.3","update"]' "$(row desktop_packages.example-app '[.current, .latest, .status]')"

# A holdback.
json_edit "$versions" 'data["desktop_packages"]["example-app"]["holdback_reason"] = "1.2 needs a newer desktop session"'
assert_exit 0 latest --out "$report"
assert_eq '["held","1.2 needs a newer desktop session"]' "$(row desktop_packages.example-app '[.status, .details.note]')"

# A package the index does not list: an error row with the row id.
declare_latest "{\"component\":\"example-app\",\"id\":\"desktop_packages.example-app\",\"adapter\":\"apt-index\",\"base\":\"$url/apt\",\"package\":\"example-missing\",\"arch\":\"amd64\"}"
assert_exit 1 latest --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
assert_eq '["apt-index","1.1.0",null,"error"]' "$(row desktop_packages.example-app '[.kind, .current, .latest, .status]')"
assert_contains "$(row desktop_packages.example-app .details.error)" "example-missing is not in the index"

# --- deb-url ------------------------------------------------------------------

json_edit "$versions" 'del data["desktop_packages"]["example-app"]["holdback_reason"]'

# The file name from Content-Disposition, no redirect, no URL template.
mkdir -p "$www/viewer2"
printf 'synthetic viewer package 2.2.0\n' >"$www/viewer2/download"
printf 'Content-Disposition: attachment; filename="example-viewer_2.2.0_amd64.deb"\n' >"$www/viewer2/download.headers"
size2=$(stat -c %s "$www/viewer2/download")
declare_latest "{\"component\":\"example-viewer\",\"id\":\"desktop_packages.example-viewer\",\"adapter\":\"deb-url\",\"latest_url\":\"$url/viewer2/download\"}"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"desktop_packages.example-viewer\",\"kind\":\"deb-url\",\"current\":\"2.0.0\",\"latest\":\"2.2.0\",\"status\":\"update\",\"source\":\"$url/viewer2/download\",\"details\":{\"file\":\"example-viewer_2.2.0_amd64.deb\",\"url\":\"$url/viewer2/download\",\"size\":$size2,\"last_modified\":null}}" \
  "$(row desktop_packages.example-viewer)"

# A declared pattern over the redirect target (plain and named group).
mkdir -p "$www/viewer3/latest" "$www/viewer3/releases/2.3.0"
printf '/viewer3/releases/2.3.0/download\n' >"$www/viewer3/latest/linux.location"
printf 'synthetic viewer package 2.3.0\n' >"$www/viewer3/releases/2.3.0/download"
declare_latest "{\"component\":\"example-viewer\",\"id\":\"desktop_packages.example-viewer\",\"adapter\":\"deb-url\",\"latest_url\":\"$url/viewer3/latest/linux\",\"version_pattern\":\"/releases/([0-9.]+)/download\$\"}"
assert_exit 0 latest --out "$report"
assert_eq "[\"2.3.0\",\"update\",\"download\",\"$url/viewer3/releases/2.3.0/download\"]" \
  "$(row desktop_packages.example-viewer '[.latest, .status, .details.file, .details.url]')"
declare_latest "{\"component\":\"example-viewer\",\"id\":\"desktop_packages.example-viewer\",\"adapter\":\"deb-url\",\"latest_url\":\"$url/viewer3/latest/linux\",\"version_pattern\":\"releases/(?P<version>[^/]+)/\"}"
assert_exit 0 latest --out "$report"
assert_eq '"2.3.0"' "$(row desktop_packages.example-viewer .latest)"

# No version in the resolved file name: an error row, never a silent pass.
mkdir -p "$www/viewer4/files"
printf '/viewer4/files/latest.bin\n' >"$www/viewer4/download.location"
printf 'synthetic\n' >"$www/viewer4/files/latest.bin"
declare_latest "{\"component\":\"example-viewer\",\"id\":\"desktop_packages.example-viewer\",\"adapter\":\"deb-url\",\"latest_url\":\"$url/viewer4/download\"}"
assert_exit 1 latest --out "$report"
assert_eq '["deb-url","2.0.0",null,"error"]' "$(row desktop_packages.example-viewer '[.kind, .current, .latest, .status]')"
assert_contains "$(row desktop_packages.example-viewer .details.error)" "cannot read a version from latest.bin"

# --- official-manifest --------------------------------------------------------

bin_declaration() {
  printf '{"component":"example-bin","id":"agent_tools.example-bin.linux-x64","adapter":"official-manifest","at":"agent_tools.example-bin.linux-x64","version_url":"%s/bin/stable","manifest_url":"%s/bin/{version}/manifest.json","version_field":"version","sha256_field":"%s","size_field":"platforms.linux-x64.size","url_template":"%s/bin/{version}/linux-x64/example-bin"}' \
    "$url" "$url" "$1" "$url"
}

# The version endpoint and the manifest disagree.
mkdir -p "$www/bin/1.0.3"
printf '1.0.3\n' >"$www/bin/stable"
cp -- "$www/bin/1.0.2/manifest.json" "$www/bin/1.0.3/manifest.json"
declare_latest "$(bin_declaration platforms.linux-x64.checksum)"
assert_exit 1 latest --out "$report"
assert_eq '["official-manifest","1.0.0",null,"error"]' \
  "$(row agent_tools.example-bin.linux-x64 '[.kind, .current, .latest, .status]')"
assert_contains "$(row agent_tools.example-bin.linux-x64 .details.error)" "manifest version 1.0.2 differs from 1.0.3"

# A field the manifest no longer has.
printf '1.0.2\n' >"$www/bin/stable"
declare_latest "$(bin_declaration platforms.linux-arm64.checksum)"
assert_exit 1 latest --out "$report"
assert_eq '"error"' "$(row agent_tools.example-bin.linux-x64 .status)"
assert_contains "$(row agent_tools.example-bin.linux-x64 .details.error)" "manifest lacks platforms.linux-arm64.checksum"

# A manifest that is not JSON.
printf '<html>moved</html>\n' >"$www/bin/1.0.2/manifest.json"
declare_latest "$(bin_declaration platforms.linux-x64.checksum)"
assert_exit 1 latest --out "$report"
assert_eq '"error"' "$(row agent_tools.example-bin.linux-x64 .status)"
assert_contains "$(row agent_tools.example-bin.linux-x64 .details.error)" "is not JSON"

# A version endpoint that answers something that is not a version.
printf 'maintenance\n' >"$www/bin/stable"
assert_exit 1 latest --out "$report"
assert_contains "$(row agent_tools.example-bin.linux-x64 .details.error)" "not a version: 'maintenance'"
