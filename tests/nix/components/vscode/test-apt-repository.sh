# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154 # Nix expressions in single quotes; DS_* variables come from the harness
# options.vendor_repository = true of vscode (Linux, deb method): VS Code
# keeps updating with plain `apt upgrade` through the vendor's APT
# repository, which the code package's own installer owns. The hook
# apt-repository.sh is declared as a systemInstall hook and as an E2E hook:
#   - systemInstall (`dotsteward install`): when no APT source maps
#     https://packages.microsoft.com/repos/code, it answers the installer's
#     repository question with yes (debconf-set-selections) and runs the
#     package's configuration again (dpkg-reconfigure), so the installer
#     writes its own source and key, then apt-get update; a source that
#     already maps the repository (any file, any format) is left alone;
#   - E2E: reading only, an APT source maps the repository and APT takes
#     code from it (apt-cache policy), with the command to run otherwise;
#     so it runs in parallel with the hooks next to it.
# The framework never writes, rewrites or removes the source itself. The
# option is refused unless it is a boolean, and with another method on
# Linux; without it nothing is declared.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

# hooks CASE SYSTEM LIST: the hooks of LIST (checks.e2e or
# hooks.systemInstall) of vscode, script names only.
hooks() {
  local inst='vscode { }'
  [[ -z $1 ]] || inst="vscode { case = \"$1\"; }"
  vscode_json "map (hook: hook // { script = baseNameOf (toString hook.script); }) (vscodeOf ($inst) \"$2\").$3" |
    jq -cS .
}

# --- The declaration -----------------------------------------------------------------------

# The E2E hook only reads, so it runs in parallel with the hooks next to it.
declare -A expected=(
  [checks.e2e]='[{"name":"apt-repository","parallel":true,"phase":"main","profiles":null,"script":"apt-repository.sh"}]'
  [hooks.systemInstall]='[{"name":"apt-repository","phase":"main","profiles":null,"script":"apt-repository.sh"}]'
)
for list in checks.e2e hooks.systemInstall; do
  assert_eq '[]' "$(hooks "" x86_64-linux "$list")" "no $list without the option"
  assert_eq "${expected[$list]}" "$(hooks vendor-repository x86_64-linux "$list")" "$list with vendor_repository"
  assert_eq '[]' "$(hooks vendor-repository aarch64-darwin "$list")" "no $list on darwin"
done
[[ -x $vscode_component/apt-repository.sh ]] || ds_fail "apt-repository.sh is not executable"

assert_vscode_fails '(home (vscode { case = "vendor-repository-invalid"; }) "x86_64-linux").home.activationPackage.drvPath' \
  "Failed assertions:" \
  'dotsteward: component vscode: options.vendor_repository must be true or false, got "yes"'
assert_vscode_fails '(home (vscode { case = "vendor-repository-external"; }) "x86_64-linux").home.activationPackage.drvPath' \
  "Failed assertions:" \
  "dotsteward: component vscode: options.vendor_repository needs the deb method on Linux (the code package's installer adds the repository), got external"

# --- The hook, over stand-ins --------------------------------------------------------------------

hook=$vscode_component/apt-repository.sh
repository=https://packages.microsoft.com/repos/code
instance=$DS_TEST_ROOT/instance
apt=$DS_TEST_ROOT/apt
bin=$DS_TEST_ROOT/fake-bin
state=$DS_TEST_ROOT/fake-state
calls=$DS_TEST_ROOT/calls
mkdir -p "$instance" "$apt/sources.list.d" "$bin" "$state"
printf 'deb http://archive.example.com/ubuntu noble main\n' >"$apt/sources.list"

# Stand-ins start with the running bash: the Nix sandbox has no /usr/bin/env.
# sudo runs the command; dpkg-reconfigure acts as the code installer does: with
# the question answered yes and no source of the repository, it writes its
# own deb822 source; apt-cache lists the repository once apt-get update read a
# source of it.
cat >"$bin/sudo" <<STUB
#!$BASH
printf 'sudo %s\n' "\$*" >>"$calls"
exec "\$@"
STUB
cat >"$bin/debconf-set-selections" <<STUB
#!$BASH
cat >>"$state/debconf"
STUB
cat >"$bin/dpkg-reconfigure" <<STUB
#!$BASH
[[ ! -f "$state/no-write" ]] || exit 0
grep -qx 'code code/add-microsoft-repo boolean true' "$state/debconf" 2>/dev/null || exit 0
grep -rqs 'packages.microsoft.com/repos/code' "$apt/sources.list.d" && exit 0
printf '%s\n' '### THIS FILE IS AUTOMATICALLY CONFIGURED ###' 'Types: deb' 'URIs: $repository' 'Suites: stable' \\
  'Components: main' 'Architectures: amd64' 'Signed-By: /usr/share/keyrings/microsoft.gpg' >"$apt/sources.list.d/vscode.sources"
STUB
cat >"$bin/dpkg-query" <<STUB
#!$BASH
[[ \$1 == -W && \$3 == code ]] || exit 64
[[ -f "$state/installed" ]] || exit 1
printf 'installed'
STUB
cat >"$bin/apt-get" <<STUB
#!$BASH
[[ \$1 == update ]] || exit 64
if grep -rqs 'packages.microsoft.com/repos/code' "$apt/sources.list.d" "$apt/sources.list"; then
  : >"$state/indexed"
fi
STUB
cat >"$bin/apt-cache" <<STUB
#!$BASH
[[ \$1 == policy && \$2 == code ]] || exit 64
printf 'code:\n  Installed: 1.140.0-1\n  Candidate: 1.140.0-1\n  Version table:\n *** 1.140.0-1 500\n'
[[ ! -f "$state/indexed" ]] || printf '        500 %s stable/main amd64 Packages\n' "$repository"
printf '        100 /var/lib/dpkg/status\n'
STUB
chmod +x "$bin"/*
: >"$state/installed"

# run_hook CHECK_ONLY: the hook with the hook environment (E2E: 1,
# systemInstall: 0).
run_hook() {
  env PATH="$bin:$PATH" DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" DOTSTEWARD_INSTANCE="$instance" \
    DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/state" DOTSTEWARD_PROFILE=workstation DOTSTEWARD_PROFILE_MODE=adopt \
    DOTSTEWARD_PLATFORM=linux DOTSTEWARD_COMPONENT=vscode DOTSTEWARD_CHECK_ONLY="$1" \
    DOTSTEWARD_APT_DIR="$apt" "$hook"
}

# E2E without a source of the repository: the command that adds it.
assert_exit 1 run_hook 1
assert_contains "$DS_STDERR" "vscode: no APT source maps $repository; run 'dotsteward --instance $instance install --profile workstation --component vscode' (it needs sudo) so the code installer adds it"
assert_eq "" "$(cat "$calls" 2>/dev/null)" "E2E changed something"

# systemInstall: the installer adds its own source, then APT reads it.
assert_exit 0 run_hook 0
assert_eq 'code code/add-microsoft-repo boolean true' "$(<"$state/debconf")"
assert_eq "sudo debconf-set-selections
sudo dpkg-reconfigure --frontend=noninteractive code
sudo timeout 600 apt-get update" "$(<"$calls")"
assert_contains "$DS_STDOUT" "vscode: APT source of $repository: $apt/sources.list.d/vscode.sources"
assert_exit 0 run_hook 1
assert_contains "$DS_STDOUT" "vscode: APT takes code from $repository ($apt/sources.list.d/vscode.sources)"

# A source that maps the repository already, in any file and format, is
# left alone: nothing runs.
rm -f -- "$apt/sources.list.d/vscode.sources" "$state/debconf" "$calls"
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] %s stable main\n' "$repository" \
  >"$apt/sources.list.d/vscode.list"
assert_exit 0 run_hook 0
assert_eq "" "$(cat "$calls" 2>/dev/null)" "an existing source was touched"
assert_eq "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] $repository stable main" \
  "$(<"$apt/sources.list.d/vscode.list")"
assert_exit 0 run_hook 1

# A source APT has not read yet: E2E names apt update.
rm -f -- "$state/indexed"
assert_exit 1 run_hook 1
assert_contains "$DS_STDERR" "vscode: APT does not take code from $repository yet ($apt/sources.list.d/vscode.list); run 'sudo apt update'"
: >"$state/indexed"

# A commented-out line maps nothing.
printf '# deb %s stable main\n' "$repository" >"$apt/sources.list.d/vscode.list"
assert_exit 1 run_hook 1
assert_contains "$DS_STDERR" "vscode: no APT source maps $repository"
rm -f -- "$apt/sources.list.d/vscode.list"

# The installer adds nothing: the hook fails and says so; without the code
# package there is no installer to run.
: >"$state/no-write"
assert_exit 1 run_hook 0
assert_contains "$DS_STDERR" "vscode: the code installer added no APT source for $repository"
rm -f -- "$state/no-write" "$state/installed"
assert_exit 1 run_hook 0
assert_contains "$DS_STDERR" "vscode: the code package is not installed, so its installer cannot add $repository"
