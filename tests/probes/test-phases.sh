# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The four runner phases: every probe command is required first,
# then all version probes, all presence probes and all feature probes; within
# a phase the order is the manifest's component order ([components] order),
# then declaration order. The first failure stops the run.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app example-term claude
manifest=$DS_TEST_ROOT/manifest.json

# Declared out of component order and with the kinds mixed.
registry=(
  "$(probe claude-code claude features argv '["--help"]' needles '["Usage: claude"]')"
  "$(probe example-app example-app presence)"
  "$(probe example-app example-app version extract '"prefix:example-app "' \
    expected '"versions:agent_tools.example-app.version"')"
  "$(probe example-term example-term features argv '["--help"]' needles '["Usage: example-term"]')"
  "$(probe example-term example-term version extract '"prefix:example-term "' \
    expected '"versions:agent_tools.example-term.version"')"
  "$(probe claude-code claude version extract '"regex:^([0-9.]+) "' \
    expected '"versions:nix_packages.claude.expected"')"
  "$(probe example-term example-term presence argv '["--help"]')"
)
write_manifest "$manifest" "${registry[@]}"

assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 3 version, 2 presence, 2 features (profile main)" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_calls \
  "example-term --version" \
  "example-app --version" \
  "claude --version" \
  "example-term --help" \
  "example-app --version" \
  "example-term --help" \
  "claude --help"

# Phase 1: a missing command fails before any probe runs, even when its
# probe comes last.
missing_command=dotsteward-test-missing-$RANDOM
write_manifest "$manifest" "${registry[@]}" \
  "$(probe claude-code "$missing_command" features argv '["--help"]' needles '["x"]')"
: >"$DS_CALL_LOG"
assert_exit 1 run_manifest "$manifest"
assert_eq "" "$DS_STDOUT"
assert_eq "[dotsteward] ERROR: required command not found: $missing_command" "$DS_STDERR"
assert_calls

# Phase 2: a version mismatch stops the run before presence and features.
write_manifest "$manifest" "${registry[@]}"
ds_stub_set example-app version "example-app 1.2.4"
: >"$DS_CALL_LOG"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: example-app version mismatch: expected 1.2.3, found 1.2.4" "$DS_STDERR"
assert_calls "example-term --version" "example-app --version"
ds_stub_set example-app version "example-app 1.2.3"

# Phase 3: a failing presence probe stops the run before the features.
ds_stub_route example-term '--help' --exit 5 --times 1
: >"$DS_CALL_LOG"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: example-term presence probe failed: example-term --help exited with status 5" \
  "$DS_STDERR"
assert_calls \
  "example-term --version" \
  "example-app --version" \
  "claude --version" \
  "example-term --help"

# Phase 4: the first missing needle stops the run.
ds_stub_set example-term help "Usage: elsewhere"
: >"$DS_CALL_LOG"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: example-term lacks Usage: example-term" "$DS_STDERR"
assert_calls \
  "example-term --version" \
  "example-app --version" \
  "claude --version" \
  "example-term --help" \
  "example-app --version" \
  "example-term --help"

# An empty registry passes.
write_manifest "$manifest"
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 0 presence, 0 features (profile main)" "$DS_STDOUT"
assert_calls
