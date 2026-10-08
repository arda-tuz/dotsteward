# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `install --check-only` in fresh mode: deb floors with
# dpkg ordering, apt packages present, external commands and floors; nix
# components are left to the probes. Read-only: no preflight, no sudo, no
# download, no write. The first failure stops with its message and exit 1;
# --json checks every component and reports them all.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl example-term example-app
pin_download desktop_packages.example-app "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" \
  https://downloads.example.invalid/example-app_1.2.3_amd64.deb 1.2.3
lock_set agent_tools.example-term '{"minimum_version": "1.0.0"}'
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app", "example-app-classic"], "architecture": null, "verifyAfterInstall": true, "apt": ["alpha"]}'
add_component example-term external '{"command": "example-term", "versionArgv": ["--version"], "minimum": "agent_tools.example-term"}'
add_component beta nix '{"packages": ["beta"]}'
ds_dpkg_installed example-app 1.1.0
ds_stub_set example-term version "example-term 0.9.0"
snapshot() { find "$HOME" "$DOTSTEWARD_STATE_ROOT" "$TMPDIR" -mindepth 1 ! -name 'dotsteward-assert.*' -print | LC_ALL=C sort; }
before=$(snapshot)

# Fail-fast: the first component's failure, the second is never run.
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-app (deb): example-app 1.2.3 or newer is not installed (found 1.1.0)" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count example-term)"

# --json: every component, in [components] order.
assert_exit 1 run_install --profile fresh --check-only --json
assert_json - '.result == "failed" and .check_only == true and .components == [
  {"name": "example-app", "method": "deb", "status": "failed", "detail": "example-app 1.2.3 or newer is not installed (found 1.1.0)"},
  {"name": "example-term", "method": "external", "status": "failed", "detail": "example-term 1.0.0 or newer is required (found 0.9.0)"},
  {"name": "beta", "method": "nix", "status": "skipped", "detail": "installed by Home Manager; checked by dotsteward probes"}
]' <<<"$DS_STDOUT"
assert_eq "[dotsteward] ERROR: example-app (deb): example-app 1.2.3 or newer is not installed (found 1.1.0)
[dotsteward] ERROR: example-term (external): example-term 1.0.0 or newer is required (found 0.9.0)" "$DS_STDERR"

# The floor is met through an alias; a missing apt package is the next
# failure.
ds_dpkg_installed example-app-classic 1.2.3
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-app (deb): apt package alpha is not installed" "$DS_STDERR"
ds_dpkg_installed alpha 1.0

# An unreadable version and a missing command fail too.
ds_stub_set example-term version "no version here"
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-term (external): example-term 1.0.0 or newer is required (found no version)" "$DS_STDERR"
manifest_edit '(.components[] | select(.name == "example-term") | .install.command) = "example-missing"'
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-term (external): command example-missing not found" "$DS_STDERR"
manifest_edit '(.components[] | select(.name == "example-term") | .install.command) = "example-term"'

# All satisfied: one line per component on standard output.
ds_stub_set example-term version "example-term 1.0.2"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh --check-only
assert_eq "[dotsteward] example-app (deb): satisfied: example-app-classic 1.2.3
[dotsteward] example-term (external): satisfied: example-term 1.0.2
[dotsteward] beta (nix): skipped: installed by Home Manager; checked by dotsteward probes" "$DS_STDOUT"
assert_eq "example-term --version" "$(ds_calls_of example-term)"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count preflight)"
assert_eq "$before" "$(snapshot)"

assert_exit 0 run_install --profile fresh --check-only --json
assert_json - '.result == "passed" and ([.components[].status] == ["satisfied", "satisfied", "skipped"])' <<<"$DS_STDOUT"
assert_eq "" "$DS_STDERR"
