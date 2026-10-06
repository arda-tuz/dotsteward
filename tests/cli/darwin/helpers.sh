# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# Helpers for the darwin platform layer tests (tests/cli/darwin). Not a test
# file.
#
# Sourcing this file makes the running platform darwin
# (DOTSTEWARD_PLATFORM=darwin) and builds, inside DS_TEST_ROOT:
#   darwin_fw     a copy of the framework under test (cli/, schema/, VERSION,
#                 an empty modules/components, so the catalog is empty) with
#                 a fake `preflight` command that records "preflight ARG..."
#                 in the call log and succeeds
#   darwin_inst   a synthetic darwin instance: workstation.toml with
#                 nix.systems = ["aarch64-darwin"] and the profiles
#                 "workstation" (adopt mode) and "fresh" (fresh mode), an
#                 empty versions.lock.json and the manifest mirror
#                 .dotsteward/manifest.aarch64-darwin.json without components
#
#   darwin_use_tools NAME...
#                 puts the macOS tool doubles of tests/cli/darwin/tools
#                 (ditto, hdiutil) first on PATH; each records its calls in
#                 the call log like a stub (ds_calls_of NAME)
#   darwin_tool_set NAME KEY VALUE
#                 a state value a tool double reads (see its header)
#   in_darwin_lib SCRIPT [ARG...]
#                 runs SCRIPT in a fresh bash that sourced lib.sh of the
#                 framework under test (so platform-darwin.sh); ARG... are
#                 $1...
#   add_app NAME INSTALL_JSON [METHOD] [PROFILES_JSON]
#                 enables NAME in workstation.toml and appends it to the
#                 manifest with METHOD (default app-archive), the install
#                 block INSTALL_JSON and the profiles PROFILES_JSON (default
#                 null: every profile)
#   lock_set PATH JSON
#                 sets the dotted lock PATH of versions.lock.json to JSON
#   pin_archive PATH FILE URL VERSION
#                 serves FILE at URL through the curl stub and writes
#                 { minimum_version, url, size, sha256 } of FILE at PATH
#   make_bundle DIR APP VERSION [xml|binary|none]
#                 writes the application bundle DIR/APP: Contents/Info.plist
#                 (CFBundleShortVersionString VERSION, as an XML or binary
#                 property list, or none), an executable Contents/MacOS/app
#                 and a framework whose Versions/Current is a symlink
#   make_zip ARCHIVE DIR
#                 a zip of the entries of DIR (symlinks and modes kept), as
#                 the vendor archives hold the bundle at their root
#   make_dmg IMAGE DIR
#                 a disk image of the tool double hdiutil: a tar of DIR
#                 followed by a 512-byte UDIF trailer starting with "koly"
#   run_install ARG...
#                 runs `dotsteward --instance <instance> install ARG...` of
#                 the copy
#   in_methods_shell SCRIPT [ARG...]
#                 runs SCRIPT in a fresh bash that sourced lib.sh, config.sh
#                 and methods.sh of the copy and loaded the instance
#                 configuration and its manifest; ARG... are $1...
#   temp_dirs     the dotsteward-* directories left in TMPDIR, one per line

export DOTSTEWARD_PLATFORM=darwin

darwin_lib_dir=$DS_REPO_ROOT/cli/lib
darwin_tools_dir=$DS_REPO_ROOT/tests/cli/darwin/tools
darwin_fw=$DS_TEST_ROOT/framework
darwin_inst=$DS_TEST_ROOT/instance
darwin_manifest=$darwin_inst/.dotsteward/manifest.aarch64-darwin.json

darwin_use_tools() {
  local bin=$DS_TEST_ROOT/darwin-tools name
  mkdir -p "$bin"
  for name in "$@"; do
    [[ -f $darwin_tools_dir/$name ]] || ds_fail "unknown macOS tool double: $name"
    ln -sfn "$darwin_tools_dir/$name" "$bin/$name"
  done
  case ":$PATH:" in
    ":$bin:"*) ;;
    *) export PATH=$bin:$PATH ;;
  esac
  hash -r
}

darwin_tool_set() {
  mkdir -p "$DS_STUB_STATE/$1"
  printf '%s\n' "$3" >"$DS_STUB_STATE/$1/$2"
}

in_darwin_lib() {
  local script=$1
  shift
  bash --noprofile --norc -c "source \"\$0\"; $script" "$darwin_lib_dir/lib.sh" "$@"
}

mkdir -p "$darwin_fw/modules/components" "$darwin_inst/.dotsteward"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$darwin_fw/"

cat >"$darwin_fw/cli/commands/preflight.sh" <<EOF
# summary: fake preflight of the darwin platform tests
set -euo pipefail
source '$DS_REPO_ROOT/tests/lib/harness.sh'
ds_record_call preflight "\$@"
printf '{"route": "fast"}\n'
EOF

cat >"$darwin_inst/workstation.toml" <<'EOF'
schema_version = 1

[identity]
username = "dotsteward-test"

[instance]
name = "workstation"
remote = "git@github.com:example-org/workstation.git"

[nix]
systems = ["aarch64-darwin"]
state_version = "26.05"

[profiles]
names = ["workstation", "fresh"]
default = "workstation"
check = "workstation"
bootstrap = "fresh"

[profiles.workstation]
mode = "adopt"

[profiles.fresh]
mode = "fresh"
EOF

printf '{\n  "schema_version": "1.0"\n}\n' >"$darwin_inst/versions.lock.json"

jq -n '{
  schema_version: 1,
  system: "aarch64-darwin",
  platform: "darwin",
  framework: { version: "0.0.0" },
  components: [],
  hooks: {
    pre_activate: [], system_install: [], post_install: [], forbid: [],
    agents_install: [], agents_migrate: [], agents_post: [], desktop_apply: []
  }
}' >"$darwin_manifest"

add_app() {
  local name=$1 install=$2 method=${3:-app-archive} profiles=${4:-null} tmp
  {
    printf '\n[components.%s]\nenable = true\n' "$name"
    if [[ $profiles != null ]]; then
      printf 'profiles = %s\n' "$(jq -c . <<<"$profiles")"
    fi
  } >>"$darwin_inst/workstation.toml"
  tmp=$(mktemp "$DS_TEST_ROOT/manifest.XXXXXX")
  jq --arg name "$name" --arg method "$method" --argjson install "$install" --argjson profiles "$profiles" '
    .components += [{
      name: $name,
      source: "instance",
      method: $method,
      profiles: $profiles,
      platforms: ["darwin"],
      options: {},
      modes: ({ workstation: "adopt", fresh: "fresh" }
        | with_entries(select($profiles == null or (.key as $p | $profiles | index($p))))),
      supported_methods: { linux: [], darwin: [$method] },
      install: $install
    }]' "$darwin_manifest" >"$tmp"
  mv -- "$tmp" "$darwin_manifest"
}

lock_set() {
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 --arg path "$path" --argjson value "$value" \
    'setpath($path | split("."); $value)' "$darwin_inst/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$darwin_inst/versions.lock.json"
}

pin_archive() {
  local path=$1 file=$2 url=$3 version=$4 size sha
  ds_curl_serve "$url" "$file"
  size=$(stat -c %s -- "$file")
  sha=$(sha256sum -- "$file" | awk '{print $1}')
  lock_set "$path" "$(jq -n --arg v "$version" --arg u "$url" --argjson s "$size" --arg h "$sha" \
    '{ minimum_version: $v, url: $u, size: $s, sha256: $h }')"
}

make_bundle() {
  local dir=$1 app=$2 version=$3 format=${4:-xml} bundle
  bundle=$dir/$app
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks/Example.framework/Versions/A"
  printf '#!/bin/sh\necho "%s %s"\n' "$app" "$version" >"$bundle/Contents/MacOS/app"
  chmod 0755 "$bundle/Contents/MacOS/app"
  printf '%s\n' "$version" >"$bundle/Contents/Frameworks/Example.framework/Versions/A/version"
  ln -sfn A "$bundle/Contents/Frameworks/Example.framework/Versions/Current"
  [[ $format == none ]] && return 0
  python3 -I - "$bundle/Contents/Info.plist" "$version" "$format" <<'PY'
import plistlib
import sys

path, version, form = sys.argv[1:]
document = {
    "CFBundleExecutable": "app",
    "CFBundleIdentifier": "org.example.app",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
}
with open(path, "wb") as handle:
    plistlib.dump(document, handle, fmt=plistlib.FMT_BINARY if form == "binary" else plistlib.FMT_XML)
PY
}

make_zip() {
  python3 -I - "$1" "$2" <<'PY'
import os
import stat
import sys
import zipfile

archive, root = sys.argv[1:]
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as out:
    for directory, dirs, files in sorted(os.walk(root)):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                info = zipfile.ZipInfo(relative)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                out.writestr(info, os.readlink(path))
            elif stat.S_ISDIR(mode):
                info = zipfile.ZipInfo(relative + "/")
                info.create_system = 3
                info.external_attr = (stat.S_IFDIR | stat.S_IMODE(mode)) << 16
                out.writestr(info, b"")
            else:
                info = zipfile.ZipInfo(relative)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | stat.S_IMODE(mode)) << 16
                with open(path, "rb") as handle:
                    out.writestr(info, handle.read(), zipfile.ZIP_DEFLATED)
PY
}

make_dmg() {
  local image=$1 dir=$2
  tar -C "$dir" -cf "$image" .
  {
    printf 'koly'
    head -c 508 /dev/zero
  } >>"$image"
}

run_install() {
  "$darwin_fw/cli/dotsteward" --instance "$darwin_inst" install "$@"
}

in_methods_shell() {
  local script=$1
  shift
  bash --noprofile --norc -c '
    lib=$0
    script=$1
    shift
    source "$lib/lib.sh"
    source "$lib/config.sh"
    source "$lib/methods.sh"
    config_load "'"$darwin_inst"'"
    methods_manifest_load
    eval "$script"
  ' "$darwin_fw/cli/lib" "$script" "$@"
}

temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -print | LC_ALL=C sort
}
