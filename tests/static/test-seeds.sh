# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Component seeds (SPEC 5.6): every modules/components/<c>/seed.json
# validates against schema/seed.schema.json, names its own component, and
# declares the same flake inputs in flake_inputs and versions_lock; and every
# lock path a catalog component reads exists in its seed or in the template
# lock (tests/static/seed-lock-paths.nix, which evaluates the catalog the
# way lib.mkInstance does).
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# seed_lock_problems FRAMEWORK: prints the lock-path problems of the catalog
# of the framework source FRAMEWORK, a compact JSON array of messages
# (tests/static/seed-lock-paths.nix, evaluated against an isolated store).
seed_lock_problems() {
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  local out=$DS_TEST_ROOT/seed-lock-paths.out err=$DS_TEST_ROOT/seed-lock-paths.err
  env -u NIX_REMOTE -u NIX_PATH \
    NIX_STORE_DIR="$nix_lib_store/store" \
    NIX_STATE_DIR="$nix_lib_store/state" \
    NIX_LOG_DIR="$nix_lib_store/log" \
    NIX_CONF_DIR="$nix_lib_store/etc" \
    NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
    nix-instantiate --eval --strict --json --show-trace \
    --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$1" \
    "$1/tests/static/seed-lock-paths.nix" >"$out" 2>"$err" ||
    ds_fail "lock-path evaluation of $1 failed: $(<"$err")"
  jq -c . "$out"
}

schema=$DS_REPO_ROOT/schema/seed.schema.json
[[ -f $schema ]] || ds_fail "missing schema/seed.schema.json"
assert_json "$schema" '.type == "object" and (.required | index("schema_version") != null)
  and .properties.schema_version.const == 1 and .additionalProperties == false'

# The real tree.
cd "$DS_REPO_ROOT"
assert_exit 0 static --sandbox --only seeds
assert_eq '[]' "$(seed_lock_problems "$DS_REPO_ROOT")" "lock paths of the real catalog"

fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
comp=$fw/modules/components/example-term
mkdir -p "$comp"
rev=0123456789abcdef0123456789abcdef01234567

# write_seed JQ_FILTER: the valid seed below, transformed by JQ_FILTER.
write_seed() {
  jq -n --arg rev "$rev" '{
    schema_version: 1,
    component: "example-term",
    flake_inputs: { "example-term": { url: "github:example-org/example-term/v0.9.0" } },
    versions_lock: {
      flake_inputs: { "example-term": { reference: "v0.9.0", revision: $rev, version: "0.9.0",
        nar_hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" } },
      nix_packages: { "example-term": { expected: "0.9.0", resolved: "0.9.0" } },
      agent_tools: { "example-term": { version: "0.9.0" } }
    }
  }' | jq "$1" >"$comp/seed.json"
}

write_seed .
assert_exit 0 fw_static "$fw" --sandbox --only seeds
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): seeds"

# Optional flake input attributes.
write_seed '.flake_inputs["example-term"] += { flake: false, inputs: { nixpkgs: { follows: "nixpkgs" } } }'
assert_exit 0 fw_static "$fw" --sandbox --only seeds

# check_bad FILTER MESSAGE: the transformed seed fails with MESSAGE.
check_bad() {
  write_seed "$1"
  assert_exit 1 fw_static "$fw" --sandbox --only seeds
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: static seeds: modules/components/example-term/seed.json: $2"
}
check_bad '.schema_version = 2' 'schema_version: expected 1, got 2'
check_bad '.component = "example-app"' 'component "example-app" does not match its directory example-term'
check_bad '. + { extra: true }' 'unknown key extra'
check_bad 'del(.versions_lock)' 'missing required key versions_lock'
check_bad '.versions_lock.flake_inputs["example-term"].revision = "abc"' 'versions_lock.flake_inputs.example-term.revision'
check_bad '.flake_inputs["example-term"] = {}' 'missing required key flake_inputs.example-term.url'
check_bad '.versions_lock.nix_packages["example-term"] = { resolved: "0.9.0" }' \
  'missing required key versions_lock.nix_packages.example-term.expected'
check_bad 'del(.versions_lock.flake_inputs["example-term"])' \
  'flake input example-term has no versions_lock.flake_inputs entry'
check_bad '.versions_lock.flake_inputs.other = .versions_lock.flake_inputs["example-term"]' \
  'versions_lock.flake_inputs.other has no flake_inputs entry'

printf '{ not json\n' >"$comp/seed.json"
assert_exit 1 fw_static "$fw" --sandbox --only seeds
assert_contains "$DS_STDERR" "static seeds: modules/components/example-term/seed.json: invalid JSON"

rm -f "$comp/seed.json"
assert_exit 1 fw_static "$fw" --sandbox --only seeds
assert_contains "$DS_STDERR" "static seeds: modules/components/example-term: missing seed.json"

# Lock paths: a synthetic catalog component that reads lock paths through
# every reader. Its seed provides the official-binary pin and the first flake
# input; the download-pin rule, the external minimum, the probe, the floor
# and the second flake input read paths it lacks. Literal floor versions,
# rule templates and fields that are not lock paths are not read.
cat >"$comp/default.nix" <<'EOF'
{ lib, ... }:
{
  dotsteward.components.example-term = {
    method = lib.mkDefault "official-binary";
    supportedMethods = {
      linux = [
        "official-binary"
        "external"
      ];
      darwin = [ "nix" ];
    };
    install = {
      official-binary = {
        pin = "agent_tools.example-term";
        asset = {
          linux = "example-term-{version}-x86_64-linux.tar.gz";
          darwin = "example-term-{version}-aarch64-darwin.tar.gz";
        };
        member = "example-term";
        dest = "~/.local/bin/example-term";
        versionArgv = [ "--version" ];
        versionRegex = "example-term ([0-9.]+)";
        policy = "at-least";
        verify = "sha256";
      };
      external.minimum = "agent_tools.example-term.minimum";
    };
    pins = {
      flakeInputs = [
        "example-term"
        "example-extra"
      ];
      rules = [
        {
          kind = "download-pin";
          at = "desktop_packages.example-term";
          url_contains = "example-term_{version}";
        }
        {
          kind = "derive";
          to = "nix_packages.{name}.expected";
          from = "flake_inputs.{name}.version";
          for_each = [ "example-term" ];
        }
      ];
    };
    probes = [
      {
        command = "example-term";
        kind = "version";
        expected = "versions:nix_packages.example-term.expected";
      }
    ];
    checks.floors = [
      {
        command = "example-term";
        argv = [ "--version" ];
        minimum = "desktop_packages.example-term.floor";
        compare = "dpkg";
      }
      {
        command = "example-term";
        argv = [ "--version" ];
        minimum = "1.2.0";
        compare = "semver";
      }
      {
        command = "example-term";
        argv = [ "--version" ];
        minimum = "v2.0.1";
        compare = "semver";
      }
    ];
  };
}
EOF
write_seed 'del(.versions_lock.nix_packages)'
assert_exit 0 fw_static "$fw" --sandbox --only seeds
assert_eq "$(jq -nc '[
    "example-term/seed.json: lock path agent_tools.example-term.minimum read by install.external.minimum is missing",
    "example-term/seed.json: lock path desktop_packages.example-term read by pins.rules download-pin.at is missing",
    "example-term/seed.json: lock path desktop_packages.example-term.floor read by floor example-term is missing",
    "example-term/seed.json: lock path flake_inputs.example-extra read by pins.flakeInputs is missing",
    "example-term/seed.json: lock path nix_packages.example-term.expected read by probe example-term is missing"
  ]')" "$(seed_lock_problems "$fw")" "lock paths the seed lacks"

# The seed provides the paths of the rule, the minimum and the probe, the
# template lock those of the floor and the second flake input.
write_seed '.versions_lock.desktop_packages["example-term"] = { version: "0.9.0" }
  | .versions_lock.agent_tools["example-term"].minimum = "0.9.0"'
mkdir -p "$fw/template"
jq -n '{
  desktop_packages: { "example-term": { floor: "0.9.0" } },
  flake_inputs: { "example-extra": { reference: "v1.0.0" } }
}' >"$fw/template/versions.lock.json"
assert_exit 0 fw_static "$fw" --sandbox --only seeds
assert_eq '[]' "$(seed_lock_problems "$fw")" "lock paths in the seed and the template lock"
