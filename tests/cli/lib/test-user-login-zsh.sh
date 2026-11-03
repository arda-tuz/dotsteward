# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # zsh code in single quotes on purpose
# user_login_zsh SCRIPT [ARG...]: runs the zsh code SCRIPT, with ARG... as
# its positional parameters, in one interactive login zsh, the shell a
# terminal opens, started from the user's PATH (user_run) with standard
# input from /dev/null. It prints what SCRIPT prints on standard output,
# without what the startup files print before it, and returns SCRIPT's exit
# status; standard error is the caller's. One call starts one login shell,
# so a hook asks for all its answers in one SCRIPT.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

command -v zsh >/dev/null 2>&1 || ds_fail "the login zsh tests need zsh on PATH"

logins=$DS_TEST_ROOT/logins
user_bin=$DS_TEST_ROOT/user-bin
toolchain=$DS_TEST_ROOT/toolchain
mkdir -p "$user_bin" "$toolchain"
printf '#!%s\necho user\n' "$BASH" >"$user_bin/example-app"
printf '#!%s\necho toolchain\n' "$BASH" >"$toolchain/example-term"
chmod 0755 "$user_bin/example-app" "$toolchain/example-term"
# Startup files that count the login shells and print before any script,
# the last line without a newline.
{
  printf 'print -r -- login >>%q\n' "$logins"
  printf 'path=(%q $path)\n' "$user_bin"
  printf 'print -r -- "zprofile says hello"\n'
} >"$HOME/.zprofile"
printf 'print -r -- "zshrc says hello"\nprint -rn -- "and no newline"\n' >"$HOME/.zshrc"
: >"$logins"

# login_count: the login shells started since the last reset.
login_count() {
  local count
  count=$(wc -l <"$logins")
  printf '%s\n' "$((count))"
}

# Several answers from one login shell, the arguments as $1, $2, ...
actual=$(user_login_zsh 'print -r -- "first $1"; print -r -- "second $2"; whence -p example-app' alpha 'beta gamma')
assert_eq "first alpha
second beta gamma
$user_bin/example-app" "$actual"
assert_eq 1 "$(login_count)" "one login shell"

# The script's exit status, with what it printed before.
: >"$logins"
status=0
actual=$(user_login_zsh 'print -r -- partial; exit 3') || status=$?
assert_eq 3 "$status"
assert_eq partial "$actual"
assert_eq 1 "$(login_count)"

# Nothing printed: nothing, not even an empty line.
assert_eq "x" "$(
  user_login_zsh 'true'
  printf x
)"

# Standard input is /dev/null, whatever the caller's is.
assert_eq "end of input" "$(printf 'from the caller\n' |
  user_login_zsh 'read -r line || line="end of input"; print -r -- $line')"

# Standard error is the caller's.
assert_contains "$(user_login_zsh 'print -r -- complaint >&2' 2>&1 >/dev/null)" complaint

# The user's PATH: the CLI's toolchain is not on it.
saved_path=$PATH
PATH=$toolchain:$saved_path
status=0
DOTSTEWARD_TOOLCHAIN_PATH=$toolchain user_login_zsh 'whence -p example-term' >/dev/null || status=$?
found=$(user_login_zsh 'whence -p example-term')
PATH=$saved_path
assert_eq 1 "$status" "a command of the toolchain only is not on the user's PATH"
assert_eq "$toolchain/example-term" "$found" "without DOTSTEWARD_TOOLCHAIN_PATH the PATH is kept"
