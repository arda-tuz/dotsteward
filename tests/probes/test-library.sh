# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ in the library shell scripts
# The library interface other commands use (agents check, e2e):
#   probes_select MANIFEST [PROFILE]      the active probes in run order
#   run_cli_probes MANIFEST [PROFILE] [PATH_PREFIX]
# An empty PROFILE scopes nothing by profile. DS_PROBES_KEEP_GOING=1 records
# every failure (code, command, message) instead of stopping at the first,
# and the runner then returns 1.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app example-term claude
manifest=$DS_TEST_ROOT/manifest.json
missing_command=dotsteward-test-missing-$RANDOM

PROBES_COMPONENTS=$(jq -cn \
  --argjson a "$(component example-term profiles '["work"]')" \
  --argjson b "$(component example-app)" \
  --argjson c "$(component claude-code)" \
  '[$a, $b, $c]')
write_manifest "$manifest" \
  "$(probe claude-code claude features argv '["--help"]' needles '["Usage: claude", "--absent", "--gone"]')" \
  "$(probe claude-code "$missing_command" version expected '"versions:x"')" \
  "$(probe claude-code "$missing_command" presence)" \
  "$(probe example-app example-app version expected '"versions:agent_tools.example-app.version"' \
    extract '"prefix:example-app "')" \
  "$(probe example-app example-app version expected '"versions:agent_tools.absent"')" \
  "$(probe example-app example-app presence argv '["--main"]' profiles '["main"]')" \
  "$(probe example-term example-term version expected '"versions:agent_tools.example-term.version"')" \
  "$(probe example-term example-term features argv '["--help"]' needles '["Usage: example-term"]')"

# probes_select: phases, then component order, then declaration order.
listing='"\(.kind) \(.component) \(.command) \(.argv | join(" "))"'
assert_exit 0 in_probes_shell 'probes_select "$1" "" | jq -r "$2"' "$manifest" "$listing"
assert_eq "version example-term example-term --version
version example-app example-app --version
version example-app example-app --version
version claude-code $missing_command --version
presence example-app example-app --main
presence claude-code $missing_command --version
features example-term example-term --help
features claude-code claude --help" "$DS_STDOUT"
assert_exit 0 in_probes_shell 'probes_select "$1" main | jq -r "$2"' "$manifest" "$listing"
assert_eq "version example-app example-app --version
version example-app example-app --version
version claude-code $missing_command --version
presence example-app example-app --main
presence claude-code $missing_command --version
features claude-code claude --help" "$DS_STDOUT"
# Every entry carries its defaults and its manifest position.
assert_exit 0 in_probes_shell 'probes_select "$1" main | head -n 1' "$manifest"
assert_json - '. == {component: "example-app", command: "example-app", kind: "version",
  argv: ["--version"], env: {}, extract: "prefix:example-app ",
  expected: "versions:agent_tools.example-app.version", needles: [], profiles: null, index: 3}' \
  <<<"$DS_STDOUT"
jq -n '{probes: [{command: "example-app", kind: "presence"}]}' >"$DS_TEST_ROOT/bare.json"
assert_exit 0 in_probes_shell 'probes_select "$1" main' "$DS_TEST_ROOT/bare.json"
assert_json - '. == {component: null, command: "example-app", kind: "presence", argv: ["--version"],
  env: {}, extract: "first-line", expected: null, needles: [], profiles: null, index: 0}' <<<"$DS_STDOUT"

# Fail-fast by default, like the command.
assert_exit 1 in_probes_shell 'run_cli_probes "$1" main' "$manifest"
assert_eq "[dotsteward] ERROR: required command not found: $missing_command" "$DS_STDERR"

# Keep-going: every failure is recorded, probes of a missing command are
# skipped, the others still run; nothing is printed.
: >"$DS_CALL_LOG"
report='
  status=0
  DS_PROBES_KEEP_GOING=1 run_cli_probes "$1" main || status=$?
  printf "status=%s\n" "$status"
  for i in "${!DS_PROBES_FAILURES[@]}"; do
    printf "%s|%s|%s\n" "${DS_PROBES_FAILURE_CODES[$i]}" "${DS_PROBES_FAILURE_COMMANDS[$i]}" \
      "${DS_PROBES_FAILURES[$i]}"
  done'
assert_exit 0 in_probes_shell "$report" "$manifest"
assert_eq "" "$DS_STDERR"
assert_eq "status=1
missing-command|$missing_command|required command not found: $missing_command
expected-unreadable|example-app|cannot read the expected version of example-app: versions.lock.json lacks agent_tools.absent
needle-missing|claude|claude lacks --absent
needle-missing|claude|claude lacks --gone" "$DS_STDOUT"
assert_calls "example-app --version" "example-app --main" "claude --help"

ds_stub_set example-app version "example-app 0.0.1"
ds_stub_route example-app '--main' --exit 9
ds_stub_route claude '--help' --exit 4 --stdout "Usage: claude"
assert_exit 0 in_probes_shell "$report" "$manifest"
assert_eq "status=1
missing-command|$missing_command|required command not found: $missing_command
version-mismatch|example-app|example-app version mismatch: expected 1.2.3, found 0.0.1
expected-unreadable|example-app|cannot read the expected version of example-app: versions.lock.json lacks agent_tools.absent
presence-failed|example-app|example-app presence probe failed: example-app --main exited with status 9
features-failed|claude|claude features probe failed: claude --help exited with status 4" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"

# A passing keep-going run returns 0 with empty failure lists; the PATH
# prefix applies to the probes.
mkdir -p "$DS_TEST_ROOT/only"
ln -s "$DS_REPO_ROOT/tests/lib/stubs/claude" "$DS_TEST_ROOT/only/claude"
write_manifest "$DS_TEST_ROOT/claude.json" "$(probe claude-code claude presence)"
assert_exit 0 in_probes_shell '
  PATH=${PATH//$DS_TEST_ROOT\/bin:/}
  DS_PROBES_KEEP_GOING=1 run_cli_probes "$1" main "$2"
  printf "%s\n" "${#DS_PROBES_FAILURES[@]}"' "$DS_TEST_ROOT/claude.json" "$DS_TEST_ROOT/only"
assert_eq 0 "$DS_STDOUT"
