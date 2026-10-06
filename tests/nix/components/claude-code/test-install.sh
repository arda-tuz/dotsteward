# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions and shell snippets in single quotes
# The claude-code install block, as the manifest renders it, driven through
# the official-binary method of the CLI (cli/lib/methods.sh) with the curl
# stub serving a stand-in for the native build at the seed's URL: the
# downloaded file is the executable itself (no archive), it lands at
# ~/.local/bin/claude as a regular file, and the version the native build
# prints ("<version> (Claude Code)") satisfies the pin. With policy
# at-least, a newer binary is kept (a newer pin installed by hand, or the
# launcher symlink of the vendor's native installer, ~/.local/bin/claude ->
# ~/.local/share/claude/versions/<version>); an older symlinked launcher is
# refused, never replaced. A claude elsewhere on PATH is hidden, so the
# machine running the tests does not decide them.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

# The manifest entry before the methods helpers change the working state.
entry=$(cc_json 'ccEntry (cc { }) "x86_64-linux"')
release=$(jq '.versions_lock.agent_tools["claude-code"]["linux-x64"]' "$cc_seed")
version=$(jq -r '.version' <<<"$release")
url=$(jq -r '.url' <<<"$release")

# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo curl
dest=$HOME/.local/bin/claude

# PATH without directories that hold a claude of the machine.
path=''
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -n $dir && ! -e $dir/claude ]] || continue
  path+=${path:+:}$dir
done
export PATH=$path
if command -v claude >/dev/null; then
  ds_fail "a claude is still on PATH: $(command -v claude)"
fi

# fake_claude VERSION OUT: an executable that prints what the native build
# prints for --version.
fake_claude() {
  printf '#!%s\nprintf "%%s (Claude Code)\\n" %q\n' "$BASH" "$1" >"$2"
  chmod 0755 "$2"
}

# The instance lock holds the seed's pin of the release platform, with the
# size and digest of the stand-in served at the seed's URL.
build=$DS_TEST_ROOT/claude
fake_claude "$version" "$build"
ds_curl_serve "$url" "$build"
lock_set agent_tools.claude-code.linux-x64 "$(jq --argjson size "$(stat -c %s -- "$build")" \
  --arg sha "$(sha256sum -- "$build" | awk '{print $1}')" '.size = $size | .sha256 = $sha' <<<"$release")"
add_component claude-code official-binary "$(jq -c '.install' <<<"$entry")"
manifest_edit '(.components[] | select(.name == "claude-code")) |= (.platforms = $e.platforms
  | .supported_methods = $e.supported_methods)' --argjson e "$entry"

install_claude() {
  in_methods_shell 'methods_official_binary_install claude-code >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
check_claude() {
  in_methods_shell 'methods_check claude-code fresh >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

# Nothing installed: the check fails with the rebuild hint.
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "claude-code (official-binary): claude $version or newer not found (found none)"

# Install: one verified HTTPS download, the file itself installed with mode
# 0755 as a regular file.
: >"$DS_CALL_LOG"
assert_exit 0 install_claude
assert_eq "installed: claude $version" "$DS_STDOUT"
[[ -f $dest && ! -L $dest ]] || ds_fail "$dest is not a regular file"
assert_file_mode "$dest" 755
cmp -s -- "$build" "$dest" || ds_fail "the installed file differs from the download"
assert_eq "1" "$(ds_call_count curl)"
assert_contains "$(ds_calls_of curl)" "--proto =https --tlsv1.2 "
assert_contains "$(ds_calls_of curl)" "$url"
assert_eq "0" "$(ds_call_count sudo)"

# Installed and checked again: nothing to do.
: >"$DS_CALL_LOG"
assert_exit 0 install_claude
assert_eq "satisfied: claude $version" "$DS_STDOUT"
assert_exit 0 check_claude
assert_eq "satisfied: claude $version" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count curl)"

# at-least: a newer regular file (a newer pin installed by hand) is kept.
# The vendor's updater never replaces a regular file at dest: it installs
# new versions under ~/.local/share/claude/versions/ (README.md).
fake_claude 9.0.0 "$dest"
assert_exit 0 install_claude
assert_eq "satisfied: claude 9.0.0" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count curl)"

# The native installer's layout: a launcher symlink into versions/. Newer
# than the pin, it satisfies the method as it is.
versions=$HOME/.local/share/claude/versions
mkdir -p "$versions"
rm -f -- "$dest"
fake_claude 9.0.0 "$versions/9.0.0"
ln -s "$versions/9.0.0" "$dest"
assert_exit 0 install_claude
assert_eq "satisfied: claude 9.0.0" "$DS_STDOUT"
assert_symlink_to "$dest" "$versions/9.0.0"

# Older than the pin, the symlinked launcher is refused, not replaced.
fake_claude 1.0.0 "$versions/1.0.0"
ln -sfn "$versions/1.0.0" "$dest"
assert_exit 1 install_claude
assert_contains "$DS_STDERR" "claude-code (official-binary): refusing to replace a symlink or non-regular file: $dest"
assert_symlink_to "$dest" "$versions/1.0.0"
assert_eq "0" "$(ds_call_count curl)"

# An older regular file is replaced by the pinned build (its predecessor is
# backed up).
rm -f -- "$dest"
fake_claude 1.0.0 "$dest"
assert_exit 0 install_claude
assert_eq "installed: claude $version" "$DS_STDOUT"
cmp -s -- "$build" "$dest" || ds_fail "the older binary was not replaced by the pinned build"
