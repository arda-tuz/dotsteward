# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and herdr_* variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # zsh startup lines with a literal $ are written on purpose
# The E2E hook of herdr: an interactive login zsh, the shell a terminal
# opens, finds herdr on PATH. The hook is declared only when the shell
# component (zsh) is enabled; it runs with the hook environment (SPEC 8.4)
# and fails with a message when the login shell does not see herdr.
# shellcheck source=tests/nix/components/herdr/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/herdr/helpers.sh"

command -v zsh >/dev/null 2>&1 || ds_fail "the herdr E2E hook tests need zsh on PATH"

# Without the shell component there is no zsh login shell to check.
assert_herdr_eq '[]' '(herdrOf (herdrInstance { }) "x86_64-linux").checks.e2e'

# With it (a stand-in definition: the check only reads its enable flag), the
# hook is declared for every profile in the main phase.
with_shell='herdrInstance { homeModules = [ { dotsteward.components.shell = { enable = true; method = "nix"; }; } ]; }'
hooks=$(herdr_json "map (hook: hook // { script = baseNameOf (toString hook.script); }) (herdrOf ($with_shell) \"x86_64-linux\").checks.e2e")
assert_eq '[{"name":"herdr-login-zsh","phase":"main","profiles":null,"script":"e2e-login-zsh.sh"}]' "$(jq -cS . <<<"$hooks")"
# The manifest lists it with the script copied into the store.
script=$(nix_core_read_write=1 herdr_json "(manifestOf ($with_shell) \"aarch64-darwin\").checks.e2e" |
  jq -er '.[] | select(.component == "herdr" and .name == "herdr-login-zsh") | .script')
[[ -f $script && -x $script ]] || ds_fail "the hook script is not an executable file: $script"
cmp "$script" "$herdr_component/e2e-login-zsh.sh" || ds_fail "the manifest hook differs from the component's script"

# run_hook: runs the hook with the hook environment and a home whose zsh
# startup files are under the test's control.
run_hook() {
  assert_exit "$1" env \
    DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" \
    DOTSTEWARD_INSTANCE="$herdr_fixture" \
    DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/state" \
    DOTSTEWARD_PROFILE=workstation \
    DOTSTEWARD_PROFILE_MODE=fresh \
    DOTSTEWARD_PLATFORM=linux \
    DOTSTEWARD_COMPONENT=herdr \
    DOTSTEWARD_CHECK_ONLY=0 \
    "${@:2}" "$script"
}

# herdr in the Home Manager profile, which the login shell puts on PATH.
mkdir -p "$HOME/.nix-profile/bin" "$DS_TEST_ROOT/empty"
ln -s "$DS_REPO_ROOT/tests/lib/stubs/herdr" "$HOME/.nix-profile/bin/herdr"
printf 'path=("$HOME/.nix-profile/bin" $path)\n' >"$HOME/.zprofile"
: >"$HOME/.zshrc"
run_hook 0
assert_contains "$DS_STDOUT" "[dotsteward] a login zsh finds herdr: $HOME/.nix-profile/bin/herdr"

# The login shell does not see herdr: the hook fails and says so.
printf 'PATH=%q\n' "$DS_TEST_ROOT/empty" >"$HOME/.zshrc"
run_hook 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: herdr is not on PATH in a login zsh"

# Without zsh the hook cannot check anything and fails.
mkdir -p "$DS_TEST_ROOT/nozsh"
for tool in bash env dirname uname; do
  ln -s "$(command -v "$tool")" "$DS_TEST_ROOT/nozsh/$tool"
done
run_hook 1 PATH="$DS_TEST_ROOT/nozsh"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: required command not found: zsh"
