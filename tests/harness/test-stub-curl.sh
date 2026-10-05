# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# curl serves fixture files by URL and keeps the flag contract the framework
# relies on: --fail, --output, --proto, --write-out, --head, redirects,
# --max-time and curl's exit codes.

ds_use_stubs curl
deb=$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)
url=https://downloads.example.invalid/pool/example-app_1.2.3_amd64.deb
ds_curl_serve "$url" "$deb"

# The download_verified flag set.
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
  --connect-timeout 20 --retry 3 --retry-delay 5 --speed-limit 10240 --speed-time 60 \
  --output "$TMPDIR/out.deb" "$url"
cmp -s "$deb" "$TMPDIR/out.deb" || ds_fail "download differs from the fixture"
assert_call_count 1 curl

# Combined short flags, -o inside the cluster, -O, standard output.
curl -fsSLo "$TMPDIR/second.deb" "$url"
cmp -s "$deb" "$TMPDIR/second.deb" || ds_fail "combined flags download differs"
(cd "$TMPDIR" && curl -fsSLO "$url")
cmp -s "$deb" "$TMPDIR/example-app_1.2.3_amd64.deb" || ds_fail "-O download differs"
assert_eq "$(<"$deb")" "$(curl -fsSL "$url")"
mkdir -p "$TMPDIR/sub"
curl -fsS --create-dirs -o "$TMPDIR/sub/new/x.deb" "$url"
[[ -f $TMPDIR/sub/new/x.deb ]] || ds_fail "--create-dirs did not create the directory"

# --proto =https refuses other schemes with exit 1, before any transfer.
ds_curl_serve http://downloads.example.invalid/plain.txt "$deb"
assert_exit 1 curl --proto '=https' -fsS -o "$TMPDIR/plain" http://downloads.example.invalid/plain.txt
assert_contains "$DS_STDERR" 'Protocol "http" not supported'
[[ ! -e $TMPDIR/plain ]] || ds_fail "refused transfer wrote the output file"
assert_exit 1 curl --proto '=https' -fsS "file://$deb"
assert_exit 0 curl -fsS http://downloads.example.invalid/plain.txt
# Without --proto a file URL reads the local file.
assert_eq "$(<"$deb")" "$(curl -fsS "file://$deb")"

# Status codes: 404 for a missing path, 22 with --fail, body without it.
assert_exit 22 curl -fsS https://downloads.example.invalid/missing
assert_eq "curl: (22) The requested URL returned error: 404" "$DS_STDERR"
assert_exit 22 curl -fs https://downloads.example.invalid/missing
assert_eq "" "$DS_STDERR"
assert_exit 0 curl -sS https://downloads.example.invalid/missing
assert_eq "404" "$(curl -sS -o /dev/null -w '%{http_code}' https://downloads.example.invalid/missing)"
assert_eq "200 $(stat -c %s "$deb")" "$(curl -sS -o /dev/null -w '%{http_code} %{size_download}' "$url")"
assert_eq "$url" "$(curl -sS -o /dev/null -w '%{url_effective}\n' "$url")"
ds_curl_serve https://api.example.invalid/broken "$deb" 503
assert_exit 22 curl -fsS https://api.example.invalid/broken
assert_contains "$DS_STDERR" "error: 503"

# An unknown host fails like DNS resolution does.
assert_exit 6 curl -fsS https://unknown.example.invalid/x
assert_contains "$DS_STDERR" "Could not resolve host: unknown.example.invalid"

# Injected transport failures and timeouts.
ds_curl_fail https://slow.example.invalid/file 28 "Operation timed out after 1000 milliseconds"
assert_exit 28 curl -fsS -o "$TMPDIR/slow" https://slow.example.invalid/file
assert_eq "curl: (28) Operation timed out after 1000 milliseconds" "$DS_STDERR"
ds_curl_serve https://delay.example.invalid/file "$deb"
ds_curl_delay https://delay.example.invalid/file 3
start=$SECONDS
assert_exit 28 curl -fsS --max-time 1 https://delay.example.invalid/file
((SECONDS - start < 3)) || ds_fail "--max-time did not cut the delay short"

# Headers and redirects.
head_out=$(curl -fsSI "$url")
assert_contains "$head_out" "HTTP/2 200"
assert_contains "$head_out" "content-length: $(stat -c %s "$deb")"
ds_curl_redirect https://short.example.invalid/latest "$url"
assert_eq "302" "$(curl -sS -o /dev/null -w '%{http_code}' https://short.example.invalid/latest)"
assert_eq "$(<"$deb")" "$(curl -fsSL https://short.example.invalid/latest)"
assert_eq "$url" "$(curl -fsSL -o /dev/null -w '%{url_effective}' https://short.example.invalid/latest)"
curl -fsSL -D "$TMPDIR/headers" -o /dev/null "$url"
assert_contains "$(<"$TMPDIR/headers")" "HTTP/2 200"

# Query strings select their own file; a request header is accepted.
printf '{"page": 2}\n' >"$TMPDIR/page2.json"
ds_curl_serve 'https://api.example.invalid/items?page=2' "$TMPDIR/page2.json"
assert_eq '{"page": 2}' "$(curl -fsS -H 'Accept: application/json' 'https://api.example.invalid/items?page=2')"

# Usage errors.
assert_exit 2 curl --no-such-option "$url"
assert_contains "$DS_STDERR" "is unknown"
assert_exit 2 curl -fsS
assert_contains "$DS_STDERR" "no URL specified"
assert_exit 2 curl -o
assert_contains "$(curl --version)" "curl"
