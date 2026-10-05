# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# httpfix.py: a loopback HTTP server over a fixture directory, for adapters
# and downloads that use the real curl or Python's urllib.

root=$TMPDIR/www
mkdir -p "$root/api/repos" "$root/files"
cp "$(ds_fixture common/github/release-latest.json)" "$root/api/repos/latest.json"
printf 'payload\n' >"$root/files/data.txt"
printf '{"page": 2}\n' >"$root/api/items?page=2"
printf 'gone\n' >"$root/files/gone.txt"
printf '410\n' >"$root/files/gone.txt.status"
printf 'X-Example: yes\nContent-Type: application/vnd.example+json\n' >"$root/api/repos/latest.json.headers"
printf 'slow\n' >"$root/files/slow.txt"
printf '3\n' >"$root/files/slow.txt.delay"
printf '/files/data.txt\n' >"$root/files/moved.location"

ds_httpfix_start "$root"
[[ $DS_HTTPFIX_URL =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || ds_fail "unexpected base URL: $DS_HTTPFIX_URL"
kill -0 "$DS_HTTPFIX_PID" || ds_fail "server is not running"

get() { curl --noproxy '*' -sS "$@"; }

assert_eq payload "$(get -f "$DS_HTTPFIX_URL/files/data.txt")"
assert_json - '.tag_name == "v0.9.0"' <<<"$(get -f "$DS_HTTPFIX_URL/api/repos/latest.json")"
assert_eq '{"page": 2}' "$(get -f "$DS_HTTPFIX_URL/api/items?page=2")"
assert_eq 404 "$(get -o /dev/null -w '%{http_code}' "$DS_HTTPFIX_URL/files/missing.txt")"
assert_eq 404 "$(get -o /dev/null -w '%{http_code}' "$DS_HTTPFIX_URL/files/gone.txt.status")"
assert_eq 404 "$(get --path-as-is -o /dev/null -w '%{http_code}' "$DS_HTTPFIX_URL/files/../../etc/passwd")"
assert_eq 410 "$(get -o /dev/null -w '%{http_code}' "$DS_HTTPFIX_URL/files/gone.txt")"
headers=$(get -f -D - -o /dev/null "$DS_HTTPFIX_URL/api/repos/latest.json")
assert_contains "$headers" "X-Example: yes"
assert_contains "$headers" "Content-Type: application/vnd.example+json"
assert_contains "$(get -fI "$DS_HTTPFIX_URL/files/data.txt")" "Content-Length: 8"
assert_eq 302 "$(get -o /dev/null -w '%{http_code}' "$DS_HTTPFIX_URL/files/moved")"
assert_eq payload "$(get -fL "$DS_HTTPFIX_URL/files/moved")"
assert_exit 28 curl --noproxy '*' -fsS --max-time 1 "$DS_HTTPFIX_URL/files/slow.txt"

# Python's urllib (used by the Python engines) works against it as well.
assert_eq payload "$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1]).read().decode().strip())' "$DS_HTTPFIX_URL/files/data.txt")"

# Every request is logged as "METHOD PATH".
log=$(<"$DS_HTTPFIX_LOG")
assert_contains "$log" "GET /files/data.txt"
assert_contains "$log" "HEAD /files/data.txt"
assert_contains "$log" "GET /api/items?page=2"

# Stopping the server is explicit or happens when the test exits.
ds_httpfix_stop
if kill -0 "$DS_HTTPFIX_PID" 2>/dev/null; then ds_fail "server still running after stop"; fi
assert_exit 2 python3 "$DS_REPO_ROOT/tests/lib/httpfix.py"
assert_exit 2 python3 "$DS_REPO_ROOT/tests/lib/httpfix.py" "$TMPDIR/no-such-dir"
