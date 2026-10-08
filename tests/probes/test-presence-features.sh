# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ in the override scripts
# Presence probes fail on a non-zero exit; feature probes must exit 0 and
# their combined standard output and error must contain every needle as a
# fixed string. Every probe runs with its own environment, its
# argv kept word for word, and an empty standard input.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app example-term pi
manifest=$DS_TEST_ROOT/manifest.json

# Presence: success, its output is not shown.
write_manifest "$manifest" "$(probe example-app example-app presence)"
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 1 presence, 0 features (profile main)" "$DS_STDOUT"
assert_calls "example-app --version"

# Presence: a non-zero exit fails, with any argv.
write_manifest "$manifest" "$(probe example-app example-app presence argv '["self-test", "--quick"]')"
ds_stub_route example-app 'self-test --quick' --exit 2 --stderr "self-test failed"
assert_exit 1 run_manifest "$manifest"
assert_eq "self-test failed"$'\n'"[dotsteward] ERROR: example-app presence probe failed: example-app self-test --quick exited with status 2" \
  "$DS_STDERR"
ds_stub_clear_routes example-app

# Features: needles in the help text, matched as fixed strings.
ds_stub_set example-term help $'Usage: example-term mv [<id>...]\n  --offline   work offline\n  --a.b'
write_manifest "$manifest" \
  "$(probe example-term example-term features argv '["--help"]' needles '["[<id>...]", "--offline", "--a.b"]')"
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 0 version, 0 presence, 1 features (profile main)" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
write_manifest "$manifest" \
  "$(probe example-term example-term features argv '["--help"]' needles '["--offline", "--axb", "--missing"]')"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: example-term lacks --axb" "$DS_STDERR"
write_manifest "$manifest" \
  "$(probe example-term example-term features argv '["--help"]' needles '["[<id>]"]')"
assert_exit 1 run_manifest "$manifest"
assert_eq "[dotsteward] ERROR: example-term lacks [<id>]" "$DS_STDERR"

# Features: standard error counts.
ds_stub_route example-term '--help' --stdout "" --stderr "  --offline"
write_manifest "$manifest" \
  "$(probe example-term example-term features argv '["--help"]' needles '["--offline"]')"
assert_exit 0 run_manifest "$manifest"
assert_eq "" "$DS_STDERR"
ds_stub_clear_routes example-term

# Features: the command must succeed; its output is shown before the error.
ds_stub_route example-term '--help' --exit 4 --stdout "  --offline" --stderr "help failed"
assert_exit 1 run_manifest "$manifest"
assert_contains "$DS_STDERR" "help failed"
assert_eq "[dotsteward] ERROR: example-term features probe failed: example-term --help exited with status 4" \
  "${DS_STDERR##*$'\n'}"
ds_stub_clear_routes example-term

# Features without needles only need a zero exit.
write_manifest "$manifest" "$(probe example-term example-term features argv '["--help"]')"
assert_exit 0 run_manifest "$manifest"

# The environment applies to every kind; argv words stay intact.
write_manifest "$manifest" \
  "$(probe opencode-pi pi presence)" \
  "$(probe opencode-pi pi presence env '{"PI_OFFLINE": "1", "PI_CODING_AGENT_DIR": "a dir/with $(no) expansion"}')" \
  "$(probe opencode-pi pi features env '{"PI_OFFLINE": "1"}' argv '["auth", "check", "--help"]' \
    needles '["--json", "--no-refresh"]')"
: >"$DS_CALL_LOG"
assert_exit 0 run_manifest "$manifest"
assert_calls \
  "pi --version" \
  "pi:env -PI_OFFLINE -PI_CODING_AGENT_DIR" \
  "pi --version" \
  "pi:env PI_OFFLINE=1 PI_CODING_AGENT_DIR=a\\ dir/with\\ \\\$\\(no\\)\\ expansion" \
  "pi auth check --help" \
  "pi:env PI_OFFLINE=1 -PI_CODING_AGENT_DIR"

ds_stub_override example-app <<'EOF'
#!/usr/bin/env bash
printf 'args=%s\n' "$#"
printf 'arg=[%s]\n' "$@"
EOF
write_manifest "$manifest" \
  "$(probe example-app example-app features argv '["two words", "", "*", "$HOME"]' \
    needles '["args=4", "arg=[two words]", "arg=[]", "arg=[*]", "arg=[$HOME]"]')"
assert_exit 0 run_manifest "$manifest"

# Probes never read the caller's standard input.
ds_stub_override example-app <<'EOF'
#!/usr/bin/env bash
if IFS= read -r line; then
  printf 'stdin=%s\n' "$line"
else
  printf 'no stdin\n'
fi
EOF
write_manifest "$manifest" "$(probe example-app example-app features needles '["no stdin"]')"
assert_exit 0 bash -c '"$1" --instance "$2" probes --manifest "$3" --path-prefix "$4" <<<"caller input"' \
  _ "$DS_REPO_ROOT/cli/dotsteward" "$probes_instance" "$manifest" "$probes_prefix"
