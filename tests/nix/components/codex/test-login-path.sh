# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # zsh startup lines with a literal $ are written on purpose
# The codex E2E hook codex-login-path: the codex an interactive login zsh
# (the shell a terminal opens) runs is the one the instance expects. The hook
# is declared with the shell component, for its profiles, and runs in
# parallel with the hooks next to it (it only reads). The expected
# location is options.expectedPath (a home or absolute path), else, with the
# official-binary method, its install destination ~/.local/bin/codex:
#   - the first codex on the login shell's PATH must be that file (a link to
#     it counts); a copy earlier on PATH fails the hook, which names the
#     shadowing path;
#   - codex missing from PATH, or the expected file missing, fails it.
# Without an expected location (external without expectedPath) the hook
# only reports more than one codex on PATH and passes.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

zsh_bin=$(command -v zsh) || ds_fail "the codex login path tests need zsh on PATH"
# No codex of the machine running the tests takes part; zsh stays, even when
# it shares a directory with a dropped command.
codex_hermetic_path
ln -s "$zsh_bin" "$DS_TEST_ROOT/tools/zsh"

component=$DS_REPO_ROOT/modules/components/codex

# with_shell DIR [PROFILES]: the instance in DIR with the shell component
# enabled (a stand-in definition: the hook reads its enable flag and its
# profiles only).
with_shell() {
  printf 'instance { root = /. + "%s"; homeModules = [ { dotsteward.components.shell = { enable = true; method = "nix"; profiles = %s; }; } ]; }' \
    "$1" "${2:-null}"
}

# hooks EXPR: the E2E hooks of codex in profile workstation, script names only.
hooks() {
  inst_json "map (hook: hook // { script = baseNameOf (toString hook.script); }) (homeOf ($1) \"x86_64-linux\" \"workstation\").dotsteward.components.codex.checks.e2e" |
    jq -cS .
}

# --- The declaration ---------------------------------------------------------------------

plain=$(codex_instance plain)
login_hook='map(select(.name == "codex-login-path"))'
assert_eq '[]' "$(hooks "$(codex_expr "$plain")" | jq -c "$login_hook")" "no hook without the shell component"
assert_eq '[{"name":"codex-login-path","parallel":true,"phase":"main","profiles":null,"script":"e2e-login-path.sh"}]' \
  "$(hooks "$(with_shell "$plain")" | jq -c "$login_hook")"
assert_eq '[{"name":"codex-login-path","parallel":true,"phase":"main","profiles":["workstation"],"script":"e2e-login-path.sh"}]' \
  "$(hooks "$(with_shell "$plain" '[ "workstation" ]')" | jq -c "$login_hook")"
[[ -x $component/e2e-login-path.sh ]] || ds_fail "e2e-login-path.sh is not executable"

# expectedPath is a home path or an absolute path.
expected=$(codex_instance expected '["x86_64-linux"]' 'method = "external"
options = { expectedPath = "~/.local/bin/codex" }')
assert_eq '{"expectedPath":"~/.local/bin/codex"}' \
  "$(inst_json "(homeOf ($(codex_expr "$expected")) \"x86_64-linux\" \"workstation\").dotsteward.components.codex.options" | jq -c .)"
for value in '"relative/codex"' '"~"' '7'; do
  invalid=$(codex_instance invalid-path '["x86_64-linux"]' "method = \"external\"
options = { expectedPath = $value }")
  assert_inst_fails "(homeOf ($(codex_expr "$invalid")) \"x86_64-linux\" \"workstation\").activationPackage" \
    "dotsteward: component codex: options.expectedPath must be a home path (~/...) or an absolute path, got $value"
done

# --- The hook in a real login zsh ------------------------------------------------------------

managed=$HOME/.local/bin/codex
shadow_dir=$HOME/.example-tools/bin
mkdir -p "$(dirname "$managed")" "$shadow_dir" "$HOME/elsewhere"
printf '#!%s\nprintf "codex-cli 1.0.0\\n"\n' "$BASH" >"$managed"
printf '#!%s\nprintf "codex-cli 2.0.0\\n"\n' "$BASH" >"$shadow_dir/codex"
chmod 0755 "$managed" "$shadow_dir/codex"
: >"$HOME/.zshrc"

# login_path DIR...: the login shell puts the directories first on PATH, in
# this order.
login_path() {
  local dir line='path=('
  for dir in "$@"; do
    line+="\"$dir\" "
  done
  printf '%s$path)\n' "$line" >"$HOME/.zprofile"
}

# run_hook STATUS INSTANCE [VAR=VALUE...]: runs the hook with the hook
# environment.
run_hook() {
  assert_exit "$1" env \
    DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" \
    DOTSTEWARD_INSTANCE="$2" \
    DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/state" \
    DOTSTEWARD_PROFILE=workstation \
    DOTSTEWARD_PROFILE_MODE=fresh \
    DOTSTEWARD_PLATFORM=linux \
    DOTSTEWARD_COMPONENT=codex \
    DOTSTEWARD_CHECK_ONLY=1 \
    "${@:3}" "$component/e2e-login-path.sh"
}

# The official-binary method (the default) expects its destination, and so
# does an external method with expectedPath.
for inst in "$plain" "$expected"; do
  login_path "$HOME/.local/bin" "$shadow_dir"
  run_hook 0 "$inst"
  assert_contains "$DS_STDOUT" "[dotsteward] a login zsh runs codex from $managed"

  # A copy earlier on PATH shadows it: the hook names it.
  login_path "$shadow_dir" "$HOME/.local/bin"
  run_hook 1 "$inst"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: a login zsh runs codex from $shadow_dir/codex, which shadows $managed; remove that copy or put $HOME/.local/bin before $shadow_dir on PATH"

  # A link to the expected file counts as that file.
  ln -s "$managed" "$HOME/elsewhere/codex"
  login_path "$HOME/elsewhere" "$shadow_dir"
  run_hook 0 "$inst"
  assert_contains "$DS_STDOUT" "[dotsteward] a login zsh runs codex from $HOME/elsewhere/codex"
  rm -f -- "$HOME/elsewhere/codex"

  # Not on PATH at all.
  login_path "$HOME/elsewhere"
  run_hook 1 "$inst"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: codex is not on PATH in a login zsh (expected $managed)"

  # The expected file is missing.
  mv -- "$managed" "$DS_TEST_ROOT/codex.saved"
  login_path "$shadow_dir"
  run_hook 1 "$inst"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: the expected codex $managed is not an executable file"
  mv -- "$DS_TEST_ROOT/codex.saved" "$managed"
done

# Without an expected location: several copies are reported, never a
# failure.
external=$(codex_instance external '["x86_64-linux"]' 'method = "external"')
login_path "$shadow_dir" "$HOME/.local/bin"
run_hook 0 "$external"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: a login zsh finds more than one codex: it runs $shadow_dir/codex, then $managed; set options.expectedPath of [components.codex] to require one"
login_path "$HOME/.local/bin"
run_hook 0 "$external"
assert_contains "$DS_STDOUT" "[dotsteward] a login zsh runs codex from $managed"
assert_not_contains "$DS_STDERR" "WARNING"
