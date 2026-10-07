# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# tests/run.sh: discovery, exclusions, --only, reporting, isolation and
# cleanup, exercised on a scratch copy of the runner.
# shellcheck source=tests/skeleton/helpers.sh
source "$DS_REPO_ROOT/tests/skeleton/helpers.sh"

fw=$DS_TEST_ROOT/fw
copy_framework "$fw"
mkdir -p "$fw/tests/alpha/fixtures" "$fw/tests/alpha/deep" "$fw/tests/vm" \
  "$fw/tests/ci" "$fw/tests/host" "$fw/tests/channels" "$fw/tests/empty"
printf 'assert_eq 1 1\n' >"$fw/tests/alpha/test-pass.sh"
printf 'assert_eq 1 1\n' >"$fw/tests/alpha/deep/test-deep.sh"
printf 'assert_eq 1 2 "numbers differ"\n' >"$fw/tests/alpha/test-fail.sh"
printf 'echo before\nfalse\necho after\n' >"$fw/tests/alpha/test-error.sh"
printf 'exit 1\n' >"$fw/tests/alpha/helper.sh"
printf 'exit 1\n' >"$fw/tests/alpha/fixtures/test-fixture.sh"
for dir in vm ci host channels; do
  printf 'exit 1\n' >"$fw/tests/$dir/test-$dir.sh"
done

# Default run: everything under tests/ except the explicit-only directories
# and fixtures, sorted, with one line per file and a summary.
assert_exit 1 bash "$fw/tests/run.sh"
expected_lines="PASS tests/alpha/deep/test-deep.sh
FAIL tests/alpha/test-error.sh: error: command failed (exit 1) at $fw/tests/alpha/test-error.sh:2: false
FAIL tests/alpha/test-fail.sh: assertion failed: numbers differ: expected [1], got [2]
PASS tests/alpha/test-pass.sh
2 passed, 2 failed"
assert_eq "$expected_lines" "$(grep -v '^    ' <<<"$DS_STDOUT")"
# The output of a failing test follows its FAIL line, indented.
assert_contains "$DS_STDOUT" "test-error.sh:2: false
    before
    error: command failed"
assert_not_contains "$DS_STDOUT" "after"

# The working directory does not matter.
(cd / && bash "$fw/tests/run.sh" --only pass) >out.txt
assert_eq "PASS tests/alpha/test-pass.sh
1 passed, 0 failed" "$(<out.txt)"

# Explicit paths: a directory, a single file, and an explicit-only directory.
assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/alpha/deep" "$fw/tests/alpha/test-pass.sh"
assert_eq "PASS tests/alpha/deep/test-deep.sh
PASS tests/alpha/test-pass.sh
2 passed, 0 failed" "$DS_STDOUT"
assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/vm"
assert_contains "$DS_STDOUT" "FAIL tests/vm/test-vm.sh: exit 1"
# Duplicates collapse.
assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/alpha/deep" "$fw/tests/alpha/deep/test-deep.sh"
assert_eq "PASS tests/alpha/deep/test-deep.sh
1 passed, 0 failed" "$DS_STDOUT"
# --only takes a glob, in both spellings.
assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/alpha" --only='alpha/*/test-*'
assert_eq "PASS tests/alpha/deep/test-deep.sh
1 passed, 0 failed" "$DS_STDOUT"

# Usage errors.
assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/missing"
assert_contains "$DS_STDERR" "no such test path"
assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/empty"
assert_contains "$DS_STDERR" "no tests found"
assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/alpha" --only nothing-matches
assert_contains "$DS_STDERR" "no tests found"
assert_exit 1 bash "$fw/tests/run.sh" --only
assert_exit 1 bash "$fw/tests/run.sh" --bogus
assert_exit 0 bash "$fw/tests/run.sh" --help
assert_contains "$DS_STDOUT" "Usage: tests/run.sh [PATH...] [--only PATTERN]"

# A hung test is stopped by the per-file timeout.
printf 'sleep 30\n' >"$fw/tests/empty/test-slow.sh"
DS_TEST_TIMEOUT=1 assert_exit 1 bash "$fw/tests/run.sh" "$fw/tests/empty"
assert_contains "$DS_STDOUT" "FAIL tests/empty/test-slow.sh: timed out after 1s"
rm "$fw/tests/empty/test-slow.sh"

# Isolation: host variables are removed, deferred commands run in reverse
# order, and the temporary root is gone after the test.
probe=$DS_TEST_ROOT/probe
mkdir -p "$fw/tests/isolation"
cat >"$fw/tests/isolation/test-isolation.sh" <<'EOF'
assert_eq "" "$(compgen -v XDG_ || true)"
assert_eq "" "$(compgen -v DOTFILES_ || true)"
assert_eq "DOTSTEWARD_CPU_COUNT DOTSTEWARD_ETC_SHELLS DOTSTEWARD_MEMORY_MIB DOTSTEWARD_OS_RELEASE DOTSTEWARD_PASSWD_CMD DOTSTEWARD_STATE_ROOT DOTSTEWARD_SW_VERS" \
  "$(compgen -v DOTSTEWARD_ | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM" "$(compgen -v GIT_ | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
printf '%s\n' "$DS_TEST_ROOT" >"$SKELETON_PROBE/root"
ds_defer sh -c 'echo first >>"$1"' sh "$SKELETON_PROBE/deferred"
ds_defer sh -c 'echo second >>"$1"' sh "$SKELETON_PROBE/deferred"
mkdir -p readonly/inner
touch readonly/inner/file
chmod 0500 readonly/inner readonly
EOF
mkdir -p "$probe"
SKELETON_PROBE=$probe XDG_CONFIG_HOME=/nonexistent DOTFILES_ROOT=/nonexistent \
  DOTSTEWARD_INSTANCE=/nonexistent GIT_DIR=/nonexistent GIT_AUTHOR_NAME=someone \
  assert_exit 0 bash "$fw/tests/run.sh" "$fw/tests/isolation"
assert_eq "PASS tests/isolation/test-isolation.sh
1 passed, 0 failed" "$DS_STDOUT"
assert_eq "second
first" "$(<"$probe/deferred")"
inner_root=$(<"$probe/root")
assert_contains "$inner_root" "$TMPDIR/dotsteward-test."
[[ ! -e $inner_root ]] || ds_fail "temporary root survived: $inner_root"

# The runner itself leaves nothing behind in TMPDIR.
assert_eq "" "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*')"
