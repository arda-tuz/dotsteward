# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The base image: the committed pin is well formed, `fetch` downloads over
# HTTPS with the size checked before the digest, keeps a read-only verified
# copy, re-verifies it on every use and replaces a damaged one, refuses a
# malformed lock, and `pin` resolves the current release into a new lock.

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image 20990101

# The committed lock pins one Ubuntu 24.04 amd64 release image.
committed=$DS_REPO_ROOT/tests/vm/image.lock
[[ -f $committed ]] || ds_fail "tests/vm/image.lock is missing"
declare -A pin=()
while IFS= read -r line; do
  [[ -z $line || $line == '#'* ]] && continue
  [[ $line =~ ^([a-z0-9]+)=(.*)$ ]] || ds_fail "malformed line in image.lock: [$line]"
  [[ -z ${pin[${BASH_REMATCH[1]}]:-} ]] || ds_fail "duplicate key in image.lock: ${BASH_REMATCH[1]}"
  pin[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
done <"$committed"
assert_eq "release serial sha256 size url" "$(printf '%s\n' "${!pin[@]}" | sort | paste -sd ' ')"
assert_eq 24.04 "${pin[release]}"
[[ ${pin[serial]} =~ ^[0-9]{8}(\.[0-9]+)?$ ]] || ds_fail "bad serial: ${pin[serial]}"
assert_eq "https://cloud-images.ubuntu.com/releases/noble/release-${pin[serial]}/ubuntu-24.04-server-cloudimg-amd64.img" \
  "${pin[url]}"
[[ ${pin[size]} =~ ^[1-9][0-9]{8,10}$ ]] || ds_fail "bad size: ${pin[size]}"
[[ ${pin[sha256]} =~ ^[0-9a-f]{64}$ ]] || ds_fail "bad sha256: ${pin[sha256]}"
assert_exit 0 env DOTSTEWARD_VM_IMAGE_LOCK="$committed" "$VM_SH" plan
assert_contains "$DS_STDOUT" "ubuntu-24.04-server-cloudimg-amd64-${pin[serial]}.img"
assert_contains "$DS_STDOUT" 'not downloaded'

images=$DOTSTEWARD_VM_ROOT/images
image=$images/ubuntu-24.04-server-cloudimg-amd64-20990101.img

# First fetch downloads and verifies; the copy is read-only.
assert_exit 0 "$VM_SH" fetch
cmp -s "$VM_TEST_IMAGE_FILE" "$image" || ds_fail "fetched image differs from the source"
assert_file_mode "$image" 444
assert_call_count 1 curl
curl_call=$(ds_calls_of curl)
assert_contains "$curl_call" "--proto =https"
assert_contains "$curl_call" "$VM_TEST_IMAGE_URL"
assert_eq "$(basename "$image")" "$(ls -A "$images")" "only the image is left in the image directory"

# A cached image is verified, not downloaded again.
assert_exit 0 "$VM_SH" fetch
assert_contains "$DS_STDOUT" 'verified'
assert_call_count 1 curl

# A damaged cached copy is replaced.
chmod u+w "$image"
printf 'tampered' >>"$image"
chmod 0444 "$image"
assert_exit 0 "$VM_SH" fetch
assert_contains "$DS_STDERR" 'fails verification'
cmp -s "$VM_TEST_IMAGE_FILE" "$image" || ds_fail "damaged image was not replaced"
assert_file_mode "$image" 444
assert_call_count 2 curl

# Size is checked before the digest; a failed download leaves nothing.
write_lock() { # SERIAL SIZE SHA256 [URL]
  cat >"$DOTSTEWARD_VM_IMAGE_LOCK" <<EOF
release=24.04
serial=$1
url=${4:-$VM_TEST_IMAGE_URL}
size=$2
sha256=$3
EOF
}
write_lock 20990102 $((VM_TEST_IMAGE_SIZE + 1)) "$VM_TEST_IMAGE_SHA256"
assert_exit 1 "$VM_SH" fetch
assert_contains "$DS_STDERR" 'size mismatch'
assert_eq "$(basename "$image")" "$(ls -A "$images")" "a refused download left files behind"

write_lock 20990103 "$VM_TEST_IMAGE_SIZE" "$(printf '%064d' 0)"
assert_exit 1 "$VM_SH" fetch
assert_contains "$DS_STDERR" 'SHA-256 mismatch'
assert_eq "$(basename "$image")" "$(ls -A "$images")" "a refused download left files behind"

ds_curl_fail "$VM_TEST_IMAGE_URL" 22 'The requested URL returned error: 404'
write_lock 20990104 "$VM_TEST_IMAGE_SIZE" "$VM_TEST_IMAGE_SHA256"
assert_exit 1 "$VM_SH" fetch
assert_eq "$(basename "$image")" "$(ls -A "$images")" "a failed download left files behind"
ds_curl_serve "$VM_TEST_IMAGE_URL" "$VM_TEST_IMAGE_FILE"

# Malformed locks are refused before any download.
calls_before=$(ds_call_count curl)
good_sha=$VM_TEST_IMAGE_SHA256
bad_lock() { # DESCRIPTION, lock text on standard input
  cat >"$DOTSTEWARD_VM_IMAGE_LOCK"
  assert_exit 1 "$VM_SH" fetch
  assert_contains "$DS_STDERR" 'image lock' "$1"
}
bad_lock 'plain http' <<EOF
release=24.04
serial=20990105
url=http://images.example.invalid/x.img
size=10
sha256=$good_sha
EOF
bad_lock 'missing sha256' <<EOF
release=24.04
serial=20990105
url=$VM_TEST_IMAGE_URL
size=10
EOF
bad_lock 'duplicate key' <<EOF
release=24.04
serial=20990105
serial=20990106
url=$VM_TEST_IMAGE_URL
size=10
sha256=$good_sha
EOF
bad_lock 'unknown key' <<EOF
release=24.04
serial=20990105
url=$VM_TEST_IMAGE_URL
size=10
sha256=$good_sha
mirror=https://example.invalid
EOF
bad_lock 'short digest' <<EOF
release=24.04
serial=20990105
url=$VM_TEST_IMAGE_URL
size=10
sha256=abc
EOF
bad_lock 'size not a number' <<EOF
release=24.04
serial=20990105
url=$VM_TEST_IMAGE_URL
size=ten
sha256=$good_sha
EOF
bad_lock 'serial with a path' <<EOF
release=24.04
serial=../../etc
url=$VM_TEST_IMAGE_URL
size=10
sha256=$good_sha
EOF
rm -f "$DOTSTEWARD_VM_IMAGE_LOCK"
assert_exit 1 "$VM_SH" fetch
assert_contains "$DS_STDERR" 'image lock'
assert_call_count "$calls_before" curl

# pin resolves the current release from the image index.
index=https://images.example.invalid/noble
export DOTSTEWARD_VM_IMAGE_INDEX=$index
printf 'serial=20990202\norig_prefix=noble-server-cloudimg\nsuite=noble\nbuild_name=server\n' \
  >"$DS_TEST_ROOT/build-info.txt"
ds_curl_serve "$index/release/unpacked/build-info.txt" "$DS_TEST_ROOT/build-info.txt"
new_image=$DS_TEST_ROOT/new.img
printf 'next release image\n' >"$new_image"
new_sha=$(sha256sum "$new_image" | cut -d' ' -f1)
new_size=$(stat -c %s "$new_image")
{
  printf '%064d *ubuntu-24.04-server-cloudimg-arm64.img\n' 1
  printf '%s *ubuntu-24.04-server-cloudimg-amd64.img\n' "$new_sha"
  printf '%064d *ubuntu-24.04-server-cloudimg-amd64.img.manifest\n' 2
} >"$DS_TEST_ROOT/SHA256SUMS"
ds_curl_serve "$index/release-20990202/SHA256SUMS" "$DS_TEST_ROOT/SHA256SUMS"
ds_curl_serve "$index/release-20990202/ubuntu-24.04-server-cloudimg-amd64.img" "$new_image"

write_lock 20990101 "$VM_TEST_IMAGE_SIZE" "$VM_TEST_IMAGE_SHA256"
before=$(<"$DOTSTEWARD_VM_IMAGE_LOCK")
unset DOTSTEWARD_VM_PHASE
assert_exit 0 "$VM_SH" pin
for expected in 'release=24.04' 'serial=20990202' \
  "url=$index/release-20990202/ubuntu-24.04-server-cloudimg-amd64.img" \
  "size=$new_size" "sha256=$new_sha" '# Refresh with: tests/vm/vm.sh pin --write'; do
  assert_contains "$DS_STDOUT" "$expected"
done
assert_eq "$before" "$(<"$DOTSTEWARD_VM_IMAGE_LOCK")" "pin without --write changed the lock"
pinned=$DS_STDOUT
assert_exit 0 "$VM_SH" pin --write
assert_eq "$pinned" "$(<"$DOTSTEWARD_VM_IMAGE_LOCK")"
assert_exit 0 "$VM_SH" plan
assert_contains "$DS_STDOUT" 'ubuntu-24.04-server-cloudimg-amd64-20990202.img'
# Every pin request is HTTPS only.
while IFS= read -r line; do
  assert_contains "$line" '--proto =https' "pin request"
done < <(ds_calls_of curl | tail -n 6)

# pin refuses an index without the amd64 image.
printf '%064d *ubuntu-24.04-server-cloudimg-arm64.img\n' 1 >"$DS_TEST_ROOT/SHA256SUMS"
ds_curl_serve "$index/release-20990202/SHA256SUMS" "$DS_TEST_ROOT/SHA256SUMS"
assert_exit 1 "$VM_SH" pin --write
assert_contains "$DS_STDERR" 'ubuntu-24.04-server-cloudimg-amd64.img'
assert_eq "$pinned" "$(<"$DOTSTEWARD_VM_IMAGE_LOCK")" "a failed pin changed the lock"
