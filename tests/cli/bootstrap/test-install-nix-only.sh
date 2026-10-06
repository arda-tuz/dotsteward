# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# bootstrap.sh --install-nix-only (SPEC 10.2, 9.7): only the verified Nix
# install and the exact version check, for dotsteward-init before an
# instance exists (the framework's template/bootstrap.sh next to its
# template/versions.lock.json). The pin comes from the stage-0 mirror when
# there is one, else from versions.lock.json beside the script, read
# without jq (the canonical lock layout). No profile, no preflight, no
# backups, no prerequisites, no stage 1.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs sudo apt-get dpkg-query curl

# nothing_else: no state, no apt, no stage 1.
nothing_else() {
  assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print -quit)" "state root untouched"
  assert_eq "" "$(ds_calls_of sudo)$(ds_calls_of dpkg-query)$(ds_calls_of cli.sh)" "no apt, no stage 1"
}

# In an instance: the mirror's pin.
assert_exit 0 run_stage0 -- --install-nix-only
assert_eq "[dotsteward] starting the verified Nix 2.35.2 multi-user installer
[dotsteward] Nix 2.35.2 is installed" "$DS_STDOUT"
assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon"
[[ -x $HOME/.nix-profile/bin/nix ]] || ds_fail "Nix was not installed"
nothing_else
# Again: Nix is there, nothing is downloaded.
: >"$DS_CALL_LOG"
assert_exit 0 run_stage0 -- --install-nix-only
assert_eq "[dotsteward] Nix 2.35.2 is installed" "$DS_STDOUT"
assert_eq "" "$(ds_calls_of curl)" "no download"
rm -r "$HOME/.nix-profile"
: >"$DS_CALL_LOG"

# Before an instance exists: the script and versions.lock.json of an
# unpacked framework release (no .dotsteward/ beside it, no git).
release=$DS_TEST_ROOT/release/template
mkdir -p "$release"
cp "$bs_inst/bootstrap.sh" "$bs_inst/versions.lock.json" "$release/"
bs_inst_saved=$bs_inst
bs_inst=$DS_TEST_ROOT/release/template
assert_exit 0 run_stage0 DOTSTEWARD_ASSUME_YES=1 -- --install-nix-only
assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon --yes"
assert_contains "$DS_STDOUT" "[dotsteward] Nix 2.35.2 is installed"
nothing_else
rm -r "$HOME/.nix-profile"
: >"$DS_CALL_LOG"
if [[ -n ${DS_BASH32:-} ]]; then
  bs_bash=$BASH
  assert_exit 0 run_stage0 -- --install-nix-only
  rm -r "$HOME/.nix-profile"
  bs_bash=$DS_BASH32
  : >"$DS_CALL_LOG"
fi

# The lock reader: the four pins of the "nix" table, nothing else.
lock=$release/versions.lock.json
cp "$lock" "$DS_TEST_ROOT/lock.json"
jq --indent 2 '.nix.version = "2.30.0"' "$DS_TEST_ROOT/lock.json" >"$lock"
printf '2.30.0\n' >"$DS_TEST_ROOT/installed-nix-version"
assert_exit 0 run_stage0 -- --install-nix-only
assert_contains "$DS_STDOUT" "[dotsteward] Nix 2.30.0 is installed"
rm -r "$HOME/.nix-profile" "$DS_TEST_ROOT/installed-nix-version"
# Key order does not matter, and a "nix" key nested in another table is not
# the pin.
jq --indent 2 '{ other: { nix: { version: "0.0.1" } }, nix: { installer_sha256: .nix.installer_sha256,
  installer_size: .nix.installer_size, installer_url: .nix.installer_url, version: .nix.version },
  flake_inputs: .flake_inputs }' "$DS_TEST_ROOT/lock.json" >"$lock"
assert_exit 0 run_stage0 -- --install-nix-only
assert_contains "$DS_STDOUT" "[dotsteward] Nix 2.35.2 is installed"
rm -r "$HOME/.nix-profile"
# A missing pin, a malformed value or no lock at all is refused before
# any download.
: >"$DS_CALL_LOG"
jq --indent 2 'del(.nix.installer_sha256)' "$DS_TEST_ROOT/lock.json" >"$lock"
assert_exit 1 run_stage0 -- --install-nix-only
assert_eq "[dotsteward] ERROR: $lock: cannot read nix.installer_sha256" "$DS_STDERR"
jq --indent 2 '.nix.installer_size = "big"' "$DS_TEST_ROOT/lock.json" >"$lock"
assert_exit 1 run_stage0 -- --install-nix-only
assert_eq "[dotsteward] ERROR: $lock: cannot read nix.installer_size" "$DS_STDERR"
rm "$lock"
assert_exit 1 run_stage0 -- --install-nix-only
assert_eq "[dotsteward] ERROR: neither .dotsteward/stage0.linux.env nor versions.lock.json found in $release" \
  "$DS_STDERR"
assert_eq "" "$(ds_calls_of curl)" "no download without a pin"
bs_inst=$bs_inst_saved
