# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The generic stub mechanism: opt-in PATH, the exact stub set, call and
# environment records, state values, canned routes and overrides.

stub_dir=$DS_REPO_ROOT/tests/lib/stubs

# Exactly the stub names of the spec exist, all executable; nothing else
# (no helper file) lives in the stub directory.
expected_names="apt-cache apt-get chsh claude code codex curl dpkg dpkg-deb dpkg-query dscl example-app example-term getent gh herdr id nix opencode pi sudo sw_vers xcode-select"
actual_names=$(cd "$stub_dir" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
assert_eq "$expected_names" "${actual_names% }" "stub names"
for name in $expected_names; do
  [[ -f $stub_dir/$name && -x $stub_dir/$name ]] || ds_fail "stub $name is not an executable file"
done

# The state root and the system root exist from the start.
assert_eq "$DS_TEST_ROOT/stubs" "$DS_STUB_STATE"
assert_eq "$DS_TEST_ROOT/system" "$DS_SYSTEM_ROOT"
for dir in etc etc/default etc/apt/sources.list.d etc/apt/keyrings opt usr/local/bin usr/share var/lib Applications Library; do
  [[ -d $DS_SYSTEM_ROOT/$dir ]] || ds_fail "system root lacks $dir"
done

# Stubs are never on PATH unless a test asks for them.
original_path=$PATH
[[ $(command -v gh || true) != "$DS_TEST_ROOT"/* ]] || ds_fail "a stub is on PATH by default"
assert_exit 1 ds_use_stubs
assert_contains "$DS_STDERR" "usage"
assert_exit 1 ds_use_stubs no-such-stub
assert_contains "$DS_STDERR" "unknown stub: no-such-stub"

ds_use_stubs gh example-app
assert_eq "$DS_TEST_ROOT/bin:$original_path" "$PATH"
assert_eq "$DS_TEST_ROOT/bin/gh" "$(command -v gh)"
assert_eq "$DS_TEST_ROOT/bin/example-app" "$(command -v example-app)"
[[ ! -e $DS_TEST_ROOT/bin/nix ]] || ds_fail "nix enabled without being asked for"
# A second call adds stubs without prepending the directory twice.
ds_use_stubs example-term
assert_eq "$DS_TEST_ROOT/bin:$original_path" "$PATH"
ds_use_stubs --all
for name in $expected_names; do
  assert_eq "$DS_TEST_ROOT/bin/$name" "$(command -v "$name")" "$name on PATH"
done

# Every call appends one line, quoted like ds_record_call.
example-app --version >/dev/null
example-app run "two words" ''
assert_calls "example-app --version" "example-app run two\\ words ''"
assert_eq "example-app --version
example-app run two\\ words ''" "$(ds_calls_of example-app)"
assert_eq "" "$(ds_calls_of example-term)"
assert_eq 2 "$(ds_call_count example-app)"
assert_eq 1 "$(ds_call_count example-app 'run *')"
assert_eq 0 "$(ds_call_count example-app 'nope*')"
assert_call_count 2 example-app
assert_call_count 1 example-app 'run *'
assert_exit 1 assert_call_count 3 example-app
assert_contains "$DS_STDERR" "expected 3 calls of example-app"

# Selected environment: one "NAME:env" line after the call line, values
# quoted, unset variables as -NAME. Tests choose the variables per stub.
: >"$DS_CALL_LOG"
ds_stub_set example-term env "ALPHA_VALUE BETA_VALUE"
ALPHA_VALUE="a b" example-term --version >/dev/null
assert_calls "example-term --version" "example-term:env ALPHA_VALUE=a\\ b -BETA_VALUE"
assert_eq "example-term --version" "$(ds_calls_of example-term)"
assert_eq "example-term:env ALPHA_VALUE=a\\ b -BETA_VALUE" "$(ds_env_of example-term)"
assert_eq 1 "$(ds_call_count example-term)"

# State values: ds_stub_set writes, stubs read; "-" reads standard input.
ds_stub_set example-app version "example-app 9.9.9"
assert_eq "example-app 9.9.9" "$(example-app --version)"
printf 'line one\nline two\n' | ds_stub_set example-app help -
assert_eq "line one
line two" "$(example-app --help)"
assert_exit 1 ds_stub_set example-app
assert_exit 1 ds_stub_set no-such-stub version 1

# Routes: glob over the space-joined arguments, first match wins, with exit
# status, stdout, stderr, a use limit and a delay.
: >"$DS_CALL_LOG"
ds_stub_route example-app 'deploy *' --exit 3 --stdout "deployed" --stderr "warning: slow"
ds_stub_route example-app 'deploy prod' --stdout "never reached"
assert_exit 3 example-app deploy prod
assert_eq deployed "$DS_STDOUT"
assert_eq "warning: slow" "$DS_STDERR"
printf '{"ok": true}\n' >"$TMPDIR/canned.json"
ds_stub_route example-term 'status' --stdout-file "$TMPDIR/canned.json" --times 1
assert_exit 0 example-term status
assert_eq '{"ok": true}' "$DS_STDOUT"
# After its single use the route is gone and the built-in behaviour returns.
assert_exit 0 example-term status
assert_eq "" "$DS_STDOUT"
assert_call_count 2 example-term status
ds_stub_route example-term 'slow' --sleep 1
start=$SECONDS
example-term slow
((SECONDS - start >= 1)) || ds_fail "route delay was not applied"
assert_exit 1 ds_stub_route example-term
assert_exit 1 ds_stub_route example-term 'x' --exit
assert_exit 1 ds_stub_route example-term 'x' --bogus
assert_exit 1 ds_stub_route example-term 'x' --stdout-file "$TMPDIR/missing"

# Overrides replace the built-in behaviour after the call is recorded.
: >"$DS_CALL_LOG"
ds_stub_override example-app <<'EOF'
#!/usr/bin/env bash
printf 'override:%s\n' "$*"
exit 7
EOF
assert_exit 7 example-app one two
assert_eq "override:one two" "$DS_STDOUT"
assert_calls "example-app one two"

# A stub refuses to run outside the harness instead of writing elsewhere.
assert_exit 1 env -u DS_CALL_LOG "$stub_dir/example-term" --version
assert_contains "$DS_STDERR" "DS_CALL_LOG"
