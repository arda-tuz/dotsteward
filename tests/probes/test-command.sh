# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ in the wrapper scripts
# `dotsteward probes` (SPEC 6.2): --generation PATH (the generation's
# manifest and home-path/bin) or --manifest F --path-prefix DIR; the prefix
# comes first on PATH for the probe commands only. Flag refusals and
# manifest validation.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

manifest=$DS_TEST_ROOT/manifest.json
registry=(
  "$(probe example-app example-app version extract '"prefix:example-app "' \
    expected '"versions:agent_tools.example-app.version"')"
  "$(probe example-app example-app features argv '["--help"]' needles '["Usage: example-app"]')"
)

# Help and the dispatcher's command list.
assert_exit 0 run_probes --help
assert_contains "$DS_STDOUT" "Usage: dotsteward probes (--generation PATH | --manifest FILE --path-prefix DIR)"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --help
assert_contains "$DS_STDOUT" "probes"
assert_contains "$(grep -E '^ +probes ' <<<"$DS_STDOUT")" "Run the version, presence and feature probes"

# Flag refusals.
refuse() {
  local message=$1
  shift
  assert_exit 1 run_probes "$@"
  assert_eq "[dotsteward] ERROR: $message" "$DS_STDERR" "probes $*"
}
refuse "one of --generation or --manifest is required"
refuse "--generation and --manifest exclude each other" --generation "$DS_TEST_ROOT" --manifest "$manifest"
refuse "--manifest requires --path-prefix" --manifest "$manifest"
refuse "--path-prefix requires --manifest" --path-prefix "$probes_prefix"
refuse "--path-prefix requires --manifest" --generation "$DS_TEST_ROOT" --path-prefix "$probes_prefix"
refuse "--generation requires a value" --generation
refuse "--manifest requires a value" --manifest ""
refuse "unknown argument: --profile" --profile main
refuse "unknown argument: extra" extra
refuse "manifest not found: $DS_TEST_ROOT/none.json" --manifest "$DS_TEST_ROOT/none.json" \
  --path-prefix "$probes_prefix"
write_manifest "$manifest" "${registry[@]}"
refuse "path prefix is not a directory: $DS_TEST_ROOT/none" --manifest "$manifest" \
  --path-prefix "$DS_TEST_ROOT/none"
refuse "generation manifest not found: $DS_TEST_ROOT/home-path/share/dotsteward/manifest.json" \
  --generation "$DS_TEST_ROOT"

# --generation: the generation's manifest and home-path/bin; the stubs are
# on no other PATH entry.
generation=$DS_TEST_ROOT/generation
mkdir -p "$generation/home-path/share/dotsteward" "$generation/home-path/bin"
write_manifest "$generation/home-path/share/dotsteward/manifest.json" "${registry[@]}"
ln -s "$DS_REPO_ROOT/tests/lib/stubs/example-app" "$generation/home-path/bin/example-app"
assert_exit 0 run_probes --generation "$generation"
assert_eq "[dotsteward] probes passed: 1 version, 0 presence, 1 features (profile main)" "$DS_STDOUT"
assert_calls "example-app --version" "example-app --help"
# A generation reached through a symlink (the result link of a build).
ln -s "$generation" "$DS_TEST_ROOT/result"
assert_exit 0 run_probes --generation "$DS_TEST_ROOT/result"
rm -- "$generation/home-path/bin/example-app"
assert_exit 1 run_probes --generation "$generation"
assert_eq "[dotsteward] ERROR: required command not found: example-app" "$DS_STDERR"

# --manifest with --path-prefix: the prefix wins over the inherited PATH,
# for the probes only: a broken jq in the prefix does not reach the runner.
ds_use_stubs example-app
ds_stub_set example-app env "PROBE_SOURCE"
cat >"$probes_prefix/example-app" <<EOF
#!$BASH
export PROBE_SOURCE=prefix
exec "$DS_REPO_ROOT/tests/lib/stubs/example-app" "\$@"
EOF
cat >"$probes_prefix/jq" <<EOF
#!$BASH
echo "jq from the probe prefix" >&2
exit 3
EOF
chmod 0755 "$probes_prefix/example-app" "$probes_prefix/jq"
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_eq "" "$DS_STDERR"
assert_calls \
  "example-app --version" "example-app:env PROBE_SOURCE=prefix" \
  "example-app --help" "example-app:env PROBE_SOURCE=prefix"
# The probes see the prefixed PATH themselves.
ds_stub_override example-app <<'EOF'
#!/usr/bin/env bash
printf 'first=%s\n' "${PATH%%:*}"
EOF
write_manifest "$manifest" \
  "$(probe example-app example-app features needles "$(jq -cn --arg n "first=$probes_prefix" '[$n]')")"
assert_exit 0 run_manifest "$manifest"
rm -- "$probes_prefix/example-app" "$probes_prefix/jq"
rm -f -- "$DS_STUB_STATE/example-app/override"

# The instance is required: its configuration names the lock files and the
# check profile.
write_manifest "$manifest" "${registry[@]}"
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" probes --manifest "$manifest" --path-prefix "$probes_prefix"
assert_contains "$DS_STDERR" "[dotsteward] ERROR:"
assert_contains "$DS_STDERR" "workstation.toml"
# Instance discovery from the working directory works too.
assert_exit 0 bash -c 'cd "$1" && "$2" probes --manifest "$3" --path-prefix "$4"' \
  _ "$probes_instance" "$DS_REPO_ROOT/cli/dotsteward" "$manifest" "$probes_prefix"

# Manifest validation: one line per problem, nothing runs.
invalid() {
  local json=$1
  shift
  printf '%s\n' "$json" >"$manifest"
  : >"$DS_CALL_LOG"
  assert_exit 1 run_manifest "$manifest"
  local expected="" line
  for line in "$@"; do
    expected+=${expected:+$'\n'}"[dotsteward] ERROR: invalid manifest $manifest: $line"
  done
  assert_eq "$expected" "$DS_STDERR" "$json"
  assert_calls
}
invalid '{ not json' "not valid JSON"
invalid '[]' "not a JSON object"
invalid '{"platform": "linux"}' "probes is not a list"
invalid '{"probes": {}}' "probes is not a list"
invalid '{"probes": [], "components": {}}' "components is not a list"
invalid '{"probes": [], "components": [{"profiles": null}]}' "component 1: name is not a non-empty string"
invalid '{"probes": [7]}' "probe 1: not an object"
invalid '{"probes": [{"kind": "presence"}]}' "probe 1: command is not a non-empty string"
invalid '{"probes": [{"command": "", "kind": "presence"}]}' "probe 1: command is not a non-empty string"
invalid '{"probes": [{"command": "example-app", "kind": "speed"}]}' \
  "probe 1 (example-app): kind is not version, presence or features"
invalid '{"probes": [{"command": "example-app", "kind": "version"}]}' \
  "probe 1 (example-app): a version probe needs expected"
invalid '{"probes": [{"command": "example-app", "kind": "version", "expected": "1.2.3"}]}' \
  "probe 1 (example-app): expected is not versions:<path> or skills:<path>"
invalid '{"probes": [{"command": "example-app", "kind": "version", "expected": "versions:a", "extract": "last-line"}]}' \
  "probe 1 (example-app): extract is not first-line, printf-vd, field:<label>, prefix:<text> or regex:<re>"
invalid '{"probes": [{"command": "example-app", "kind": "version", "expected": "versions:a", "extract": "regex:("}]}' \
  "probe 1 (example-app): invalid regular expression in extract: ("
invalid '{"probes": [{"command": "example-app", "kind": "presence", "argv": "--version"}]}' \
  "probe 1 (example-app): argv is not a list of strings"
invalid '{"probes": [{"command": "example-app", "kind": "presence", "env": {"A B": "1"}}]}' \
  "probe 1 (example-app): env is not a table of variable names to strings"
invalid '{"probes": [{"command": "example-app", "kind": "presence", "env": {"A": 1}}]}' \
  "probe 1 (example-app): env is not a table of variable names to strings"
invalid '{"probes": [{"command": "example-app", "kind": "features", "needles": [1]}]}' \
  "probe 1 (example-app): needles is not a list of strings"
invalid '{"probes": [{"command": "example-app", "kind": "presence", "profiles": "main"}]}' \
  "probe 1 (example-app): profiles is not null or a list of strings"
invalid '{"probes": [{"command": "example-app", "kind": "presence", "component": 3}]}' \
  "probe 1 (example-app): component is not a string"
invalid '{"probes": [{"command": "example-app", "kind": "presence", "argv": ["a\u0000b"]}]}' \
  "probe 1 (example-app): a value contains a NUL character"
invalid '{"probes": [{"command": "example-app", "kind": "speed"}, {"command": "example-term", "kind": "version"}]}' \
  "probe 1 (example-app): kind is not version, presence or features" \
  "probe 2 (example-term): a version probe needs expected"
