# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# sha256_file, directory_sha256 (today's algorithm: sorted sha256sum lines of
# the regular files, __pycache__ and *.pyc excluded, symlinks not followed),
# lock_value and pin_value/desktop_pin, install_asset.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

empty_sha=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
: >"$DS_TEST_ROOT/empty"
assert_eq "$empty_sha" "$(sha256_file "$DS_TEST_ROOT/empty")"
printf 'abc' >"$DS_TEST_ROOT/-abc"
(cd "$DS_TEST_ROOT" && assert_eq ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_file -abc)")
assert_exit 1 sha256_file "$DS_TEST_ROOT/missing"

# directory_sha256: the fixture skill tree has a known digest; bytecode,
# empty directories and symlinks do not count, file names and bytes do.
tree=$DS_TEST_ROOT/tree
ds_fixture_skill_tree "$tree"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(directory_sha256 "$tree")"
expected=$( (cd "$tree" && find . \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' -print0 \) |
  LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | awk '{print $1}')
assert_eq "$expected" "$(directory_sha256 "$tree")" "same algorithm as today"
printf 'more bytecode' >"$tree/__pycache__/other.pyc"
mkdir -p "$tree/nested/__pycache__" "$tree/another-empty"
printf 'x' >"$tree/nested/__pycache__/ignored.txt"
ln -s SKILL.md "$tree/second-link"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(directory_sha256 "$tree")" "ignored entries"
printf 'changed\n' >>"$tree/references/guide.md"
[[ $(directory_sha256 "$tree") != "$DS_FIXTURE_SKILL_TREE_SHA256" ]] || ds_fail "content change not detected"
mkdir -p "$DS_TEST_ROOT/empty-dir"
assert_eq "$empty_sha" "$(directory_sha256 "$DS_TEST_ROOT/empty-dir")" "an empty tree hashes the empty listing"
assert_exit 1 directory_sha256 "$DS_TEST_ROOT/missing-dir"
assert_eq "[dotsteward] ERROR: directory digest source not found: $DS_TEST_ROOT/missing-dir" "$DS_STDERR"
# The working directory of the caller is unchanged.
before=$PWD
directory_sha256 "$tree" >/dev/null
assert_eq "$before" "$PWD"

# lock_value QUERY [FILE]: the instance versions lock by default
# (DOTSTEWARD_INSTANCE + pins.versions_lock when loaded).
instance=$DS_TEST_ROOT/instance
mkdir -p "$instance/locks"
cat >"$instance/versions.lock.json" <<'JSON'
{
  "nix": { "version": "2.35.2" },
  "flag": false,
  "desktop_packages": {
    "example-app": { "minimum_version": "1.2.3", "url": "https://example.invalid/app.deb", "size": 42 }
  }
}
JSON
printf '{"nix":{"version":"9.9.9"}}\n' >"$instance/locks/other.json"
assert_exit 1 lock_value .nix.version
assert_eq "[dotsteward] ERROR: lock_value: no lock file (DOTSTEWARD_INSTANCE is not set)" "$DS_STDERR"
export DOTSTEWARD_INSTANCE=$instance
assert_eq 2.35.2 "$(lock_value .nix.version)"
assert_eq 9.9.9 "$(lock_value .nix.version "$instance/locks/other.json")"
assert_eq 9.9.9 "$(DS_PINS_VERSIONS_LOCK=locks/other.json lock_value .nix.version)"
assert_eq 42 "$(lock_value '.desktop_packages["example-app"].size')"
for query in .missing .flag '.nix.version | select(false)'; do
  assert_exit 1 lock_value "$query"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read lock value: $query"
done
assert_exit 1 lock_value .nix.version "$instance/missing.json"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read lock value: .nix.version"

# pin_value PACKAGE FIELD and its legacy name desktop_pin.
assert_eq 1.2.3 "$(pin_value example-app minimum_version)"
assert_eq https://example.invalid/app.deb "$(desktop_pin example-app url)"
assert_exit 1 pin_value example-app sha256
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read desktop package pin: example-app sha256"
assert_exit 1 desktop_pin example-term url
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read desktop package pin: example-term url"
# A package name is data, never jq syntax.
assert_exit 1 pin_value '"] | halt_error(3) | ["' url
assert_contains "$DS_STDERR" "cannot read desktop package pin"

# install_asset SOURCE DEST MODE SHA256: verified copy with a mode; parents
# are created; a wrong source digest stops before anything is written.
printf 'asset bytes\n' >"$DS_TEST_ROOT/asset.png"
asset_sha=$(sha256sum "$DS_TEST_ROOT/asset.png" | awk '{print $1}')
assert_exit 0 install_asset "$DS_TEST_ROOT/asset.png" "$HOME/.local/share/backgrounds/a/asset.png" 0644 "$asset_sha"
cmp "$DS_TEST_ROOT/asset.png" "$HOME/.local/share/backgrounds/a/asset.png"
assert_file_mode "$HOME/.local/share/backgrounds/a/asset.png" 644
# Re-installing replaces the file and its mode (also a symlink in the way).
rm "$HOME/.local/share/backgrounds/a/asset.png"
ln -s /nonexistent "$HOME/.local/share/backgrounds/a/asset.png"
assert_exit 0 install_asset "$DS_TEST_ROOT/asset.png" "$HOME/.local/share/backgrounds/a/asset.png" 0600 "$asset_sha"
[[ -f $HOME/.local/share/backgrounds/a/asset.png && ! -L $HOME/.local/share/backgrounds/a/asset.png ]] ||
  ds_fail "install_asset left a symlink"
assert_file_mode "$HOME/.local/share/backgrounds/a/asset.png" 600
assert_exit 1 install_asset "$DS_TEST_ROOT/asset.png" "$HOME/elsewhere/asset.png" 0644 "$empty_sha"
assert_eq "[dotsteward] ERROR: asset digest mismatch: $DS_TEST_ROOT/asset.png" "$DS_STDERR"
[[ ! -e $HOME/elsewhere ]] || ds_fail "install_asset wrote after a digest mismatch"
assert_exit 1 install_asset "$DS_TEST_ROOT/missing.png" "$HOME/elsewhere/asset.png" 0644 "$asset_sha"
assert_eq "[dotsteward] ERROR: asset not found: $DS_TEST_ROOT/missing.png" "$DS_STDERR"
assert_exit 1 install_asset "$DS_TEST_ROOT/asset.png" "$HOME/elsewhere/asset.png" 644x "$asset_sha"
assert_eq "[dotsteward] ERROR: install_asset: invalid mode: 644x" "$DS_STDERR"
