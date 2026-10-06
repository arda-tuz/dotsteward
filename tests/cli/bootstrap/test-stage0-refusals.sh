# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Stage-0 refusals (SPEC 10.2): usage errors, a profile other than the
# bootstrap profile, an unsafe identity, a missing or foreign stage-0
# mirror and a missing launcher stop before any write; the adaptive route
# exits 3 before any write (no state, no backup, no apt, no download); a
# download that is not the pinned installer (size, SHA-256, not a text
# file, not HTTPS), a Nix of another version and failing snapshots or
# prerequisites stop stage-0 before stage 1.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs sudo apt-get dpkg-query curl example-app
for package in ca-certificates curl git gnupg xz-utils; do
  ds_dpkg_installed "$package" 1.0
done
mkdir -p "$HOME/.config/nix"
printf 'keep\n' >"$HOME/.config/nix/nix.conf"

# no_writes: nothing below the state root, no system call, no stage 1.
no_writes() {
  assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print -quit)" "state root untouched: $1"
  assert_eq "" "$(ds_calls_of sudo)$(ds_calls_of curl)$(ds_calls_of cli.sh)" "no apt, download or stage 1: $1"
  [[ ! -e $HOME/.nix-profile ]] || ds_fail "Nix installed: $1"
}

# --- usage ------------------------------------------------------------------
assert_exit 1 run_stage0 --
assert_eq "[dotsteward] ERROR: a fresh install requires --profile fresh" "$DS_STDERR"
no_writes "no profile"
assert_exit 1 run_stage0 -- --profile workstation
assert_eq "[dotsteward] ERROR: a fresh install requires --profile fresh" "$DS_STDERR"
no_writes "another profile"
assert_exit 1 run_stage0 -- --profile
assert_eq "[dotsteward] ERROR: --profile requires a value" "$DS_STDERR"
assert_exit 1 run_stage0 -- --profile fresh --bogus
assert_eq "[dotsteward] ERROR: unknown option: --bogus" "$DS_STDERR"
assert_exit 1 run_stage0 -- --install-nix-only --profile fresh
assert_eq "[dotsteward] ERROR: --install-nix-only takes no --profile" "$DS_STDERR"
assert_exit 0 run_stage0 -- --help
assert_contains "$DS_STDOUT" "Usage: ./bootstrap.sh --profile PROFILE"
assert_contains "$DS_STDOUT" "./bootstrap.sh --install-nix-only"
no_writes "usage"

# --- identity -----------------------------------------------------------------
assert_exit 1 run_stage0 USER=Root -- --profile fresh
assert_contains "$DS_STDERR" "unsafe user name: Linux user names must match"
assert_exit 1 run_stage0 HOME="$DS_TEST_ROOT/no such home" -- --profile fresh
assert_contains "$DS_STDERR" "unsafe HOME"
no_writes "identity"

# --- the mirror and the launcher ----------------------------------------------
mv "$bs_inst/.dotsteward/stage0.linux.env" "$DS_TEST_ROOT/stage0.linux.env"
assert_exit 1 run_stage0 -- --profile fresh
assert_eq "[dotsteward] ERROR: .dotsteward/stage0.linux.env not found in $bs_inst (run 'dotsteward sync' and commit it)" \
  "$DS_STDERR"
mv "$DS_TEST_ROOT/stage0.linux.env" "$bs_inst/.dotsteward/stage0.linux.env"
stage0_env_set linux 'DS_STAGE0_PLATFORM=darwin'
assert_exit 1 run_stage0 -- --profile fresh
assert_eq "[dotsteward] ERROR: $bs_inst/.dotsteward/stage0.linux.env describes darwin, not linux" "$DS_STDERR"
stage0_env_write linux
chmod 0644 "$bs_inst/.dotsteward/cli.sh"
assert_exit 1 run_stage0 -- --profile fresh
assert_eq "[dotsteward] ERROR: .dotsteward/cli.sh is missing or not executable in $bs_inst" "$DS_STDERR"
chmod 0755 "$bs_inst/.dotsteward/cli.sh"
no_writes "mirror and launcher"

# --- the adaptive route: exit 3 before any write --------------------------------
cp "$(ds_fixture common/os-release/debian-12)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_stage0 -- --profile fresh
assert_json - '.route == "adaptive" and .writes_performed == false' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "WARNING: the fast path does not match this machine"
no_writes "adaptive route"
if [[ -n ${DS_BASH32:-} ]]; then
  assert_exit 3 run_stage0 -- --profile fresh
  bs_bash=$BASH
  assert_exit 3 run_stage0 -- --profile fresh
  bs_bash=$DS_BASH32
  no_writes "adaptive route, both shells"
fi
# The document is the CLI's for the same machine (free space aside, which
# other processes change).
assert_exit 3 env PATH="$(cli_path)" "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json --profile fresh
cli_document=$(grep -v '"free_kib":' <<<"$DS_STDOUT")
assert_exit 3 run_stage0 -- --profile fresh
assert_eq "$cli_document" "$(grep -v '"free_kib":' <<<"$DS_STDOUT")" "stage-0 and CLI documents"
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"

# --- snapshots --------------------------------------------------------------------
stage0_env_set linux "DS_STAGE0_SNAPSHOTS=(bad/name)" "DS_STAGE0_SNAPSHOT_0_ARGV=(example-app dump)" \
  "DS_STAGE0_SNAPSHOT_0_REQUIRE_COMMAND=''"
assert_exit 1 run_stage0 -- --profile fresh
assert_eq "[dotsteward] ERROR: invalid snapshot name: bad/name" "$DS_STDERR"
stage0_env_write linux
stage0_env_set linux "DS_STAGE0_SNAPSHOTS=(example-app-state)" "DS_STAGE0_SNAPSHOT_0_ARGV=(example-app dump)" \
  "DS_STAGE0_SNAPSHOT_0_REQUIRE_COMMAND=example-app"
ds_stub_route example-app "dump" --exit 4 --stderr "cannot dump"
assert_exit 1 run_stage0 -- --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: snapshot example-app-state failed (exit 4)"
assert_eq "" "$(ds_calls_of sudo)$(ds_calls_of curl)$(ds_calls_of cli.sh)" "nothing after a failed snapshot"
stage0_env_write linux
rm -rf "${DOTSTEWARD_STATE_ROOT:?}/backups"

# --- prerequisites ------------------------------------------------------------------
stage0_env_set linux "DS_STAGE0_PREREQUISITES_APT=(example-unknown-package)"
assert_exit 100 run_stage0 -- --profile fresh
assert_eq "" "$(ds_calls_of cli.sh)" "no stage 1 after a failed apt transaction"
stage0_env_write linux
: >"$DS_CALL_LOG"

# --- the Nix installer ------------------------------------------------------------
# installer_case STATUS MESSAGE: stage-0 fails with STATUS and MESSAGE on
# standard error; no installer ran, no stage 1, the download directory is
# gone.
installer_case() {
  assert_exit "$1" run_stage0 -- --profile fresh
  assert_contains "$DS_STDERR" "$2"
  assert_not_contains "$(<"$DS_CALL_LOG")" "nix-installer"
  assert_eq "" "$(ds_calls_of cli.sh)" "no stage 1"
  assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'dotsteward-nix.*')" "installer directory removed"
  : >"$DS_CALL_LOG"
}
cat "$bs_installer" >"$DS_TEST_ROOT/tampered-installer"
printf '# x\n' >>"$DS_TEST_ROOT/tampered-installer"
ds_curl_serve "$bs_installer_url" "$DS_TEST_ROOT/tampered-installer"
installer_case 1 "[dotsteward] ERROR: size mismatch: "
# Same size, other bytes.
sed 's/Fake Nix installer/Fake nix installer/' "$bs_installer" >"$DS_TEST_ROOT/tampered-installer"
ds_curl_serve "$bs_installer_url" "$DS_TEST_ROOT/tampered-installer"
installer_case 1 "[dotsteward] ERROR: SHA-256 mismatch: "
ds_curl_fail "$bs_installer_url" 22 "The requested URL returned error: 404"
installer_case 22 "[dotsteward] ERROR: downloading $bs_installer_url failed (curl exit 22)"
rm -f -- "$(_ds_curl_path "$bs_installer_url").exit"
ds_curl_serve "$bs_installer_url" "$bs_installer"
stage0_env_set linux "DS_STAGE0_NIX_INSTALLER_URL=http://releases.example.invalid/nix/install"
installer_case 1 "[dotsteward] ERROR: refusing a download that is not HTTPS: http://releases.example.invalid/nix/install"
stage0_env_write linux
stage0_env_set linux "DS_STAGE0_NIX_INSTALLER_SHA256=not-a-digest"
installer_case 1 "[dotsteward] ERROR: invalid Nix installer pin: installer_sha256 not-a-digest"
stage0_env_write linux
# A pinned installer that `file` does not see as text is refused.
mkdir -p "$DS_TEST_ROOT/file-bin"
printf '#!%s\nprintf "application/x-executable\\n"\n' "$BASH" >"$DS_TEST_ROOT/file-bin/file"
chmod 0755 "$DS_TEST_ROOT/file-bin/file"
assert_exit 1 run_stage0 PATH="$DS_TEST_ROOT/bin:$DS_TEST_ROOT/file-bin:$(stage0_path)" -- --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the Nix installer is not a text file (application/x-executable)"
assert_not_contains "$(<"$DS_CALL_LOG")" "nix-installer"
: >"$DS_CALL_LOG"

# A Nix of another version stops stage-0, installed or found.
printf '2.30.0\n' >"$DS_TEST_ROOT/installed-nix-version"
assert_exit 1 run_stage0 -- --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: Nix version is not 2.35.2: nix (Nix) 2.30.0"
assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon"
assert_eq "" "$(ds_calls_of cli.sh)" "no stage 1 with another Nix"
: >"$DS_CALL_LOG"
assert_exit 1 run_stage0 -- --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: Nix version is not 2.35.2: nix (Nix) 2.30.0"
assert_not_contains "$(<"$DS_CALL_LOG")" "nix-installer"
rm -r "$HOME/.nix-profile" "$DS_TEST_ROOT/installed-nix-version"

# An installer that leaves no nix behind.
cat >"$DS_TEST_ROOT/empty-installer" <<'EOF'
# installs nothing
printf 'nix-installer %s\n' "$*" >>"$DS_CALL_LOG"
EOF
size=$(wc -c <"$DS_TEST_ROOT/empty-installer")
sha=$(sha256sum <"$DS_TEST_ROOT/empty-installer")
ds_curl_serve "$bs_installer_url" "$DS_TEST_ROOT/empty-installer"
stage0_env_set linux "DS_STAGE0_NIX_INSTALLER_SIZE=${size//[[:space:]]/}" "DS_STAGE0_NIX_INSTALLER_SHA256=${sha%% *}"
assert_exit 1 run_stage0 -- --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix is not on PATH after the installation"
assert_eq "" "$(ds_calls_of cli.sh)"
