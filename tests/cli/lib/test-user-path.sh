# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# user_path and user_run CMD [ARG...]: the packaged CLI puts its own
# toolchain first on PATH and names those directories in
# DOTSTEWARD_TOOLCHAIN_PATH. user_path is PATH without them, in the same
# order; user_run runs CMD with that PATH, so CMD and everything it starts
# (a login shell and its startup files) see the user's commands, never the
# CLI's copies. Without DOTSTEWARD_TOOLCHAIN_PATH (a source checkout)
# user_path is PATH.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

toolchain=$DS_TEST_ROOT/toolchain
toolchain_two=$DS_TEST_ROOT/toolchain-two
user_bin=$DS_TEST_ROOT/user-bin
mkdir -p "$toolchain" "$toolchain_two" "$user_bin"
printf '#!%s\necho toolchain\n' "$BASH" >"$toolchain/example-app"
printf '#!%s\necho toolchain\n' "$BASH" >"$toolchain_two/example-term"
printf '#!%s\necho user\n' "$BASH" >"$user_bin/example-app"
# shellcheck disable=SC2016 # the script prints its own PATH
printf '#!%s\nprintf "%%s\\n" "$PATH"\n' "$BASH" >"$user_bin/example-path"
chmod 0755 "$toolchain/example-app" "$toolchain_two/example-term" "$user_bin/example-app" "$user_bin/example-path"

saved_path=$PATH

# The toolchain first, as the package wrapper puts it.
PATH=$toolchain:$toolchain_two:$user_bin:$saved_path
DOTSTEWARD_TOOLCHAIN_PATH=$toolchain:$toolchain_two
actual=$(user_path)
expected=$user_bin:$saved_path
PATH=$saved_path
assert_eq "$expected" "$actual"

PATH=$toolchain:$toolchain_two:$user_bin:$saved_path
app=$(user_run example-app)
child_path=$(user_run example-path)
term_status=0
user_run example-term >/dev/null 2>&1 || term_status=$?
PATH=$saved_path
assert_eq "user" "$app"
assert_eq "$user_bin:$saved_path" "$child_path"
assert_eq 127 "$term_status"

# Wherever a toolchain directory stands (a nested call, or a caller that
# prepended its own directories), it is dropped and the order of the other
# entries is kept.
PATH=$user_bin:$toolchain_two:/usr/bin:$toolchain:/bin
actual=$(user_path)
PATH=$saved_path
assert_eq "$user_bin:/usr/bin:/bin" "$actual"

# Without the toolchain variable: PATH as it is.
unset DOTSTEWARD_TOOLCHAIN_PATH
PATH=$toolchain:$user_bin:$saved_path
actual=$(user_path)
app=$(user_run example-app)
PATH=$saved_path
assert_eq "$toolchain:$user_bin:$saved_path" "$actual"
assert_eq "toolchain" "$app"
