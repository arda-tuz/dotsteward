# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The official-binary method (a user-level release install):
# methods_official_binary_install checks
# the command found with dest's directory first on PATH against the pin's
# version by policy (at-least keeps a newer self-updated binary, exact
# replaces any other version), downloads the pinned URL with
# download_verified, extracts the member, backs up a previous regular file
# into <state>/backups/<UTC>/files/<abs>, installs it with mode 0755 and
# re-checks the version. A non-regular dest is refused, a dest that cannot
# be backed up is left untouched; sigstore verification is refused until it
# is supported. `install --check-only` fails with the rebuild hint;
# `install` itself leaves the method to `dotsteward agents install`.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo curl
dest=$HOME/.local/bin/example-term
url=https://downloads.example.invalid/releases/example-term-1.0.0-x86_64-linux.tar.gz

# make_release VERSION REPORTED OUT [MEMBER_DIR]: a tar.gz whose member
# MEMBER_DIR/example-term (default example-term-VERSION) prints
# "example-term REPORTED".
make_release() {
  local version=$1 reported=$2 out=$3 member_dir=${4:-} dir
  [[ -n $member_dir ]] || member_dir=example-term-$version
  dir=$(mktemp -d "$DS_TEST_ROOT/release.XXXXXX")
  mkdir -p "$dir/$member_dir"
  printf '#!%s\nprintf "example-term %%s\\n" %q\n' "$BASH" "$reported" >"$dir/$member_dir/example-term"
  chmod 0755 "$dir/$member_dir/example-term"
  tar -czf "$out" -C "$dir" "$member_dir"
  rm -rf -- "$dir"
}

release=$DS_TEST_ROOT/example-term-1.0.0-x86_64-linux.tar.gz
make_release 1.0.0 1.0.0 "$release"
pin_download agent_tools.example-term "$release" "$url" 1.0.0
install_block='{
  "pin": "agent_tools.example-term",
  "asset": {"linux": "example-term-{version}-x86_64-linux.tar.gz", "darwin": "example-term-{version}-aarch64-darwin.tar.gz"},
  "member": "example-term-{version}/example-term",
  "dest": "~/.local/bin/example-term",
  "versionArgv": ["--version"],
  "versionRegex": "example-term ([0-9][0-9.]*)",
  "policy": "at-least",
  "verify": "sha256"
}'
add_component example-term official-binary "$install_block"

install_term() {
  in_methods_shell 'methods_official_binary_install example-term >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
set_block() {
  manifest_edit "(.components[] | select(.name == \"example-term\") | .install) |= ($1)"
}

# `install --check-only` reports the missing binary with the rebuild hint;
# `install` leaves it to the agents installer.
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-term (official-binary): example-term 1.0.0 or newer not found (found none); run 'dotsteward rebuild --profile fresh --switch'" "$DS_STDERR"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "[dotsteward] example-term (official-binary): skipped: installed by dotsteward agents install"
assert_eq "0" "$(ds_call_count curl)"
# Adopt mode checks it the same way (user level).
assert_exit 1 run_install --profile workstation --check-only
assert_contains "$DS_STDERR" "example-term 1.0.0 or newer not found (found none); run 'dotsteward rebuild --profile workstation --switch'"

# Install from nothing.
: >"$DS_CALL_LOG"
assert_exit 0 install_term
assert_eq "installed: example-term 1.0.0" "$DS_STDOUT"
assert_file_mode "$dest" 755
[[ -f $dest && ! -L $dest ]] || ds_fail "dest is not a regular file"
assert_eq "example-term 1.0.0" "$("$dest" --version)"
assert_eq "1" "$(ds_call_count curl)"
assert_contains "$(ds_calls_of curl)" "--proto =https --tlsv1.2 "
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "" "$(temp_dirs)"
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print)" "nothing to back up"
assert_exit 0 run_install --profile fresh --check-only
assert_eq "[dotsteward] example-term (official-binary): satisfied: example-term 1.0.0" "$DS_STDOUT"

# Idempotent.
: >"$DS_CALL_LOG"
assert_exit 0 install_term
assert_eq "satisfied: example-term 1.0.0" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count curl)"

# at-least keeps a newer self-updated binary; exact replaces it and backs
# the old one up.
make_release 1.2.0 1.2.0 "$DS_TEST_ROOT/newer.tar.gz"
tar -xzf "$DS_TEST_ROOT/newer.tar.gz" -C "$DS_TEST_ROOT"
cp "$DS_TEST_ROOT/example-term-1.2.0/example-term" "$dest"
newer_sha=$(sha256sum "$dest" | awk '{print $1}')
: >"$DS_CALL_LOG"
assert_exit 0 install_term
assert_eq "satisfied: example-term 1.2.0" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count curl)"
set_block '.policy = "exact"'
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-term (official-binary): example-term 1.0.0 exactly not found (found 1.2.0); run 'dotsteward rebuild --profile fresh --switch'" "$DS_STDERR"
assert_exit 0 install_term
assert_eq "installed: example-term 1.0.0" "$DS_STDOUT"
assert_eq "example-term 1.0.0" "$("$dest" --version)"
mapfile -t backups < <(find "$DOTSTEWARD_STATE_ROOT/backups" -type f)
assert_eq 1 "${#backups[@]}"
[[ ${backups[0]} =~ ^$DOTSTEWARD_STATE_ROOT/backups/[0-9]{8}T[0-9]{6}Z/files${dest}$ ]] ||
  ds_fail "unexpected backup path: ${backups[0]}"
assert_eq "$newer_sha" "$(sha256sum "${backups[0]}" | awk '{print $1}')"
assert_file_mode "${backups[0]}" 600
assert_file_mode "${backups[0]%%/files/*}" 700
set_block '.policy = "at-least"'

# A command found elsewhere on PATH counts (the installer's semantics).
rm -f "$dest"
ds_use_stubs example-term
ds_stub_set example-term version "example-term 1.1.0"
: >"$DS_CALL_LOG"
assert_exit 0 install_term
assert_eq "satisfied: example-term 1.1.0" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count curl)"
ds_stub_set example-term version "example-term 0.9.0"
assert_exit 0 install_term
assert_eq "installed: example-term 1.0.0" "$DS_STDOUT"

# A symlink at dest is fatal when an install is needed.
rm -f "$dest"
ln -s "$DS_TEST_ROOT/nowhere" "$dest"
: >"$DS_CALL_LOG"
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): refusing to replace a symlink or non-regular file: $dest" "$DS_STDERR"
assert_eq "0" "$(ds_call_count curl)"
rm -f "$dest"
mkdir -p "$dest"
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): refusing to replace a symlink or non-regular file: $dest" "$DS_STDERR"
rmdir "$dest"

# A previous file that cannot be backed up is never replaced. The stub on
# PATH reports 0.9.0, so an install is needed. Root reads any file, so the
# case only exists for a regular user.
if ((EUID != 0)); then
  printf 'previous example-term\n' >"$dest"
  previous_sha=$(sha256sum "$dest" | awk '{print $1}')
  chmod 0000 "$dest"
  : >"$DS_CALL_LOG"
  assert_exit 1 install_term
  assert_eq "[dotsteward] ERROR: example-term (official-binary): backup of $dest failed; nothing was replaced" "${DS_STDERR##*$'\n'}"
  assert_not_contains "$DS_STDERR" "backed up"
  chmod 0600 "$dest"
  assert_eq "$previous_sha" "$(sha256sum "$dest" | awk '{print $1}')"
  assert_eq "" "$(temp_dirs)"
  rm -f "$dest"
fi

# Download and archive failures leave dest alone and clean up.
lock_set agent_tools.example-term.sha256 "\"$(printf '0%.0s' {1..64})\""
assert_exit 1 install_term
assert_contains "$DS_STDERR" "SHA-256 mismatch: "
[[ ! -e $dest ]] || ds_fail "dest written after a failed download"
assert_eq "" "$(temp_dirs)"
pin_download agent_tools.example-term "$release" "$url" 1.0.0
make_release 1.0.0 1.0.0 "$DS_TEST_ROOT/odd.tar.gz" other-dir
pin_download agent_tools.example-term "$DS_TEST_ROOT/odd.tar.gz" "$url" 1.0.0
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): archive member example-term-1.0.0/example-term is not an executable regular file in $url" "$DS_STDERR"
[[ ! -e $dest ]] || ds_fail "dest written from a broken archive"
assert_eq "" "$(temp_dirs)"
set_block '.member = "../example-term"'
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): invalid archive member: ../example-term" "$DS_STDERR"
set_block '.member = "example-term-{version}/example-term"'

# The installed binary must report the pinned version.
make_release 1.0.0 0.5.0 "$DS_TEST_ROOT/liar.tar.gz"
pin_download agent_tools.example-term "$DS_TEST_ROOT/liar.tar.gz" "$url" 1.0.0
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): example-term 1.0.0 or newer not found after the install (found 0.5.0)" "$DS_STDERR"
rm -f "$dest"
pin_download agent_tools.example-term "$release" "$url" 1.0.0

# A plain binary asset (no archive) is installed as is; the pin may name its
# version "version".
raw=$DS_TEST_ROOT/example-term-1.0.0-x86_64-linux
tar -xzf "$release" -O example-term-1.0.0/example-term >"$raw"
raw_url=https://downloads.example.invalid/releases/example-term-1.0.0-x86_64-linux
pin_download agent_tools.example-term "$raw" "$raw_url" 1.0.0
lock_set agent_tools.example-term "$(jq '.agent_tools["example-term"] | .version = .minimum_version | del(.minimum_version)' "$methods_inst/versions.lock.json")"
assert_exit 0 install_term
assert_eq "installed: example-term 1.0.0" "$DS_STDOUT"
assert_file_mode "$dest" 755
assert_eq "example-term 1.0.0" "$("$dest" --version)"

# sigstore verification is refused rather than skipped.
rm -f "$dest"
set_block '.verify = "sha256+sigstore"'
: >"$DS_CALL_LOG"
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): verify = \"sha256+sigstore\" is not supported yet; use \"sha256\"" "$DS_STDERR"
assert_eq "0" "$(ds_call_count curl)"

# The lock entry must carry a version and the download fields.
set_block '.verify = "sha256"'
lock_set agent_tools.example-term '{"url": "https://downloads.example.invalid/x.tar.gz"}'
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): versions.lock.json agent_tools.example-term lacks minimum_version (or version)" "$DS_STDERR"
lock_set agent_tools.example-term '{"minimum_version": "1.0.0"}'
assert_exit 1 install_term
assert_eq "[dotsteward] ERROR: example-term (official-binary): versions.lock.json agent_tools.example-term lacks url, size or sha256" "$DS_STDERR"
