# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Scoping: the command runs the probes of the instance's check profile
# (profiles.check, the profile the gate builds). A probe runs when its
# component is scoped to that profile (profiles null or listing it) and
# supports the manifest's platform, and the probe's own profiles allow it.
# Skipped probes are not even required (phase 1).
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app example-term claude
manifest=$DS_TEST_ROOT/manifest.json
missing_command=dotsteward-test-missing-$RANDOM

PROBES_COMPONENTS=$(jq -cn \
  --argjson a "$(component example-term profiles '["work"]')" \
  --argjson b "$(component example-app)" \
  --argjson c "$(component claude-code platforms '["darwin"]')" \
  '[$a, $b, $c]')
write_manifest "$manifest" \
  "$(probe example-term example-term presence)" \
  "$(probe example-app example-app presence profiles '["work"]')" \
  "$(probe example-app example-app presence argv '["--help"]' profiles '["main", "work"]')" \
  "$(probe example-app example-app presence argv '["--main-only"]' profiles '["main"]')" \
  "$(probe claude-code claude presence)" \
  "$(probe claude-code "$missing_command" presence)"

# profiles.check defaults to the default profile, the first name: main.
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 2 presence, 0 features (profile main)" "$DS_STDOUT"
assert_calls "example-app --help" "example-app --main-only"

# profiles.check = "work".
python3 - "$probes_instance/workstation.toml" <<'EOF'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('names = ["main", "work"]', 'names = ["main", "work"]\ncheck = "work"')
open(path, "w", encoding="utf-8").write(text)
EOF
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 3 presence, 0 features (profile work)" "$DS_STDOUT"
assert_calls "example-term --version" "example-app --version" "example-app --help"

# The platform comes from the manifest, not from the running system.
jq '.platform = "darwin"' "$manifest" >"$manifest.tmp"
mv -- "$manifest.tmp" "$manifest"
: >"$DS_CALL_LOG"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: required command not found: $missing_command" "$DS_STDERR"
assert_calls

# A probe of a component the manifest does not list is an error.
write_manifest "$manifest" "$(probe codex example-app presence)"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: invalid manifest $manifest: probe 1 (example-app): component codex is not in the manifest components" \
  "$DS_STDERR"

# Without a components list (a hand-written manifest) nothing is scoped by
# component and the declaration order holds.
jq -n '{schema_version: 1, platform: "linux", probes: [
  {component: "b", command: "example-term", kind: "presence"},
  {component: "a", command: "example-app", kind: "presence", profiles: ["other"]},
  {component: "a", command: "example-app", kind: "presence", argv: ["--help"]}
]}' >"$manifest"
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 2 presence, 0 features (profile work)" "$DS_STDOUT"
assert_calls "example-term --version" "example-app --help"
