# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Preflight detectors and the desktop part of the Linux fast path (SPEC 4.1
# platform.linux.fast_path): every component detector is run and emitted as
# a platform.<name> boolean (true when its command succeeds and prints the
# match line as a whole line; a missing command is false); the desktop
# matches when no desktop rule is configured, when XDG_CURRENT_DESKTOP
# contains desktop_contains (case-insensitive) or when one of the fast-path
# detectors is true. Also the darwin facts (sw_vers, os_id "macos",
# min_version and architecture).
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs nix example-app

detectors=(
  "DS_STAGE0_DETECTORS=(example_detector other_detector)"
  "DS_STAGE0_DETECTOR_0_ARGV=(example-app detect 'the schemas')"
  "DS_STAGE0_DETECTOR_0_MATCH_LINE='it'\\''s here'"
  "DS_STAGE0_DETECTOR_1_ARGV=(missing-command-of-the-test list)"
  "DS_STAGE0_DETECTOR_1_MATCH_LINE=anything"
)

# Detectors without a desktop rule: emitted, the fast path does not need
# them.
stage0_env_set linux "${detectors[@]}"
ds_stub_route example-app "detect the schemas" --stdout $'first line\nit\'s here\nlast line'
assert_exit 0 run_preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh fast true ubuntu 24.04 "$bs_arch" unknown 2.31.2 "$free" true \
  example_detector=true other_detector=false)" "$DS_STDOUT" "detectors in platform, in order"
assert_call_count 1 example-app "detect the*schemas"

# The match is a whole line, and the command must succeed.
ds_stub_clear_routes example-app
ds_stub_route example-app "detect the schemas" --stdout "it's here, almost"
assert_exit 0 run_preflight --read-only --json
assert_json - '.platform.example_detector == false' <<<"$DS_STDOUT"
ds_stub_clear_routes example-app
ds_stub_route example-app "detect the schemas" --stdout "it's here" --exit 1
assert_exit 0 run_preflight --read-only --json
assert_json - '.platform.example_detector == false' <<<"$DS_STDOUT"

# desktop_contains alone: a case-insensitive substring of
# XDG_CURRENT_DESKTOP.
stage0_env_set linux "DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS=example"
assert_exit 3 run_preflight --read-only --json
assert_json - '.route == "adaptive" and .platform.desktop == "unknown"' <<<"$DS_STDOUT"
assert_exit 0 env XDG_CURRENT_DESKTOP=vendor:EXAMPLE "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json
assert_json - '.route == "fast" and .platform.desktop == "vendor:EXAMPLE"' <<<"$DS_STDOUT"
assert_exit 3 env XDG_CURRENT_DESKTOP=Other "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json

# ORed with the fast-path detectors.
stage0_env_set linux "DS_STAGE0_FAST_PATH_DETECTORS=(example_detector)"
assert_exit 3 env XDG_CURRENT_DESKTOP=Other "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json
ds_stub_clear_routes example-app
ds_stub_route example-app "detect the schemas" --stdout "it's here"
assert_exit 0 env XDG_CURRENT_DESKTOP=Other "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json
assert_json - '.route == "fast" and .platform.example_detector == true and .platform.desktop == "Other"' <<<"$DS_STDOUT"

# Detectors alone (no desktop_contains): one true detector is enough.
stage0_env_set linux "DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS=''" \
  "DS_STAGE0_FAST_PATH_DETECTORS=(other_detector example_detector)"
assert_exit 0 run_preflight --read-only --json
stage0_env_set linux "DS_STAGE0_FAST_PATH_DETECTORS=(other_detector)"
assert_exit 3 run_preflight --read-only --json
assert_json - '.platform.other_detector == false' <<<"$DS_STDOUT"

# A fast-path detector no component provides, and a detector named like a
# platform key, are configuration errors.
stage0_env_set linux "DS_STAGE0_FAST_PATH_DETECTORS=(nowhere)"
assert_exit 1 run_preflight --read-only --json
assert_eq "[dotsteward] ERROR: fast path detector nowhere is not a preflight detector of an enabled component" \
  "$DS_STDERR"
stage0_env_write linux
stage0_env_set linux "DS_STAGE0_DETECTORS=(desktop)" "DS_STAGE0_DETECTOR_0_ARGV=(example-app detect)" \
  "DS_STAGE0_DETECTOR_0_MATCH_LINE=x"
assert_exit 1 run_preflight --read-only --json
assert_eq "[dotsteward] ERROR: preflight detector desktop has the name of a platform fact" "$DS_STDERR"
stage0_env_write linux

# --- darwin -----------------------------------------------------------------
ds_use_stubs xcode-select
export DOTSTEWARD_PLATFORM=darwin
assert_exit 0 run_preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh fast true macos 15.0 "$bs_arch" unknown 2.31.2 "$free" true)" \
  "$DS_STDOUT" "darwin fast route"
# min_version is compared as dotted numbers.
for case in "15.0:15:0" "15.0:15.0.1:3" "15.0:9:0" "15.0:15.1:3" "14.7.1:14.10:3" "26.1:26:0"; do
  IFS=: read -r version minimum status <<<"$case"
  printf '#!%s\necho %s\n' "$BASH" "$version" >"$DS_TEST_ROOT/platform/sw_vers"
  stage0_env_set darwin "DS_STAGE0_FAST_PATH_MIN_VERSION=$minimum"
  assert_exit "$status" run_preflight --read-only --json
  assert_json - ".platform.os_version == \"$version\"" <<<"$DS_STDOUT"
done
stage0_env_write darwin
printf '#!%s\necho 15.0\n' "$BASH" >"$DS_TEST_ROOT/platform/sw_vers"
stage0_env_set darwin "DS_STAGE0_FAST_PATH_ARCHITECTURE=arm64-elsewhere"
assert_exit 3 run_preflight --read-only --json
stage0_env_write darwin
# Without the Command Line Tools the remote is not probed: /usr/bin/git
# would open the installer dialog.
ds_stub_set xcode-select installed 0
: >"$DS_FAKESSH_LOG"
assert_exit 0 run_preflight --read-only --json
assert_json - '.github_ssh_remote_accessible == false' <<<"$DS_STDOUT"
assert_eq "" "$(<"$DS_FAKESSH_LOG")" "no git call without the Command Line Tools"
# darwin user names may use capitals and dots.
assert_exit 0 env USER=Example.User "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only --json
assert_exit 1 env USER=1bad "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only --json
assert_contains "$DS_STDERR" "unsafe user name: macOS user names"
