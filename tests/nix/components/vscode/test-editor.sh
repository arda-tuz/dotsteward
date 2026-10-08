# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154 # Nix expressions in single quotes; DS_* variables come from the harness
# The set_default_editor option of vscode: true sets exactly
# EDITOR = "code", VISUAL = "code" and GIT_EDITOR = "code --wait" in every
# profile where the component is active; absent or false sets none of them;
# anything else, and an unknown option, fails an assertion. With the
# app-archive method on darwin the code command of the installed bundle is
# put on PATH (home.sessionPath), so the editor variables work there too.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

editor='{"EDITOR":"code","GIT_EDITOR":"code --wait","VISUAL":"code"}'
bundle_bin='$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin'

# variables CASE SYSTEM PROFILE: the editor variables of that configuration
# (CASE "" is the fixture's own workstation.toml).
variables() {
  local inst='vscode { }'
  [[ -z $1 ]] || inst="vscode { case = \"$1\"; }"
  vscode_json "editorVariables (homeIn ($inst) \"$2\" \"$3\")" | jq -cS .
}

for system in x86_64-linux aarch64-darwin; do
  for profile in workstation fresh; do
    assert_eq "$editor" "$(variables "" "$system" "$profile")" "set_default_editor on $system ($profile)"
    assert_eq '{}' "$(variables editor-absent "$system" "$profile")" "no options on $system ($profile)"
    assert_eq '{}' "$(variables editor-false "$system" "$profile")" "set_default_editor = false on $system ($profile)"
  done
  # The variables follow the component's profiles; the manifest does not.
  assert_eq "$editor" "$(variables profile-scoped "$system" workstation)" "scoped component, active profile, $system"
  assert_eq '{}' "$(variables profile-scoped "$system" fresh)" "scoped component, other profile, $system"
  # They do not depend on the method.
  assert_eq "$editor" "$(variables method-external "$system" workstation)" "external method on $system"
done

# Invalid options fail with every problem named.
assert_vscode_fails '(home (vscode { case = "editor-invalid"; }) "x86_64-linux").home.activationPackage.drvPath' \
  "Failed assertions:" \
  'dotsteward: component vscode: options.set_default_editor must be true or false, got "yes"'
assert_vscode_fails '(home (vscode { case = "unknown-option"; }) "aarch64-darwin").home.activationPackage.drvPath' \
  "Failed assertions:" \
  "dotsteward: component vscode: unknown option theme (known: set_default_editor)"

# PATH: the bundle's command directory with app-archive on darwin (active
# profiles only); nothing on Linux or with the external method.
# path_of CASE SYSTEM PROFILE: home.sessionPath of that configuration.
path_of() {
  local inst='vscode { }'
  [[ -z $1 ]] || inst="vscode { case = \"$1\"; }"
  vscode_json "(homeIn ($inst) \"$2\" \"$3\").home.sessionPath" | jq -c .
}
assert_eq "$(jq -cn --arg b "$bundle_bin" '["$HOME/.local/bin", $b]')" "$(path_of "" aarch64-darwin workstation)" \
  "darwin app-archive PATH"
assert_eq "$(jq -cn --arg b "$bundle_bin" '["$HOME/.local/bin", $b]')" "$(path_of editor-absent aarch64-darwin fresh)" \
  "darwin app-archive PATH without the editor variables"
assert_eq '["$HOME/.local/bin"]' "$(path_of profile-scoped aarch64-darwin fresh)" "darwin, inactive profile"
assert_eq '["$HOME/.local/bin"]' "$(path_of method-external aarch64-darwin workstation)" "darwin external"
assert_eq '["$HOME/.local/bin"]' "$(path_of "" x86_64-linux workstation)" "Linux deb"

# The rendered session variables quote the directory, which contains
# spaces.
vars=$(vscode_json '(home (vscode { }) "aarch64-darwin").home.sessionVariablesPackage.text' | jq -r .)
assert_contains "$vars" "export PATH=\"\$HOME/.local/bin:$bundle_bin\${PATH:+:}\$PATH\""
assert_contains "$vars" 'export EDITOR="code"'
assert_contains "$vars" 'export GIT_EDITOR="code --wait"'
assert_contains "$vars" 'export VISUAL="code"'
