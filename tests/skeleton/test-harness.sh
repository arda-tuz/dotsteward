# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The harness gives every test an isolated, deterministic environment.

# Layout of the temporary root.
assert_eq "$DS_TEST_ROOT/home" "$HOME"
assert_eq "$DS_TEST_ROOT/tmp" "$TMPDIR"
assert_eq "$DS_TEST_ROOT/work" "$PWD"
assert_eq "$DS_TEST_ROOT/state" "$DOTSTEWARD_STATE_ROOT"
assert_eq "$DS_TEST_ROOT/calls.log" "$DS_CALL_LOG"
[[ -d $HOME && -d $TMPDIR ]] || ds_fail "HOME or TMPDIR missing"
assert_contains "$(basename "$DS_TEST_ROOT")" "dotsteward-test."
assert_eq "$DS_REPO_ROOT/tests/skeleton/test-harness.sh" "$DS_TEST_FILE"
[[ -f $DS_REPO_ROOT/tests/lib/harness.sh ]] || ds_fail "DS_REPO_ROOT is wrong: $DS_REPO_ROOT"

# Strict mode is on.
[[ $- == *e* && $- == *u* && $- == *E* ]] || ds_fail "errexit, nounset or errtrace is off: $-"
[[ -o pipefail ]] || ds_fail "pipefail is off"

# Time zone and locale.
assert_eq UTC "$TZ"
assert_eq +0000 "$(date +%z)"
assert_eq C "$LC_ALL"

# Git sees only the temporary global config and the test identity.
assert_eq 1 "$GIT_CONFIG_NOSYSTEM"
assert_eq "$DS_TEST_ROOT/gitconfig" "$GIT_CONFIG_GLOBAL"
assert_eq dotsteward-test "$(git config --global user.name)"
assert_eq dotsteward-test@example.invalid "$(git config --global user.email)"
git init -q repo
git -C repo commit -q --allow-empty -m "test: commit"
assert_eq "dotsteward-test <dotsteward-test@example.invalid> +0000" \
  "$(git -C repo log -1 --format='%an <%ae> %ad' --date=format:%z)"
assert_eq main "$(git -C repo symbolic-ref --short HEAD)"

# Platform injection points point at synthetic data inside the root.
for name in DOTSTEWARD_ETC_SHELLS DOTSTEWARD_OS_RELEASE DOTSTEWARD_PASSWD_CMD DOTSTEWARD_SW_VERS; do
  assert_contains "${!name}" "$DS_TEST_ROOT/" "$name"
  [[ -f ${!name} ]] || ds_fail "$name does not exist"
done
assert_contains "$(<"$DOTSTEWARD_ETC_SHELLS")" /bin/bash
assert_contains "$(<"$DOTSTEWARD_OS_RELEASE")" "ID=ubuntu"
assert_contains "$(<"$DOTSTEWARD_OS_RELEASE")" 'VERSION_ID="24.04"'
assert_eq "example:x:1000:1000:example:$HOME:/bin/bash" "$("$DOTSTEWARD_PASSWD_CMD" example)"
assert_eq 15.0 "$("$DOTSTEWARD_SW_VERS" -productVersion)"
# The machine facts of the derived gate parallelism: 32768 MiB and 16 CPUs.
assert_eq "32768 16" "$DOTSTEWARD_MEMORY_MIB $DOTSTEWARD_CPU_COUNT"
assert_contains "$("$DOTSTEWARD_SW_VERS")" "ProductName:"
assert_exit 1 "$DOTSTEWARD_SW_VERS" -bogus

# fake_secret builds secret-shaped strings at run time.
first=$(fake_secret gh"p_")
second=$(fake_secret gh"p_")
[[ $first =~ ^ghp_[A-Za-z0-9]{36}$ ]] || ds_fail "unexpected shape: ${#first} characters"
[[ $first != "$second" ]] || ds_fail "fake_secret repeated itself"
[[ $(fake_secret AK"IA" 16 upper-alnum) =~ ^AKIA[A-Z0-9]{16}$ ]] || ds_fail "upper-alnum shape"
[[ $(fake_secret x 8 hex) =~ ^x[0-9a-f]{8}$ ]] || ds_fail "hex shape"
assert_eq prefix "$(fake_secret prefix 0)"
assert_exit 1 fake_secret
assert_exit 1 fake_secret p 12 nope
assert_exit 1 fake_secret p twelve

# ds_record_call quotes arguments so the log is unambiguous.
ds_record_call example-app
ds_record_call example-term "a b" "" 'q"uote'
assert_eq "example-app
example-term a\\ b '' q\\\"uote" "$(<"$DS_CALL_LOG")"
