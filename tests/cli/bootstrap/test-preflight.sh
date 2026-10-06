# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $(...) text is single-quoted on purpose
# dotsteward preflight (SPEC 6.2, port of scripts/preflight.sh): read-only
# facts about this machine against the instance's fast path, printed as
# today's JSON document (keys, order and two-space layout of the jq program
# it replaces) without jq; exit 0 on the fast route, 3 on the adaptive route.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs nix

# --- the fast route (Ubuntu 24.04 of the harness, this machine's arch) ------
assert_exit 0 run_preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh fast true ubuntu 24.04 "$bs_arch" unknown 2.31.2 "$free" true)" \
  "$DS_STDOUT" "fast route document (profile defaults to profiles.bootstrap)"
assert_eq "" "$DS_STDERR" "nothing on standard error"
# Nothing was written: no state, no backups, the instance untouched.
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print -quit)" "state root untouched"
assert_eq "" "$(git -C "$bs_inst" status --porcelain)" "instance untouched"

# The human line goes to standard output.
assert_exit 0 run_preflight --read-only
assert_eq "[dotsteward] route=fast os=ubuntu-24.04 arch=$bs_arch desktop=unknown" "$DS_STDOUT"

# --profile selects any profile of the instance.
assert_exit 0 run_preflight --read-only --json --profile workstation
assert_json - '.profile == "workstation" and .route == "fast"' <<<"$DS_STDOUT"
assert_exit 0 run_preflight --read-only --json --profile=workstation
assert_json - '.profile == "workstation"' <<<"$DS_STDOUT"

# --- the adaptive route: exit 3 after the document, a warning ---------------
cp "$(ds_fixture common/os-release/debian-12)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh adaptive false debian 12 "$bs_arch" unknown 2.31.2 "$free" true)" \
  "$DS_STDOUT" "adaptive route document"
assert_eq "[dotsteward] WARNING: the fast path does not match this machine; continue on the adaptive route without writing to the tracked repository" \
  "$DS_STDERR"
assert_exit 3 run_preflight --read-only
assert_eq "[dotsteward] route=adaptive os=debian-12 arch=$bs_arch desktop=unknown" "$DS_STDOUT"
cp "$(ds_fixture common/os-release/ubuntu-22.04)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_preflight --read-only --json
assert_json - '.platform.os_id == "ubuntu" and .platform.os_version == "22.04" and .fast_path == false' <<<"$DS_STDOUT"

# The architecture is part of the fast path.
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"
stage0_env_set linux 'DS_STAGE0_FAST_PATH_ARCHITECTURE=riscv128'
assert_exit 3 run_preflight --read-only --json
assert_json - ".route == \"adaptive\" and .platform.architecture == \"$bs_arch\"" <<<"$DS_STDOUT"
stage0_env_write linux

# --- os-release is parsed, never executed -----------------------------------
cat >"$DOTSTEWARD_OS_RELEASE" <<EOF
# comment
NAME='Example Linux'
ID=ubuntu
ID=ubuntu
VERSION_ID=\$(touch $DS_TEST_ROOT/pwned)
EOF
assert_exit 3 run_preflight --read-only --json
[[ ! -e $DS_TEST_ROOT/pwned ]] || ds_fail "os-release was executed"
assert_json - ".platform.os_version == \"\$(touch $DS_TEST_ROOT/pwned)\"" <<<"$DS_STDOUT"
printf 'ID="ubuntu"\nVERSION_ID="24.04"\nVERSION_ID="24.04"\n' >"$DOTSTEWARD_OS_RELEASE"
assert_exit 0 run_preflight --read-only --json
# Missing keys read as "unknown".
printf 'NAME=Nothing\n' >"$DOTSTEWARD_OS_RELEASE"
assert_exit 3 run_preflight --read-only --json
assert_json - '.platform.os_id == "unknown" and .platform.os_version == "unknown"' <<<"$DS_STDOUT"
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"

# --- JSON strings are escaped exactly like jq -------------------------------
desktop=$'Example "quoted" \\ back\ttab\x01\x7f caf\xc3\xa9'
assert_exit 0 env XDG_CURRENT_DESKTOP="$desktop" "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh fast true ubuntu 24.04 "$bs_arch" "$desktop" 2.31.2 "$free" true)" \
  "$DS_STDOUT" "escaped desktop"

# --- the remote: reachable, missing, and the batch-mode SSH default ---------
stage0_env_set linux 'DS_STAGE0_INSTANCE_REMOTE=git@github.com:example-org/missing.git'
assert_exit 0 run_preflight --read-only --json
assert_json - '.github_ssh_remote_accessible == false' <<<"$DS_STDOUT"
stage0_env_write linux
# Without GIT_SSH_COMMAND git runs ssh in batch mode with a connect timeout.
mkdir -p "$DS_TEST_ROOT/ssh-bin"
cat >"$DS_TEST_ROOT/ssh-bin/ssh" <<EOF
#!$BASH
printf '%s\n' "\$*" >>$(printf %q "$DS_TEST_ROOT/ssh.log")
exit 255
EOF
chmod 0755 "$DS_TEST_ROOT/ssh-bin/ssh"
assert_exit 0 env -u GIT_SSH_COMMAND PATH="$DS_TEST_ROOT/ssh-bin:$PATH" \
  "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only --json
assert_json - '.github_ssh_remote_accessible == false' <<<"$DS_STDOUT"
assert_contains "$(<"$DS_TEST_ROOT/ssh.log")" "-o BatchMode=yes -o ConnectTimeout=15" "batch-mode ssh"
assert_contains "$(<"$DS_TEST_ROOT/ssh.log")" "git@github.com" "the configured remote"

# --- Nix: the version, or null without Nix ----------------------------------
ds_stub_set nix version 'nix (Nix) 2.35.2'
assert_exit 0 run_preflight --read-only --json
assert_json - '.nix_version == "2.35.2"' <<<"$DS_STDOUT"
assert_exit 0 env PATH="$(cli_path)" "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only --json
free=$(preflight_free_kib "$DS_STDOUT")
assert_eq "$(expected_preflight_json fresh fast true ubuntu 24.04 "$bs_arch" unknown null "$free" true)" \
  "$DS_STDOUT" "no Nix: null"
# A Nix that only the profile directory provides is found.
mkdir -p "$HOME/.nix-profile/bin"
printf '#!%s\necho "nix (Nix) 2.99.0"\n' "$BASH" >"$HOME/.nix-profile/bin/nix"
chmod 0755 "$HOME/.nix-profile/bin/nix"
assert_exit 0 env PATH="$(cli_path)" "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only --json
assert_json - '.nix_version == "2.99.0"' <<<"$DS_STDOUT"
rm -r "$HOME/.nix-profile"

# --- refusals ---------------------------------------------------------------
assert_exit 1 run_preflight --json
assert_eq "[dotsteward] ERROR: preflight runs only with --read-only" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_exit 1 run_preflight --read-only --bogus
assert_eq "[dotsteward] ERROR: preflight: unknown option: --bogus" "$DS_STDERR"
assert_exit 1 run_preflight --read-only --profile
assert_eq "[dotsteward] ERROR: preflight: --profile requires a value" "$DS_STDERR"
assert_exit 1 run_preflight --read-only --profile nope
assert_eq "[dotsteward] ERROR: unsupported profile: nope (profiles: workstation, fresh)" "$DS_STDERR"
assert_exit 1 env USER='Bad User' "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight --read-only
assert_contains "$DS_STDERR" "unsafe user name"
assert_exit 1 env HOME="$DS_TEST_ROOT/missing-home" "$bs_fw/cli/dotsteward" --instance "$bs_inst" \
  preflight --read-only
assert_contains "$DS_STDERR" "unsafe HOME"
# The mirror must exist and describe this platform.
mv "$bs_inst/.dotsteward/stage0.linux.env" "$DS_TEST_ROOT/stage0.linux.env"
assert_exit 1 run_preflight --read-only
assert_eq "[dotsteward] ERROR: .dotsteward/stage0.linux.env not found in $bs_inst (run 'dotsteward sync' and commit it)" \
  "$DS_STDERR"
mv "$DS_TEST_ROOT/stage0.linux.env" "$bs_inst/.dotsteward/stage0.linux.env"
stage0_env_set linux 'DS_STAGE0_SCHEMA_VERSION=2'
assert_exit 1 run_preflight --read-only
assert_eq "[dotsteward] ERROR: unsupported stage-0 schema_version 2: $bs_inst/.dotsteward/stage0.linux.env" "$DS_STDERR"
stage0_env_write linux
stage0_env_set linux 'DS_STAGE0_PLATFORM=darwin'
assert_exit 1 run_preflight --read-only
assert_eq "[dotsteward] ERROR: $bs_inst/.dotsteward/stage0.linux.env describes darwin, not linux" "$DS_STDERR"
stage0_env_write linux

# --help describes the command.
assert_exit 0 run_preflight --help
assert_contains "$DS_STDOUT" "Usage: dotsteward preflight --read-only [--json] [--profile PROFILE]"
assert_contains "$("$bs_fw/cli/dotsteward" --help)" "preflight"
