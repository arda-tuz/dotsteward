# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_*, herdr_* and settings_* variables come from the harness and the helpers
# End to end through the settings engine: the targets file of the
# generation's local-maintained-files alias (rendered from the herdr
# component) drives `dotsteward settings apply` with an instance buffer that
# tracks herdr settings but defines no target of its own. The engine writes
# ~/.config/herdr/config.toml (created 0644 on a fresh machine, merged into
# an existing file without touching untracked settings) and reloads the
# running herdr server once per write, with HOME and XDG_CONFIG_HOME of the
# target home and without the caller's HERDR_SOCKET_PATH.
# shellcheck source=tests/nix/components/herdr/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/herdr/helpers.sh"
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

targets=$DS_TEST_ROOT/targets.json
herdr_json 'builtins.unsafeDiscardStringContext (home (herdrInstance { }) "x86_64-linux").dotsteward.cli.aliasPackage.passthru.targetsFile.text' |
  jq -r . >"$targets"
assert_json "$targets" '.targets | keys == ["herdr"]'

ds_use_stubs herdr
export HERDR_SOCKET_PATH=$DS_TEST_ROOT/herdr.sock

# A fresh machine: the file is created with the tracked settings.
settings_buffer F <"$herdr_fixture/local-maintained-files/buffer.toml"
home=$settings_work/F/home
config=$home/.config/herdr/config.toml
assert_exit 0 lmf F --targets-file "$targets" apply
[[ -f $config && ! -L $config ]] || ds_fail "the herdr configuration was not written as a regular file"
assert_file_mode "$config" 644
assert_eq false "$(toml_get "$config" onboarding)"
assert_eq '"ctrl+b"' "$(toml_get "$config" keys.prefix)"
assert_calls "herdr server reload-config" \
  "herdr:env HOME=$(printf '%q' "$home") XDG_CONFIG_HOME=$(printf '%q' "$home/.config") -HERDR_SOCKET_PATH"
assert_contains "$DS_STDOUT" "herdr-server"
assert_eq in-sync "$(lmf F --targets-file "$targets" status --json | jq -r '.entries[] | select(.id == "herdr-onboarding") | .state')"

# Nothing left to write: no second reload.
assert_exit 0 lmf F --targets-file "$targets" apply
assert_call_count 1 herdr

# An existing configuration: tracked settings are written on first contact,
# everything else in the file stays as the application wrote it.
settings_buffer E <"$herdr_fixture/local-maintained-files/buffer.toml"
existing=$settings_work/E/home/.config/herdr/config.toml
mkdir -p "$(dirname "$existing")"
printf 'onboarding = true\n\n[ui]\nsidebar_width = 30\n' >"$existing"
chmod 0600 "$existing"
assert_exit 0 lmf E --targets-file "$targets" apply
assert_eq false "$(toml_get "$existing" onboarding)"
assert_eq '"ctrl+b"' "$(toml_get "$existing" keys.prefix)"
assert_eq 30 "$(toml_get "$existing" ui.sidebar_width)"
assert_file_mode "$existing" 600
assert_call_count 2 herdr
