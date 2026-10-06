# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_*, vscode_* and settings_* variables come from the harness and the helpers
# End to end through the settings engine: the targets file of the Linux
# generation's local-maintained-files alias (rendered from the vscode
# component) drives `dotsteward settings apply` with an instance buffer that
# tracks VS Code settings but defines no target of its own. The JSONC
# target creates settings.json (0644) on a fresh machine, merges into a
# comment-free file without touching untracked settings or its mode, and
# refuses (exit 2, nothing written) when the live file has comments or
# trailing commas, the way the editor itself may write it.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

targets=$DS_TEST_ROOT/targets.json
vscode_json 'builtins.unsafeDiscardStringContext (home (vscode { }) "x86_64-linux").dotsteward.cli.aliasPackage.passthru.targetsFile.text' |
  jq -r . >"$targets"
assert_json "$targets" '.targets | keys == ["vscode-settings"]'
assert_json "$targets" '.reload_hooks == {}'

# setting FILE NAME: the value of the top-level setting NAME (names contain
# dots) as compact JSON.
setting() {
  jq -c --arg name "$2" '.[$name]' "$1"
}

# A fresh machine: the file and its directories are created with the
# tracked settings.
settings_buffer F <"$vscode_fixture/local-maintained-files/buffer.toml"
settings_file=$settings_work/F/home/.config/Code/User/settings.json
assert_exit 0 lmf F --targets-file "$targets" apply
[[ -f $settings_file && ! -L $settings_file ]] || ds_fail "settings.json was not written as a regular file"
assert_file_mode "$settings_file" 644
assert_eq 14 "$(setting "$settings_file" editor.fontSize)"
assert_eq '"afterDelay"' "$(setting "$settings_file" files.autoSave)"
assert_eq in-sync "$(lmf F --targets-file "$targets" status --json | jq -r '.entries[] | select(.id == "vscode-font-size") | .state')"
assert_exit 0 lmf F --targets-file "$targets" verify

# An existing comment-free file: tracked settings are written on first
# contact, every other setting and the file mode stay as they were.
settings_buffer E <"$vscode_fixture/local-maintained-files/buffer.toml"
existing=$settings_work/E/home/.config/Code/User/settings.json
mkdir -p "$(dirname "$existing")"
printf '{\n  "workbench.colorTheme": "Default Dark Modern",\n  "editor.fontSize": 12\n}\n' >"$existing"
chmod 0600 "$existing"
assert_exit 0 lmf E --targets-file "$targets" apply
assert_eq 14 "$(setting "$existing" editor.fontSize)"
assert_eq '"afterDelay"' "$(setting "$existing" files.autoSave)"
assert_eq '"Default Dark Modern"' "$(setting "$existing" workbench.colorTheme)"
assert_file_mode "$existing" 600

# A file with comments and a trailing comma: every row of the target is an
# error, apply refuses before any write.
settings_buffer C <"$vscode_fixture/local-maintained-files/buffer.toml"
commented=$settings_work/C/home/.config/Code/User/settings.json
mkdir -p "$(dirname "$commented")"
cat >"$commented" <<'EOF'
{
  // Written by the editor.
  "editor.fontSize": 12,
  "workbench.colorTheme": "Default Dark Modern",
}
EOF
before=$(sha "$commented")
message="commented JSONC file; edit it in the application or remove the comments"
assert_exit 2 lmf C --targets-file "$targets" apply
assert_contains "$DS_STDERR" "vscode-font-size: $message"
assert_contains "$DS_STDERR" "no file is written"
assert_eq "$before" "$(sha "$commented")" "the commented settings.json was written"
assert_eq error "$(lmf C --targets-file "$targets" status --json | jq -r '.entries[] | select(.id == "vscode-auto-save") | .state')"
