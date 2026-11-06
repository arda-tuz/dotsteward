# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Harness extensions: the synthetic user, the shared user database behind
# DOTSTEWARD_PASSWD_CMD, the fixture lookup and the helper libraries.

# The test runs as the synthetic user, never as the host user.
assert_eq dotsteward-test "$USER"
assert_eq dotsteward-test "$LOGNAME"

# One user database serves the injection point and the stubs.
assert_eq "$DS_TEST_ROOT/platform/passwd" "$DS_PASSWD_FILE"
assert_eq "$DS_TEST_ROOT/platform/group" "$DS_GROUP_FILE"
assert_eq "dotsteward-test:x:1000:1000:dotsteward-test:$HOME:/bin/bash" "$(<"$DS_PASSWD_FILE")"
assert_eq "dotsteward-test:x:1000:" "$(<"$DS_GROUP_FILE")"
assert_eq "dotsteward-test:x:1000:1000:dotsteward-test:$HOME:/bin/bash" "$("$DOTSTEWARD_PASSWD_CMD")"
assert_eq "dotsteward-test:x:1000:1000:dotsteward-test:$HOME:/bin/bash" "$("$DOTSTEWARD_PASSWD_CMD" dotsteward-test)"

# ds_passwd_set adds or replaces an entry; the injection point follows it.
ds_passwd_set dotsteward-test /opt/zsh-path/bin/zsh
assert_eq "dotsteward-test:x:1000:1000:dotsteward-test:$HOME:/opt/zsh-path/bin/zsh" "$("$DOTSTEWARD_PASSWD_CMD")"
assert_eq /opt/zsh-path/bin/zsh "$(ds_passwd_field dotsteward-test 7)"
ds_passwd_set other-user /bin/sh 1001 /srv/other
assert_eq "other-user:x:1001:1001:other-user:/srv/other:/bin/sh" "$("$DOTSTEWARD_PASSWD_CMD" other-user)"
assert_eq 2 "$(wc -l <"$DS_PASSWD_FILE")"
assert_exit 1 ds_passwd_set
assert_exit 1 ds_passwd_set "bad:name" /bin/sh

# ds_group_add creates groups and adds members.
ds_group_add example-group dotsteward-test
ds_group_add example-group other-user
assert_contains "$(<"$DS_GROUP_FILE")" "example-group:x:1001:dotsteward-test,other-user"

# Fixture lookup.
assert_eq "$DS_REPO_ROOT/tests/fixtures/common/apt/Packages" "$(ds_fixture common/apt/Packages)"
assert_exit 1 ds_fixture common/no-such-file
assert_contains "$DS_STDERR" "no such fixture"

# git starts no background maintenance after a commit: a detached repack
# races with tests that copy or inspect the repository right after.
git init -q "$DS_TEST_ROOT/maintenance"
GIT_TRACE=1 git -C "$DS_TEST_ROOT/maintenance" commit -q --allow-empty -m "chore: empty" 2>"$DS_TEST_ROOT/trace.log"
assert_not_contains "$(<"$DS_TEST_ROOT/trace.log")" "maintenance run"
assert_not_contains "$(<"$DS_TEST_ROOT/trace.log")" "gc --auto"

# The helper libraries are separate files a test sources when it needs them.
for lib in bare-remote.sh fakessh.sh httpfix.py; do
  [[ -f $DS_REPO_ROOT/tests/lib/$lib ]] || ds_fail "missing tests/lib/$lib"
done
[[ -x $DS_REPO_ROOT/tests/lib/fakessh.sh ]] || ds_fail "fakessh.sh is not executable"
[[ -x $DS_REPO_ROOT/tests/lib/httpfix.py ]] || ds_fail "httpfix.py is not executable"

# The harness resets only the variables it owns. Other DS_* names are inputs
# a caller (for example a Nix check's setup hook) passes to the tests and
# must survive; a stale harness variable is replaced by the test's own value.
inner=$TMPDIR/inner/test-inherited-environment.sh
mkdir -p "${inner%/*}"
cat >"$inner" <<'INNER'
# shellcheck shell=bash
assert_eq kept "${DS_EXAMPLE_INPUT:-}"
assert_eq "$DS_TEST_ROOT/calls.log" "$DS_CALL_LOG"
INNER
assert_exit 0 env DS_EXAMPLE_INPUT=kept DS_CALL_LOG=/nonexistent bash "$DS_REPO_ROOT/tests/run.sh" "$inner"
assert_contains "$DS_STDOUT" "PASS"

# Host credentials never reach a test: without the SSH agent and the GitHub
# CLI tokens, a test that forgets the fake SSH transport or the gh stub fails
# instead of reaching the real remote with the user's identity.
inner=$TMPDIR/inner/test-host-credentials.sh
cat >"$inner" <<'INNER'
# shellcheck shell=bash
for name in SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GITHUB_TOKEN \
  GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR; do
  [[ -z ${!name+x} ]] || ds_fail "$name leaked into the test"
done
INNER
assert_exit 0 env SSH_AUTH_SOCK=/nonexistent SSH_AGENT_PID=1 GH_TOKEN=x \
  GITHUB_TOKEN=x GH_ENTERPRISE_TOKEN=x GITHUB_ENTERPRISE_TOKEN=x GH_HOST=x \
  GH_CONFIG_DIR=/nonexistent bash "$DS_REPO_ROOT/tests/run.sh" "$inner"
assert_contains "$DS_STDOUT" "PASS"

# ds_path_without hides one command and keeps everything else on PATH.
mkdir -p "$DS_TEST_ROOT/tools"
printf '#!%s\nexit 0\n' "$BASH" >"$DS_TEST_ROOT/tools/example-app"
printf '#!%s\nexit 0\n' "$BASH" >"$DS_TEST_ROOT/tools/example-term"
chmod 0755 "$DS_TEST_ROOT/tools/example-app" "$DS_TEST_ROOT/tools/example-term"
hidden=$(PATH=$DS_TEST_ROOT/tools:$PATH ds_path_without example-app)
if PATH=$hidden command -v example-app >/dev/null; then
  ds_fail "ds_path_without left the command on PATH"
fi
[[ $(PATH=$hidden command -v example-term) == "$DS_TEST_ROOT/path-without-example-app/0/example-term" ]] ||
  ds_fail "ds_path_without lost the other commands of the directory"
assert_eq "$PATH" "$(ds_path_without no-such-command)" "a PATH without the command stays as it is"
