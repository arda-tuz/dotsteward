# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # zsh lines with a literal $ are written on purpose
# The launchEnvironment option of claude-code and the MCP servers of its
# plugins, end to end: each entry names an environment variable and the
# command that prints its value. With the shell component, ~/.zshrc wraps
# claude in a function that runs every command at each launch and passes the
# value to that claude process only; the shell never exports it, and a value
# already in the environment is kept. The E2E hook claude-login-zsh, declared
# for the profiles of the shell component, checks in an interactive login zsh
# that no launch variable is exported, that claude is that function and,
# when every command prints a value, that Claude Code connects to each MCP
# server the plugins name (plugin:NAME:SERVER); a command without a value
# (no credential yet) is a hint, never a failure. Invalid entries fail the
# evaluation with every problem listed.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

command -v zsh >/dev/null 2>&1 || ds_fail "the launch environment tests need zsh on PATH"

component=$DS_REPO_ROOT/modules/components/claude-code

# with_shell DIR: the instance in DIR with the shell component enabled (a
# stand-in definition: the block and the hook read its enable flag and its
# profiles only).
with_shell() {
  printf 'instance { root = /. + "%s"; homeModules = [ { dotsteward.components.shell = { enable = true; method = "nix"; profiles = %s; }; } ]; }' \
    "$1" "${2:-null}"
}

# home EXPR: the Home Manager configuration of profile workstation.
home() {
  printf '(homeOf (%s) "x86_64-linux" "workstation")' "$1"
}

inst=$(cc_instance launch 'method = "external"
options = { launchEnvironment = [
  { name = "EXAMPLE_TOKEN", command = ["example-credential-helper", "--print", "it'"'"'s"] },
], plugins = [
  { spec = "example-plugin@example-market", mcpServers = ["example"] },
] }')

# --- Without the shell component: no block, no hook ------------------------------------

assert_inst_eq 'false' "$(home "$(cc_expr "$inst")").dotsteward.shell.zshrc.blocks ? claude-code-launch-environment"
assert_inst_eq '[]' "$(home "$(cc_expr "$inst")").dotsteward.components.claude-code.checks.e2e"

# --- With it: the block and the hook ---------------------------------------------------------

zshrc=$(inst_json "$(home "$(with_shell "$inst")").dotsteward.shell.zshrc.text" | jq -r .)
expected_zshrc=$(cat <<'EOF'
# The launch environment of the claude-code component: each variable comes
# from its command at every launch of claude and reaches only that process.
claude() {
  if [[ -z ${EXAMPLE_TOKEN:-} ]]; then
    local -x EXAMPLE_TOKEN
    EXAMPLE_TOKEN="$('example-credential-helper' '--print' 'it'\''s' </dev/null 2>/dev/null)" || EXAMPLE_TOKEN=""
    [[ -n $EXAMPLE_TOKEN ]] || unset EXAMPLE_TOKEN
  fi
  command claude "$@"
}
EOF
)
assert_eq "$expected_zshrc" "$zshrc" "the rendered launch environment block"
assert_inst_eq '75' "$(home "$(with_shell "$inst")").dotsteward.shell.zshrc.blocks.claude-code-launch-environment.order"

hooks=$(inst_json "map (hook: hook // { script = baseNameOf (toString hook.script); }) $(home "$(with_shell "$inst")").dotsteward.components.claude-code.checks.e2e")
assert_eq '[{"name":"claude-login-zsh","phase":"main","profiles":null,"script":"e2e-login-zsh.sh"}]' "$(jq -cS . <<<"$hooks")"
scoped=$(inst_json "map (hook: hook.profiles) $(home "$(with_shell "$inst" '[ "workstation" ]')").dotsteward.components.claude-code.checks.e2e")
assert_eq '[["workstation"]]' "$(jq -c . <<<"$scoped")"
[[ -x $component/e2e-login-zsh.sh ]] || ds_fail "e2e-login-zsh.sh is not executable"

# MCP servers alone declare the hook, without a block.
servers_only=$(cc_instance servers-only 'method = "external"
options = { plugins = [{ spec = "example-plugin@example-market", mcpServers = ["example"] }] }')
assert_inst_eq 'false' "$(home "$(with_shell "$servers_only")").dotsteward.shell.zshrc.blocks ? claude-code-launch-environment"
assert_eq '["claude-login-zsh"]' "$(inst_json "map (hook: hook.name) $(home "$(with_shell "$servers_only")").dotsteward.components.claude-code.checks.e2e" | jq -c .)"

# Neither: no hook.
plain=$(cc_instance plain 'method = "external"
options = { plugins = [{ spec = "example-plugin@example-market" }] }')
assert_inst_eq '[]' "$(home "$(with_shell "$plain")").dotsteward.components.claude-code.checks.e2e"

# --- The hook in a real login zsh ---------------------------------------------------------------

# The rendered ~/.zshrc, the claude stub and a credential helper in the Home
# Manager profile, which the login shell puts on PATH.
bin=$HOME/.nix-profile/bin
mkdir -p "$bin"
ln -s "$DS_REPO_ROOT/tests/lib/stubs/claude" "$bin/claude"
helper_calls=$DS_TEST_ROOT/helper-calls
cat >"$bin/example-credential-helper" <<EOF
#!$BASH
# A synthetic credential helper: prints the value in $DS_TEST_ROOT/credential,
# fails without one, and counts its calls.
printf '%s\n' "\$*" >>"$helper_calls"
[[ -s "$DS_TEST_ROOT/credential" ]] || exit 1
cat -- "$DS_TEST_ROOT/credential"
EOF
chmod 0755 "$bin/example-credential-helper"
printf 'path=("$HOME/.nix-profile/bin" $path)\n' >"$HOME/.zprofile"
printf '%s\n' "$zshrc" >"$HOME/.zshrc"
ds_stub_set claude mcp-servers '{"plugin:example-plugin:example": "EXAMPLE_TOKEN"}'

# run_hook STATUS [VAR=VALUE...]: runs the hook with the hook environment.
run_hook() {
  assert_exit "$1" env \
    DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" \
    DOTSTEWARD_INSTANCE="$inst" \
    DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/state" \
    DOTSTEWARD_PROFILE=workstation \
    DOTSTEWARD_PROFILE_MODE=fresh \
    DOTSTEWARD_PLATFORM=linux \
    DOTSTEWARD_COMPONENT=claude-code \
    DOTSTEWARD_CHECK_ONLY=0 \
    "${@:2}" "$component/e2e-login-zsh.sh"
}

# A credential: the value reaches claude, which connects; the login shell
# itself never holds it.
fake_secret example-token- >"$DS_TEST_ROOT/credential"
run_hook 0
assert_contains "$DS_STDOUT" "[dotsteward] claude-code: a login zsh passes EXAMPLE_TOKEN to claude only"
assert_contains "$DS_STDOUT" "[dotsteward] claude-code: Claude Code connects to plugin:example-plugin:example"
assert_contains "$(<"$helper_calls")" "--print it's"
assert_eq '' "$(zsh -lic 'claude --version >/dev/null; print -r -- "${EXAMPLE_TOKEN-}"' </dev/null 2>/dev/null | tail -n 1)" \
  "the shell keeps no value after a launch"

# The caller's own EXAMPLE_TOKEN never reaches the login shell of the check.
run_hook 0 EXAMPLE_TOKEN=from-caller
assert_not_contains "$DS_STDERR" "exports EXAMPLE_TOKEN"

# A value already in the environment is kept: the helper does not run.
: >"$helper_calls"
assert_contains "$(EXAMPLE_TOKEN=preset zsh -lic 'claude mcp get plugin:example-plugin:example' </dev/null 2>/dev/null)" "Status: Connected"
assert_eq '' "$(<"$helper_calls")" "the helper runs only without a value"

# No credential yet: a hint, the servers are not checked.
: >"$DS_TEST_ROOT/credential"
run_hook 0
assert_contains "$DS_STDOUT" "[dotsteward] claude-code: example-credential-helper --print it's printed no value for EXAMPLE_TOKEN in a login zsh; the MCP servers are checked once it does"
assert_not_contains "$DS_STDOUT" "connects to plugin:example-plugin:example"

# A server that does not connect with the value fails the check.
fake_secret example-token- >"$DS_TEST_ROOT/credential"
ds_stub_set claude mcp-servers '{"plugin:example-plugin:example": "OTHER_TOKEN"}'
run_hook 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: Claude Code does not connect to plugin:example-plugin:example in a login zsh (status: Failed to connect)"
ds_stub_set claude mcp-servers '{}'
run_hook 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: Claude Code does not connect to plugin:example-plugin:example in a login zsh (status: unknown)"
ds_stub_set claude mcp-servers '{"plugin:example-plugin:example": "EXAMPLE_TOKEN"}'

# The login shell exports the variable itself: it fails.
printf '%s\nexport EXAMPLE_TOKEN=exported\n' "$zshrc" >"$HOME/.zshrc"
run_hook 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: a login zsh exports EXAMPLE_TOKEN; only the claude function of the claude-code component may pass it to claude"

# claude is not wrapped: it fails.
: >"$HOME/.zshrc"
run_hook 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: a login zsh does not wrap claude in the launch environment function of the claude-code component"

# MCP servers without a launch environment: only the connection counts.
ds_stub_set claude mcp-servers '{"plugin:example-plugin:example": ""}'
run_hook 0 DOTSTEWARD_INSTANCE="$servers_only"
assert_contains "$DS_STDOUT" "[dotsteward] claude-code: Claude Code connects to plugin:example-plugin:example"

# --- Invalid entries ------------------------------------------------------------------------------

username() {
  printf '(homeOf (%s) "x86_64-linux" "workstation").home.username' "$(cc_expr "$1")"
}

invalid=$(cc_instance invalid 'options = { launchEnvironment = [
  { name = "lower_case", command = ["example-credential-helper"] },
  { name = "EXAMPLE_TOKEN", command = [] },
  { name = "EXAMPLE_TOKEN", command = ["example-credential-helper", ""], extra = 1 },
  "EXAMPLE_TOKEN",
  { command = "example-credential-helper" },
], plugins = [
  { spec = "example-plugin@example-market", mcpServers = ["bad/name"] },
  { spec = "other-plugin@example-market", mcpServers = "example" },
] }')
assert_inst_fails "$(username "$invalid")" \
  "Failed assertions:" \
  '- dotsteward: component claude-code: options.launchEnvironment[0].name must be an environment variable name ([A-Z_][A-Z0-9_]*), got "lower_case"' \
  "- dotsteward: component claude-code: options.launchEnvironment[1].command must be a non-empty list of non-empty strings (the argv of a command)" \
  "- dotsteward: component claude-code: options.launchEnvironment[2].command must be a non-empty list of non-empty strings (the argv of a command)" \
  "- dotsteward: component claude-code: options.launchEnvironment[2].name EXAMPLE_TOKEN is listed twice" \
  "- dotsteward: component claude-code: options.launchEnvironment[2] has unknown key extra (known: name, command)" \
  "- dotsteward: component claude-code: options.launchEnvironment[3] must be a table" \
  "- dotsteward: component claude-code: options.launchEnvironment[4].name must be an environment variable name ([A-Z_][A-Z0-9_]*), got null" \
  '- dotsteward: component claude-code: options.plugins[0].mcpServers[0] must be a plain server name, got "bad/name"' \
  "- dotsteward: component claude-code: options.plugins[1].mcpServers must be a list of server names"

invalid=$(cc_instance invalid-list 'options = { launchEnvironment = "EXAMPLE_TOKEN" }')
assert_inst_fails "$(username "$invalid")" \
  "- dotsteward: component claude-code: options.launchEnvironment must be a list of tables"
