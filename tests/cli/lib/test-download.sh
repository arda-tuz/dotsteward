# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# download_verified URL DEST SIZE SHA256: today's curl flag contract (HTTPS
# only, TLS 1.2, fail on HTTP errors, follow redirects, retries, stall
# limits), a regular non-symlink destination, the exact size before the
# digest. cleanup_temp_dir: removes only real directories whose physical
# path is <physical TMPDIR>/dotsteward-*.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

ds_use_stubs curl
payload=$DS_TEST_ROOT/payload.bin
printf 'example-app package bytes\n' >"$payload"
size=$(stat -c %s "$payload")
sha=$(sha256sum "$payload" | awk '{print $1}')
url=https://downloads.example.invalid/example-app_1.2.3_amd64.deb
ds_curl_serve "$url" "$payload"

dest=$DS_TEST_ROOT/dl/example-app.deb
mkdir -p "$DS_TEST_ROOT/dl"
assert_exit 0 download_verified "$url" "$dest" "$size" "$sha"
cmp "$payload" "$dest"
assert_calls "curl --proto =https --tlsv1.2 --fail --location --silent --show-error --connect-timeout 20 --retry 3 --retry-delay 5 --speed-limit 10240 --speed-time 60 --output $dest $url"

# Redirects are followed.
: >"$DS_CALL_LOG"
ds_curl_redirect https://downloads.example.invalid/latest "$url"
rm -f "$dest"
assert_exit 0 download_verified https://downloads.example.invalid/latest "$dest" "$size" "$sha"
cmp "$payload" "$dest"

# The size is checked before the digest: a file with a wrong size and a
# wrong digest reports the size.
rm -f "$dest"
assert_exit 1 download_verified "$url" "$dest" $((size + 1)) "$(printf '0%.0s' {1..64})"
assert_eq "[dotsteward] ERROR: size mismatch: $dest (expected $((size + 1)) bytes, got $size)" "$DS_STDERR"
rm -f "$dest"
assert_exit 1 download_verified "$url" "$dest" "$size" "$(printf '0%.0s' {1..64})"
assert_eq "[dotsteward] ERROR: SHA-256 mismatch: $dest" "$DS_STDERR"

# Plain HTTP is refused by curl itself (--proto =https); curl's status
# propagates.
ds_curl_serve http://downloads.example.invalid/plain.deb "$payload"
rm -f "$dest"
assert_exit 1 download_verified http://downloads.example.invalid/plain.deb "$dest" "$size" "$sha"
assert_contains "$DS_STDERR" "Protocol \"http\" not supported"
[[ ! -e $dest ]] || ds_fail "an HTTP download was written"
# HTTP errors and network failures stop with curl's status.
ds_curl_serve https://downloads.example.invalid/gone.deb "$payload" 404
assert_exit 22 download_verified https://downloads.example.invalid/gone.deb "$dest" "$size" "$sha"
ds_curl_fail https://downloads.example.invalid/down.deb 6 "Could not resolve host"
assert_exit 6 download_verified https://downloads.example.invalid/down.deb "$dest" "$size" "$sha"

# The destination must end up a regular file, never a symlink.
ln -s "$DS_TEST_ROOT/elsewhere" "$DS_TEST_ROOT/dl/link.deb"
ds_stub_override curl <<'SH'
#!/usr/bin/env bash
# Writes nothing: the destination stays a dangling symlink.
exit 0
SH
assert_exit 1 download_verified "$url" "$DS_TEST_ROOT/dl/link.deb" "$size" "$sha"
assert_eq "[dotsteward] ERROR: downloaded file is not a regular file: $DS_TEST_ROOT/dl/link.deb" "$DS_STDERR"
rm -rf "${DS_STUB_STATE:?}/curl/override"

# curl itself is required.
no_curl() { PATH=/nonexistent download_verified "$url" "$dest" "$size" "$sha"; }
assert_exit 1 no_curl
assert_eq "[dotsteward] ERROR: required command not found: curl" "$DS_STDERR"

# cleanup_temp_dir
tmp_root=$(cd "$TMPDIR" && pwd -P)
made=$(mktemp -d "$TMPDIR/dotsteward-test-cleanup.XXXXXX")
mkdir -p "$made/nested"
touch "$made/nested/file"
assert_exit 0 cleanup_temp_dir "$made"
[[ ! -e $made ]] || ds_fail "temp dir not removed"
# Missing, empty and symlinked arguments are ignored silently.
assert_exit 0 cleanup_temp_dir ""
assert_exit 0 cleanup_temp_dir
assert_exit 0 cleanup_temp_dir "$TMPDIR/dotsteward-missing"
assert_eq "" "$DS_STDERR"
real=$(mktemp -d "$TMPDIR/dotsteward-real.XXXXXX")
ln -s "$real" "$TMPDIR/dotsteward-link"
assert_exit 0 cleanup_temp_dir "$TMPDIR/dotsteward-link"
[[ -d $real && -L $TMPDIR/dotsteward-link ]] || ds_fail "a symlink argument was followed"
# Anything outside the prefix is kept, with a warning.
mkdir -p "$TMPDIR/other-dir" "$DS_TEST_ROOT/dotsteward-outside" "$TMPDIR/not-dotsteward-x"
for keep in "$TMPDIR/other-dir" "$DS_TEST_ROOT/dotsteward-outside" "$TMPDIR/not-dotsteward-x" "$TMPDIR"; do
  assert_exit 0 cleanup_temp_dir "$keep"
  [[ -d $keep ]] || ds_fail "removed $keep"
  assert_eq "[dotsteward] WARNING: unsafe temporary directory not removed: $(cd "$keep" && pwd -P)" "$DS_STDERR"
done
# The physical path decides: a dotsteward-* name reached through a symlinked
# parent outside TMPDIR is kept.
mkdir -p "$DS_TEST_ROOT/outside/dotsteward-x"
ln -s "$DS_TEST_ROOT/outside" "$TMPDIR/via-link"
assert_exit 0 cleanup_temp_dir "$TMPDIR/via-link/dotsteward-x"
[[ -d $DS_TEST_ROOT/outside/dotsteward-x ]] || ds_fail "followed a symlinked parent"
# A symlinked TMPDIR still works (the physical paths are compared).
ln -s "$TMPDIR" "$DS_TEST_ROOT/tmp-link"
made=$(TMPDIR=$DS_TEST_ROOT/tmp-link mktemp -d "$DS_TEST_ROOT/tmp-link/dotsteward-x.XXXXXX")
TMPDIR=$DS_TEST_ROOT/tmp-link cleanup_temp_dir "$made"
[[ ! -e $made && $tmp_root == "$(cd "$TMPDIR" && pwd -P)" ]] || ds_fail "temp dir below a symlinked TMPDIR not removed"
