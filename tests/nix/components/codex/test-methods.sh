# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The codex install methods end to end: an instance that
# enables codex is evaluated by lib.mkInstance, its manifest mirror is
# written, and the framework CLI installs and checks the component.
# official-binary: `agents install` downloads the pinned release archive of
# the platform, verifies size and SHA-256, installs its member as
# ~/.local/bin/codex and reads the version it prints; at-least keeps a newer
# binary. external: nothing is installed, the check wants codex on PATH.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs curl

dest=$HOME/.local/bin/codex
version=$(jq -r '.versions_lock.agent_tools.codex.linux.version' "$codex_seed")
url=$(jq -r '.versions_lock.agent_tools.codex.linux.url' "$codex_seed")

# make_release REPORTED OUT: an archive laid out like the official Linux
# release: one member, codex-x86_64-unknown-linux-musl, which prints
# "codex-cli REPORTED".
make_release() {
  local dir
  dir=$(mktemp -d "$DS_TEST_ROOT/release.XXXXXX")
  printf '#!%s\nprintf "codex-cli %%s\\n" %q\n' "$BASH" "$1" >"$dir/codex-x86_64-unknown-linux-musl"
  chmod 0755 "$dir/codex-x86_64-unknown-linux-musl"
  tar -czf "$2" -C "$dir" codex-x86_64-unknown-linux-musl
  rm -rf -- "$dir"
}

# serve_release DIR FILE: the curl stub serves FILE at the seed's URL and
# the instance pin describes it (the seed's version and URL, FILE's size and
# digest).
serve_release() {
  local size sha
  ds_curl_serve "$url" "$2"
  size=$(stat -c %s -- "$2")
  sha=$(sha256sum -- "$2" | awk '{print $1}')
  codex_lock_set "$1" agent_tools.codex.linux "$(jq -n --arg v "$version" --arg u "$url" \
    --argjson s "$size" --arg h "$sha" '{ version: $v, url: $u, size: $s, sha256: $h }')"
}

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

# --- official-binary (the default) ------------------------------------------------

inst=$(codex_instance release)
make_release "$version" "$DS_TEST_ROOT/codex.tar.gz"
serve_release "$inst" "$DS_TEST_ROOT/codex.tar.gz"
codex_mirror "$inst"

# Before the install: both checks fail with the rebuild hint, nothing changes.
before=$(codex_home_state)
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex (official-binary): codex $version or newer not found (found none); run 'dotsteward rebuild --profile workstation --switch'"
assert_exit 1 codex_cli "$inst" install --check-only --profile workstation
assert_contains "$DS_STDERR" "codex (official-binary): codex $version or newer not found (found none)"
assert_eq "$before" "$(codex_home_state)" "checks change nothing"
assert_call_count 0 curl

# The install: verified download, the member installed 0755 at the
# destination, the legacy skill root created as a directory.
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex (official-binary): downloading $url"
assert_file_mode "$dest" 0755
assert_eq "codex-cli $version" "$("$dest" --version)"
[[ -d $HOME/.codex/skills && ! -L $HOME/.codex/skills ]] || ds_fail "$HOME/.codex/skills is not a directory"
assert_call_count 1 curl
assert_exit 0 agents check
assert_exit 0 codex_cli "$inst" install --check-only --profile workstation
assert_contains "$DS_STDOUT" "codex (official-binary): satisfied"
assert_exit 0 agents install
assert_call_count 1 curl

# at-least: a newer binary (updated by hand) is kept, an older one replaced.
printf '#!%s\necho "codex-cli 999.0.0"\n' "$BASH" >"$dest"
assert_exit 0 agents install
assert_eq "codex-cli 999.0.0" "$("$dest" --version)"
assert_call_count 1 curl
printf '#!%s\necho "codex-cli 0.0.1"\n' "$BASH" >"$dest"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $version or newer not found (found 0.0.1)"
assert_exit 0 agents install
assert_eq "codex-cli $version" "$("$dest" --version)"
assert_call_count 2 curl

# A release whose bytes differ from the pin is refused before anything is
# installed: a different size, then the same size with other bytes.
rm -f -- "$dest"
make_release "$version-tampered" "$DS_TEST_ROOT/tampered.tar.gz"
ds_curl_serve "$url" "$DS_TEST_ROOT/tampered.tar.gz"
assert_exit 1 agents install
assert_contains "$DS_STDOUT" "codex (official-binary): downloading $url"
assert_contains "$DS_STDERR" "size mismatch: "
[[ ! -e $dest ]] || ds_fail "a tampered release was installed"
cp -- "$DS_TEST_ROOT/codex.tar.gz" "$DS_TEST_ROOT/flipped.tar.gz"
last=$(($(stat -c %s -- "$DS_TEST_ROOT/flipped.tar.gz") - 1))
printf '\377' | dd of="$DS_TEST_ROOT/flipped.tar.gz" bs=1 seek="$last" conv=notrunc status=none
ds_curl_serve "$url" "$DS_TEST_ROOT/flipped.tar.gz"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "SHA-256 mismatch: "
[[ ! -e $dest ]] || ds_fail "a release with a wrong digest was installed"

# --- external ---------------------------------------------------------------------

inst=$(codex_instance external '["x86_64-linux"]' 'method = "external"')
codex_mirror "$inst"
assert_exit 1 codex_cli "$inst" install --check-only --profile workstation
assert_contains "$DS_STDERR" "codex (external): command codex not found"
calls=$(ds_call_count curl)
assert_exit 0 agents install
assert_call_count "$calls" curl
[[ ! -e $dest ]] || ds_fail "external installed a binary"
ds_use_stubs codex
assert_exit 0 codex_cli "$inst" install --check-only --profile workstation
assert_contains "$DS_STDOUT" "codex (external): satisfied: codex found"
