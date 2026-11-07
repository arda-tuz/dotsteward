# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the preflight of the generated stage-0 bootstrap, before Nix and
# without jq, on the system bash of this release. A platform file that declares this
# release with a fast path gives it the fast route; without one it takes the adaptive route.
release=$(. /etc/os-release && printf '%s' "$VERSION_ID")
arch=$(uname -m)
inst=$DS_TEST_ROOT/instance
mkdir -p "$inst/.dotsteward"
# Stage 0 runs before jq exists: a jq first on PATH that fails and leaves a mark.
shim=$DS_TEST_ROOT/no-jq
mkdir -p "$shim"
printf '#!/bin/sh\n: >"%s/jq-called"\nexit 127\n' "$DS_TEST_ROOT" >"$shim/jq"
chmod 0755 "$shim/jq"
export PATH=$shim:$PATH

# mirror [PLATFORM_LINE...]: the stage-0 mirror of a synthetic instance whose
# workstation.toml fast path is another release.
mirror() {
  {
    printf 'DS_STAGE0_SCHEMA_VERSION=1\nDS_STAGE0_SYSTEM=x86_64-linux\nDS_STAGE0_PLATFORM=linux\n'
    printf 'DS_STAGE0_INSTANCE_REMOTE=/nonexistent/remote.git\n'
    printf 'DS_STAGE0_PROFILES=(fresh)\nDS_STAGE0_PROFILE_MODES=(fresh=fresh)\n'
    printf 'DS_STAGE0_DEFAULT_PROFILE=fresh\nDS_STAGE0_CHECK_PROFILE=fresh\nDS_STAGE0_BOOTSTRAP_PROFILE=fresh\n'
    printf 'DS_STAGE0_FAST_PATH_OS_ID=ubuntu\nDS_STAGE0_FAST_PATH_OS_VERSION=10.04\n'
    printf 'DS_STAGE0_FAST_PATH_ARCHITECTURE=%s\n' "$arch"
    printf "DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS=''\nDS_STAGE0_FAST_PATH_DETECTORS=()\nDS_STAGE0_DETECTORS=()\n"
    printf '%s\n' "$@"
  } >"$inst/.dotsteward/stage0.linux.env"
}

# preflight: the route the stage-0 functions of bootstrap.sh take, on standard output.
preflight() {
  local out status=0
  out=$(bash --noprofile --norc -c '
    set -Eeuo pipefail
    source <(sed "\$d" /framework/template/bootstrap.sh)
    preflight_load_env "$1" linux
    preflight_parse --read-only --json
    preflight_run' preflight "$inst" 2>"$DS_TEST_ROOT/preflight.err") || status=$?
  grep -o '"route": "[a-z]*"' <<<"$out" || true
  return "$status"
}

mirror
assert_exit 3 preflight
assert_contains "$DS_STDOUT" '"route": "adaptive"'

mirror "DS_STAGE0_PLATFORM_IDS=(ubuntu-$release)" "DS_STAGE0_PLATFORM_OS_IDS=(ubuntu)" \
  "DS_STAGE0_PLATFORM_OS_VERSIONS=($release)" "DS_STAGE0_PLATFORM_ARCHITECTURES=($arch)"
assert_exit 0 preflight
assert_contains "$DS_STDOUT" '"route": "fast"'

mirror "DS_STAGE0_PLATFORM_IDS=(ubuntu-$release)" "DS_STAGE0_PLATFORM_OS_IDS=(ubuntu)" \
  "DS_STAGE0_PLATFORM_OS_VERSIONS=($release)" "DS_STAGE0_PLATFORM_ARCHITECTURES=(riscv128)"
assert_exit 3 preflight
[[ ! -e $DS_TEST_ROOT/jq-called ]] || ds_fail "stage 0 called jq"
