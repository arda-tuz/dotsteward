# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `skills hooks install|check|remove`: the hooks join the configuration of each
# agent without touching anything else in it, and `[skills] tracking` is the one
# switch. An instance that does not name it behaves as before. The text never
# changes with the generation, which Codex's trust depends on.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

export CLAUDE_CONFIG_DIR=$DS_TEST_ROOT/claude-config CODEX_HOME=$DS_TEST_ROOT/codex-home
settings=$CLAUDE_CONFIG_DIR/settings.json
codex_hooks=$CODEX_HOME/hooks.json
codex_config=$CODEX_HOME/config.toml
context=$HOME/.config/dotsteward/hook-context.json
hooks_of() { jq -c "[.hooks | to_entries[] | {event: .key, entries: .value}]" "$1"; }

# --- tracking off, the default of an instance that does not name it ------------------

assert_exit 0 ds_cli skills hooks install --agent claude
assert_contains "$DS_STDOUT" "tracking is off"
[[ ! -e $settings ]] || ds_fail "tracking off writes no settings"
[[ ! -e $context ]] || ds_fail "tracking off writes no context"
assert_exit 0 ds_cli skills hooks check --agent claude
assert_exit 0 ds_cli skills hooks check --agent codex
[[ ! -e $codex_hooks && ! -e $settings ]] || ds_fail "check writes nothing"
assert_exit 2 ds_cli skills hooks install --agent nonsense
assert_exit 2 ds_cli skills hooks nonsense

# --- Claude Code: merged, the rest of the file stays --------------------------------

mkdir -p "$CLAUDE_CONFIG_DIR"
cat >"$settings" <<'JSON'
{
  "model": "example",
  "permissions": {"allow": ["Read"]},
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "user-stop-hook"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "user-pre-hook"}]}]
  }
}
JSON
chmod 0640 "$settings"
tracking_on
assert_exit 0 ds_cli skills hooks install --agent claude
assert_file_mode "$settings" 0640
assert_json "$settings" '.model == "example" and .permissions.allow == ["Read"]'
assert_json "$settings" '.hooks.PreToolUse == [{"matcher": "Bash", "hooks": [{"type": "command", "command": "user-pre-hook"}]}]'
assert_json "$settings" '.hooks.Stop[0].hooks[0].command == "user-stop-hook"'
assert_eq 2 "$(jq '.hooks.Stop | length' "$settings")" "the user's hook and ours"
assert_json "$settings" '.hooks.Stop[1].hooks[0] | .type == "command" and .timeout == 10 and (.command | contains("skills hook Stop --agent claude"))'
assert_json "$settings" '.hooks.SessionStart[0].hooks[0].timeout == 10'
assert_json "$settings" '.hooks.PostToolUse[0] | .matcher == "Write|Edit|MultiEdit" and .hooks[0].timeout == 5'
assert_json "$settings" '.hooks.SessionEnd[0].hooks[0].timeout == 3'
# The text is the fixed one: no store path, no pass-through of a status.
text=$(hook_text claude Stop)
assert_eq '[ -x "$HOME/.nix-profile/bin/dotsteward" ] && "$HOME/.nix-profile/bin/dotsteward" skills hook Stop --agent claude 2>/dev/null; exit 0' "$text"
assert_not_contains "$(cat "$settings")" /nix/store
assert_not_contains "$(cat "$settings")" exec

# What the hooks need without looking for the instance.
assert_file_mode "$context" 0600
assert_eq "$agents_inst" "$(jq -r '.instance' "$context")"
assert_eq "$state" "$(jq -r '.state_root' "$context")"
assert_eq "$agents_lock" "$(jq -r '.lock_path' "$context")"
assert_json "$context" '.repo_owned_revisions == ["same-as-instance-checkout"]'
for root in "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills"; do
  assert_contains "$(jq -r '.roots[]' "$context")" "$root"
done
assert_contains "$(jq -r '.exclude[]' "$context")" .system
assert_contains "$(jq -r '.exclude[]' "$context")" synced

# A second install changes nothing, not even the time of the file.
sum=$(sha256sum "$settings")
touch -d '2001-01-01' "$settings"
stamp=$(stat -c %Y "$settings")
assert_exit 0 ds_cli skills hooks install --agent claude
assert_eq "$sum" "$(sha256sum "$settings")"
assert_eq "$stamp" "$(stat -c %Y "$settings")" "no write without a change"
assert_exit 0 ds_cli skills hooks check --agent claude
assert_contains "$DS_STDOUT" "claude: installed"

# A profile elsewhere: the stable path is found once, never a store path.
mkdir -p "$HOME/.local/state/nix/profiles/home-manager/home-path/bin"
mv "$HOME/.nix-profile/bin/dotsteward" "$HOME/.local/state/nix/profiles/home-manager/home-path/bin/dotsteward"
assert_exit 0 ds_cli skills hooks install --agent claude
assert_contains "$(hook_text claude Stop)" '$HOME/.local/state/nix/profiles/home-manager/home-path/bin/dotsteward'
mv "$HOME/.local/state/nix/profiles/home-manager/home-path/bin/dotsteward" "$HOME/.nix-profile/bin/dotsteward"
assert_exit 0 ds_cli skills hooks install --agent claude
assert_eq 2 "$(jq '.hooks.Stop | length' "$settings")" "a new text replaces the old one in place"

# A broken configuration is refused and stays as it is.
cp "$settings" "$settings.saved"
printf 'not json\n' >"$settings"
assert_exit 1 ds_cli skills hooks install --agent claude
assert_contains "$DS_STDERR" "$settings"
assert_eq 'not json' "$(cat "$settings")"
assert_exit 0 ds_cli skills hooks check --agent claude
assert_contains "$DS_STDOUT" "cannot read"
mv "$settings.saved" "$settings"

# --- Codex: hooks.json, one entry per event at the end, config.toml untouched ---------

mkdir -p "$CODEX_HOME"
printf 'model = "example"\n' >"$codex_config"
config_sum=$(sha256sum "$codex_config")
cat >"$codex_hooks" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "user-stop-hook"}]}]}}
JSON
assert_exit 0 ds_cli skills hooks install --agent codex
assert_eq "$config_sum" "$(sha256sum "$codex_config")"
assert_json "$codex_hooks" '.hooks.Stop | length == 2 and .[0].hooks[0].command == "user-stop-hook"'
assert_json "$codex_hooks" '.hooks.PostToolUse[0].matcher == "apply_patch|Edit|Write"'
assert_json "$codex_hooks" '.hooks.SessionStart | length == 1'
assert_contains "$(hook_text codex Stop)" 'skills hook Stop --agent codex'
# Trust: a note, never a failure, until /hooks has been answered.
assert_exit 0 ds_cli skills hooks check --agent codex
assert_contains "$DS_STDOUT" "/hooks"
{
  printf '\n[hooks.state."%s:session_start:0:0"]\ntrusted_hash = "sha256:00"\n' "$codex_hooks"
  printf '\n[hooks.state."%s:post_tool_use:0:0"]\ntrusted_hash = "sha256:00"\n' "$codex_hooks"
  printf '\n[hooks.state."%s:stop:1:0"]\ntrusted_hash = "sha256:00"\n' "$codex_hooks"
  printf '\n[hooks.state."%s:session_end:0:0"]\ntrusted_hash = "sha256:00"\n' "$codex_hooks"
} >>"$codex_config"
assert_exit 0 ds_cli skills hooks check --agent codex
assert_not_contains "$DS_STDOUT" "/hooks"
assert_contains "$DS_STDOUT" "codex: installed"
order_before=$(hooks_of "$codex_hooks")
assert_exit 0 ds_cli skills hooks install --agent codex
assert_eq "$order_before" "$(hooks_of "$codex_hooks")" "the order stays, trust depends on it"

# --- a missing entry is a note; remove is for this run; tracking is the switch --------

assert_exit 0 ds_cli skills hooks remove --agent claude
assert_json "$settings" '.hooks.Stop == [{"hooks": [{"type": "command", "command": "user-stop-hook"}]}]'
assert_json "$settings" '.hooks | has("SessionEnd") | not'
assert_json "$settings" '.model == "example"'
assert_exit 0 ds_cli skills hooks check --agent claude
assert_contains "$DS_STDOUT" "not installed"
assert_exit 0 ds_cli skills hooks install --agent claude
sed -i '/^tracking = true$/d' "$agents_inst/workstation.toml"
assert_exit 0 ds_cli skills hooks install --agent claude
assert_contains "$DS_STDOUT" "tracking is off"
assert_json "$settings" '.hooks.Stop == [{"hooks": [{"type": "command", "command": "user-stop-hook"}]}]'
assert_exit 0 ds_cli skills hooks remove --agent codex
assert_json "$codex_hooks" '.hooks.Stop == [{"hooks": [{"type": "command", "command": "user-stop-hook"}]}]'

# --- without --agent: the agents the instance enables -----------------------------------

rm -f "$settings" "$codex_hooks"
tracking_on
assert_exit 0 ds_cli skills hooks install
[[ ! -e $settings && ! -e $codex_hooks ]] || ds_fail "no agent component, nothing installed"
add_component claude-code external '{"external": {"command": "claude", "versionArgv": ["--version"]}}'
tracking_on
assert_exit 0 ds_cli skills hooks install
[[ -e $settings ]] || ds_fail "the enabled agent gets its hooks"
[[ ! -e $codex_hooks ]] || ds_fail "the other agent does not"

# --- the hook script of the catalog component, in both modes -----------------------------

rm -f "$settings" "$context"
hook=$DS_REPO_ROOT/modules/components/claude-code/skill-hooks.sh
run_component_hook() {
  env DOTSTEWARD_LIB="$agents_fw/cli/lib" DOTSTEWARD_INSTANCE="$agents_inst" DOTSTEWARD_COMPONENT=claude-code \
    DOTSTEWARD_CHECK_ONLY="$1" DOTSTEWARD_PROFILE=workstation "$hook" </dev/null
}
assert_exit 0 run_component_hook 1
[[ ! -e $settings ]] || ds_fail "check mode writes nothing"
assert_contains "$DS_STDOUT" "claude: not installed"
assert_exit 0 run_component_hook 0
assert_eq "" "$DS_STDOUT" "a rebuild does not hear of what went right"
assert_json "$settings" '.hooks.Stop[0].hooks[0].timeout == 10'
assert_exit 0 run_component_hook 1
assert_eq "" "$DS_STDOUT" "neither does an E2E run"
hook=$DS_REPO_ROOT/modules/components/codex/skill-hooks.sh
assert_exit 0 env DOTSTEWARD_LIB="$agents_fw/cli/lib" DOTSTEWARD_INSTANCE="$agents_inst" DOTSTEWARD_COMPONENT=codex \
  DOTSTEWARD_CHECK_ONLY=0 DOTSTEWARD_PROFILE=workstation "$hook"
assert_json "$codex_hooks" '.hooks.Stop[0].hooks[0].timeout == 10'

# --- an instance with local skills and no tracking behaves as before -----------------------

rm -f "$settings" "$codex_hooks" "$context"
sed -i '/^tracking = true$/d' "$agents_inst/workstation.toml"
hook=$DS_REPO_ROOT/modules/components/claude-code/skill-hooks.sh
assert_exit 0 run_component_hook 1
assert_eq "" "$DS_STDOUT" "with tracking off a hook says nothing"
assert_exit 0 run_component_hook 0
assert_eq "" "$DS_STDOUT" "with tracking off a hook says nothing"
own_skill alpha
assert_exit 0 run_agents check
assert_exit 0 ds_cli skills status
[[ ! -e $settings && ! -e $codex_hooks && ! -e $context ]] || ds_fail "without tracking, no hook configuration"
