# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The fast path of a platform file: a release that platforms/<id>.toml declares with a
# [fast_path] takes the fast route like the one of workstation.toml, through the
# DS_STAGE0_PLATFORM_* arrays of the stage-0 mirror; the desktop rule of workstation.toml
# still applies.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs nix

# 22.04 is not the fast path of workstation.toml.
cp "$(ds_fixture common/os-release/ubuntu-22.04)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_preflight --read-only --json
assert_json - '.route == "adaptive" and .fast_path == false' <<<"$DS_STDOUT"

# A platform file declares it.
stage0_env_set linux \
  'DS_STAGE0_PLATFORM_IDS=(ubuntu-22.04 ubuntu-26.04)' \
  'DS_STAGE0_PLATFORM_OS_IDS=(ubuntu ubuntu)' \
  'DS_STAGE0_PLATFORM_OS_VERSIONS=(22.04 26.04)' \
  "DS_STAGE0_PLATFORM_ARCHITECTURES=($bs_arch riscv128)"
assert_exit 0 run_preflight --read-only --json
assert_json - '.route == "fast" and .fast_path == true and .platform.os_version == "22.04"' <<<"$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_exit 0 run_preflight --read-only
assert_eq "[dotsteward] route=fast os=ubuntu-22.04 arch=$bs_arch desktop=unknown" "$DS_STDOUT"

# The fast path of workstation.toml still holds.
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 0 run_preflight --read-only --json
assert_json - '.route == "fast"' <<<"$DS_STDOUT"

# A platform file for another architecture is not this machine's.
printf 'ID=ubuntu\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\n' >"$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_preflight --read-only --json
assert_json - '.route == "adaptive"' <<<"$DS_STDOUT"

# The desktop rule of workstation.toml is part of every fast path.
cp "$(ds_fixture common/os-release/ubuntu-22.04)" "$DOTSTEWARD_OS_RELEASE"
stage0_env_set linux "DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS=exampledesk"
assert_exit 3 run_preflight --read-only --json
assert_json - '.route == "adaptive"' <<<"$DS_STDOUT"
XDG_CURRENT_DESKTOP=ubuntu:ExampleDesk assert_exit 0 run_preflight --read-only --json
assert_json - '.route == "fast"' <<<"$DS_STDOUT"

# A mirror without the arrays, from before platform files, keeps its one fast path.
stage0_env_write linux
assert_exit 3 run_preflight --read-only --json
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 0 run_preflight --read-only --json
