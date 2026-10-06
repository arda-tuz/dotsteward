# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Expected values (SPEC 8.2): versions:<path> reads the instance's versions
# lock (pins.versions_lock), skills:<path> its skills lock mirror
# (skills.lock); the path is dotted, its segments are literal keys (dashes
# included). A missing, empty or non-scalar value is an error naming the lock
# file and the path.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app pi
manifest=$DS_TEST_ROOT/manifest.json

# check_expected EXPECTED VERSION_OUTPUT [MESSAGE]: an example-app version
# probe with EXPECTED; without MESSAGE it must pass, otherwise fail with it.
check_expected() {
  local expected=$1 output=$2 message=${3:-}
  write_manifest "$manifest" \
    "$(probe example-app example-app version expected "$(jq -cn --arg e "$expected" '$e')")"
  ds_stub_set example-app version "$output"
  if [[ -z $message ]]; then
    assert_exit 0 run_manifest "$manifest"
    assert_eq "[dotsteward] probes passed: 1 version, 0 presence, 0 features (profile main)" "$DS_STDOUT" \
      "$expected"
  else
    assert_exit 1 run_manifest "$manifest"
    assert_eq "[dotsteward] ERROR: $message" "$DS_STDERR" "$expected"
  fi
}

check_expected versions:agent_tools.example-app.version 1.2.3
check_expected versions:agent_tools.example-term.version 1.2.3 \
  "example-app version mismatch: expected 0.9.0, found 1.2.3"
check_expected skills:npm_tools.example-app 1.2.3
check_expected versions:nix_packages.table.nested.value 1.0
# A number is compared in its JSON text.
check_expected versions:nix_packages.count 7

check_expected versions:agent_tools.missing.version 1.2.3 \
  "cannot read the expected version of example-app: versions.lock.json lacks agent_tools.missing.version"
check_expected skills:nix_tools.example-app 1.2.3 \
  "cannot read the expected version of example-app: agent/skills.lock.json lacks nix_tools.example-app"
check_expected versions:nix_packages.count.deeper 1.2.3 \
  "cannot read the expected version of example-app: versions.lock.json lacks nix_packages.count.deeper"
check_expected versions:nix_packages.table 1.2.3 \
  "cannot read the expected version of example-app: versions.lock.json has no version string at nix_packages.table"
check_expected versions:nix_packages.empty 1.2.3 \
  "cannot read the expected version of example-app: versions.lock.json has no version string at nix_packages.empty"
check_expected versions:schema_version.x.. 1.2.3 \
  "cannot read the expected version of example-app: versions.lock.json lacks schema_version.x.."

# The probe's environment applies (here the skills mirror pins the version).
write_manifest "$manifest" \
  "$(probe opencode-pi pi version env '{"PI_OFFLINE": "1"}' expected '"skills:nix_tools.pi"')"
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_calls "pi --version" "pi:env PI_OFFLINE=1 -PI_CODING_AGENT_DIR"

# The lock paths come from the instance configuration.
mkdir -p "$probes_instance/locks"
mv "$probes_instance/versions.lock.json" "$probes_instance/locks/pins.json"
cat >>"$probes_instance/workstation.toml" <<'EOF'

[pins]
versions_lock = "locks/pins.json"
EOF
check_expected versions:agent_tools.example-app.version 1.2.3
rm -- "$probes_instance/locks/pins.json"
check_expected versions:agent_tools.example-app.version 1.2.3 \
  "cannot read the expected version of example-app: lock file not found: $probes_instance/locks/pins.json"
printf '{ not json\n' >"$probes_instance/locks/pins.json"
check_expected versions:agent_tools.example-app.version 1.2.3 \
  "cannot read the expected version of example-app: invalid JSON in $probes_instance/locks/pins.json"

# A lock file is read only when a probe needs it.
rm -- "$probes_instance/locks/pins.json" "$probes_instance/agent/skills.lock.json"
write_manifest "$manifest" "$(probe example-app example-app presence)"
assert_exit 0 run_manifest "$manifest"
