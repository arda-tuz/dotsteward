# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Stage-0 on macOS (DOTSTEWARD_PLATFORM=darwin, sw_vers through
# DOTSTEWARD_SW_VERS): the darwin mirror .dotsteward/stage0.darwin.env,
# backups as on Linux, no APT (component apt prerequisites are Linux-only):
# the Xcode Command Line Tools must be installed, else stage-0 stops with
# the xcode-select hint after the backups and before any download; then the
# verified Nix install and stage 1.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs sudo apt-get dpkg-query curl xcode-select
export DOTSTEWARD_PLATFORM=darwin
stage0_env_set darwin "DS_STAGE0_PREREQUISITES_APT=(example-app-deps)"
mkdir -p "$HOME/.config/nix"
printf 'keep\n' >"$HOME/.config/nix/nix.conf"

# A stock macOS has no timeout(1): the remote probe uses its watchdog.
darwin_tools=$DS_TEST_ROOT/darwin-tools
mkdir -p "$darwin_tools"
stage0_path >/dev/null
for tool in "$DS_TEST_ROOT"/stage0-tools/*; do
  [[ ${tool##*/} == timeout ]] || ln -s "$(readlink "$tool")" "$darwin_tools/${tool##*/}"
done
run_darwin() {
  run_stage0 PATH="$DS_TEST_ROOT/bin:$darwin_tools" "$@"
}

# Without the Command Line Tools.
ds_stub_set xcode-select installed 0
assert_exit 1 run_darwin -- --profile fresh
assert_json - '.platform.os_id == "macos" and .platform.os_version == "15.0" and .route == "fast"' \
  <<<"$(sed -n '1,/^}$/p' <<<"$DS_STDOUT")"
assert_eq "[dotsteward] ERROR: the Xcode Command Line Tools are not installed; run 'xcode-select --install', finish the installation, then run ./bootstrap.sh again" \
  "$DS_STDERR"
mapfile -t dirs < <(backup_dirs)
assert_eq 1 "${#dirs[@]}" "backups come first"
assert_eq keep "$(<"${dirs[0]}/files$HOME/.config/nix/nix.conf")"
assert_eq "" "$(ds_calls_of sudo)$(ds_calls_of dpkg-query)$(ds_calls_of curl)$(ds_calls_of cli.sh)" \
  "no apt, no download, no stage 1"
assert_eq "xcode-select -p" "$(ds_calls_of xcode-select | sort -u)" "only checked, never installed"

# With them: Nix, then stage 1; still no APT.
ds_stub_set xcode-select installed 1
: >"$DS_CALL_LOG"
assert_exit 0 run_darwin -- --profile fresh
assert_eq "" "$(ds_calls_of sudo)$(ds_calls_of dpkg-query)" "no apt on darwin"
assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon"
assert_eq "cli.sh bootstrap --profile fresh --stage 1" "$(ds_calls_of cli.sh)"
assert_json - '.github_ssh_remote_accessible == true' <<<"$(sed -n '1,/^}$/p' <<<"$DS_STDOUT")"

# The darwin identity rules.
rm -r "$HOME/.nix-profile"
: >"$DS_CALL_LOG"
assert_exit 0 run_darwin USER=Example.User -- --profile fresh
assert_exit 1 run_darwin USER=-bad -- --profile fresh
assert_contains "$DS_STDERR" "unsafe user name: macOS user names must match"

# The darwin fast path: an older macOS is the adaptive route.
printf '#!%s\necho 13.6\n' "$BASH" >"$DS_TEST_ROOT/platform/sw_vers"
rm -rf "${DOTSTEWARD_STATE_ROOT:?}/backups"
assert_exit 3 run_darwin -- --profile fresh
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print -quit)" "no backup on the adaptive route"
