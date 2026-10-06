# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# Helpers for the install methods tests (tests/cli/methods). Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   methods_fw    a copy of the framework under test (cli/, schema/, VERSION,
#                 an empty modules/components, so the catalog is empty) with
#                 a fake `preflight` command: it records "preflight ARG..." in
#                 the call log, prints a JSON line like the real one and
#                 exits with the status set by preflight_exit (default 0)
#   methods_inst  a synthetic instance: workstation.toml with the profiles
#                 "workstation" (adopt mode) and "fresh" (fresh mode), an
#                 empty versions.lock.json and the manifest mirror
#                 .dotsteward/manifest.x86_64-linux.json without components
#
#   add_component NAME METHOD INSTALL_JSON [PROFILES_JSON]
#                 enables NAME in workstation.toml and appends it to the
#                 manifest with the install block INSTALL_JSON (the manifest
#                 keeps the contract's camelCase install keys) and the
#                 profiles PROFILES_JSON (default null: every profile)
#   add_hook LIST COMPONENT NAME [PHASE] [PROFILES_JSON]
#                 adds a hook (LIST: system_install, post_install or forbid)
#                 whose script, read from standard input, is written to
#                 components/COMPONENT/NAME.sh and referenced as
#                 <instance>/components/COMPONENT/NAME.sh
#   manifest_edit JQ_FILTER [JQ_OPTION...]
#                 rewrites the manifest mirror with a jq filter
#   lock_set PATH JSON
#                 sets the dotted lock PATH of versions.lock.json to JSON
#   pin_download PATH FILE URL VERSION
#                 serves FILE at URL through the curl stub and writes
#                 { minimum_version, url, size, sha256 } of FILE at PATH
#   preflight_exit STATUS
#                 the exit status of the fake preflight command
#   run_install ARG...
#                 runs `dotsteward --instance <instance> install ARG...` of
#                 the copy
#   in_methods_shell SCRIPT [ARG...]
#                 runs SCRIPT in a fresh bash that sourced lib.sh, config.sh
#                 and methods.sh of the copy and loaded the instance
#                 configuration (config_load) and its manifest
#                 (methods_manifest_load); ARG... are $1...
#   temp_dirs     the dotsteward-* directories left in TMPDIR, one per line

methods_fw=$DS_TEST_ROOT/framework
methods_inst=$DS_TEST_ROOT/instance
methods_manifest=$methods_inst/.dotsteward/manifest.x86_64-linux.json

mkdir -p "$methods_fw/modules/components" "$methods_inst/.dotsteward" "$methods_inst/components"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$methods_fw/"

# The fake preflight replaces a real one in the copy; its status file lives
# in the test root.
cat >"$methods_fw/cli/commands/preflight.sh" <<EOF
# summary: fake preflight of the install methods tests
set -euo pipefail
source '$DS_REPO_ROOT/tests/lib/harness.sh'
ds_record_call preflight "\$@"
status=0
if [[ -f '$DS_TEST_ROOT/preflight-status' ]]; then
  status=\$(<'$DS_TEST_ROOT/preflight-status')
fi
printf '{"route": "%s"}\n' "\$( ((status == 0)) && echo fast || echo adaptive)"
exit "\$status"
EOF

cat >"$methods_inst/workstation.toml" <<'EOF'
schema_version = 1

[identity]
username = "dotsteward-test"

[instance]
name = "workstation"
remote = "git@github.com:example-org/workstation.git"

[nix]
systems = ["x86_64-linux"]
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

printf '{\n  "schema_version": "1.0"\n}\n' >"$methods_inst/versions.lock.json"

jq -n '{
  schema_version: 1,
  system: "x86_64-linux",
  platform: "linux",
  framework: { version: "0.0.0" },
  components: [],
  hooks: {
    pre_activate: [], system_install: [], post_install: [], forbid: [],
    agents_install: [], agents_migrate: [], agents_post: [], desktop_apply: []
  }
}' >"$methods_manifest"

manifest_edit() {
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$DS_TEST_ROOT/manifest.XXXXXX")
  jq "$@" "$filter" "$methods_manifest" >"$tmp"
  mv -- "$tmp" "$methods_manifest"
}

add_component() {
  local name=$1 method=$2 install=$3 profiles=${4:-null}
  # A component added again (after manifest_edit removed it) keeps its
  # table.
  if ! grep -qxF "[components.$name]" "$methods_inst/workstation.toml"; then
    {
      printf '\n[components.%s]\nenable = true\n' "$name"
      if [[ $profiles != null ]]; then
        printf 'profiles = %s\n' "$(jq -c . <<<"$profiles")"
      fi
    } >>"$methods_inst/workstation.toml"
  fi
  manifest_edit '.components += [{
      name: $name,
      source: "instance",
      method: $method,
      profiles: $profiles,
      platforms: ["linux"],
      options: {},
      modes: ({ workstation: "adopt", fresh: "fresh" }
        | with_entries(select($profiles == null or (.key as $p | $profiles | index($p))))),
      supported_methods: { linux: [$method], darwin: [] },
      install: $install
    }]' \
    --arg name "$name" --arg method "$method" --argjson install "$install" \
    --argjson profiles "$profiles"
}

add_hook() {
  local list=$1 component=$2 name=$3 phase=${4:-main} profiles=${5:-null}
  local script=$methods_inst/components/$component/$name.sh
  mkdir -p "$(dirname "$script")"
  {
    printf '#!%s\n' "$BASH"
    cat
  } >"$script"
  chmod 0755 "$script"
  manifest_edit '.hooks[$list] += [{
      component: $component, name: $name, phase: $phase, profiles: $profiles,
      script: ("<instance>/components/" + $component + "/" + $name + ".sh")
    }]' \
    --arg list "$list" --arg component "$component" --arg name "$name" \
    --arg phase "$phase" --argjson profiles "$profiles"
}

lock_set() {
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 --arg path "$path" --argjson value "$value" \
    'setpath($path | split("."); $value)' "$methods_inst/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$methods_inst/versions.lock.json"
}

pin_download() {
  local path=$1 file=$2 url=$3 version=$4 size sha
  ds_curl_serve "$url" "$file"
  size=$(stat -c %s -- "$file")
  sha=$(sha256sum -- "$file" | awk '{print $1}')
  lock_set "$path" "$(jq -n --arg v "$version" --arg u "$url" --argjson s "$size" --arg h "$sha" \
    '{ minimum_version: $v, url: $u, size: $s, sha256: $h }')"
}

preflight_exit() {
  printf '%s\n' "$1" >"$DS_TEST_ROOT/preflight-status"
}

run_install() {
  "$methods_fw/cli/dotsteward" --instance "$methods_inst" install "$@"
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
    config_load "'"$methods_inst"'"
    methods_manifest_load
    eval "$script"
  ' "$methods_fw/cli/lib" "$script" "$@"
}

temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -print | LC_ALL=C sort
}
