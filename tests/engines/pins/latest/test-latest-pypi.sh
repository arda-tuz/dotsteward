# shellcheck shell=bash
# The pypi adapter against the loopback server: the newest final release
# of a package's JSON API (pre-releases, yanked releases and releases
# without files are skipped), a newer major version as review, holdbacks,
# the package name from another lock field, and format changes or a
# missing package as error rows with the row id, never a silent pass.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
url=$DS_HTTPFIX_URL

# releases JSON: a JSON object of version -> files, written as the API's
# answer for example-app.
serve_releases() {
  mkdir -p "$www/pypi/example-app"
  jq -n --argjson releases "$1" '{ info: { name: "example-app", version: "0.0.0" }, releases: $releases }' \
    >"$www/pypi/example-app/json"
}

file() {
  jq -cn --argjson yanked "${1:-false}" --arg requires "${2:->=3.9}" \
    '{ filename: "example_app-x-py3-none-any.whl", yanked: $yanked, requires_python: $requires }'
}

json_edit "$versions" 'data["pypi"] = {"example-app": {"version": "1.0.0", "distribution": "example-app"}}'
declaration="{\"component\":\"example-app\",\"id\":\"pypi.example-app\",\"adapter\":\"pypi\",\"package\":\"example-app\",\"index\":\"$url/pypi\"}"
declare_latest "$declaration"

serve_releases "{
  \"0.9.0\": [$(file)], \"1.0.0\": [$(file)], \"1.3.0\": [$(file)],
  \"1.4.0\": [$(file false '>=3.10')], \"1.5.0\": [$(file true)], \"1.6.0\": [],
  \"1.7.0rc1\": [$(file)], \"1.7.0.dev2\": [$(file)], \"1.7.0a1\": [$(file)]
}"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"pypi.example-app\",\"kind\":\"pypi\",\"current\":\"1.0.0\",\"latest\":\"1.4.0\",\"status\":\"update\",\"source\":\"$url/pypi/example-app\",\"details\":{\"requires_python\":\">=3.10\"}}" \
  "$(row pypi.example-app)"
assert_contains "$(<"$DS_HTTPFIX_LOG")" "GET /pypi/example-app/json"$'\n'

# A newer major version is a review; the current release is current.
serve_releases "{ \"1.0.0\": [$(file)], \"2.0.0\": [$(file)] }"
assert_exit 0 latest --out "$report"
assert_eq '["2.0.0","review"]' "$(row pypi.example-app '[.latest, .status]')"
serve_releases "{ \"0.9.0\": [$(file)], \"1.0.0\": [$(file)] }"
assert_exit 0 latest --out "$report"
assert_eq '["1.0.0","current"]' "$(row pypi.example-app '[.latest, .status]')"

# A holdback.
serve_releases "{ \"1.0.0\": [$(file)], \"1.1.0\": [$(file)] }"
json_edit "$versions" 'data["pypi"]["example-app"]["holdback_reason"] = "1.1 needs a newer interpreter"'
assert_exit 0 latest --out "$report"
assert_eq '["held","1.1 needs a newer interpreter"]' "$(row pypi.example-app '[.status, .details.note]')"
json_edit "$versions" 'del data["pypi"]["example-app"]["holdback_reason"]'

# The package name from another lock field, and a declared source.
declare_latest "{\"component\":\"example-app\",\"id\":\"pypi.example-app\",\"adapter\":\"pypi\",\"package_at\":\".distribution\",\"index\":\"$url/pypi\",\"source\":\"https://example.org/example-app\"}"
assert_exit 0 latest --out "$report"
assert_eq '["1.1.0","update","https://example.org/example-app"]' "$(row pypi.example-app '[.latest, .status, .source]')"
declare_latest "$declaration"

# No final release with files, a body without releases and a missing
# package are error rows with the row id.
serve_releases "{ \"1.5.0\": [$(file true)], \"2.0.0b1\": [$(file)] }"
assert_exit 1 latest --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
assert_eq '["pypi","1.0.0",null,"error"]' "$(row pypi.example-app '[.kind, .current, .latest, .status]')"
assert_contains "$(row pypi.example-app .details.error)" "example-app has no final release with files"
printf '{"info": {}}\n' >"$www/pypi/example-app/json"
assert_exit 1 latest --out "$report"
assert_contains "$(row pypi.example-app .details.error)" "the index answered no releases for example-app"
rm -rf -- "$www/pypi/example-app"
assert_exit 1 latest --out "$report"
assert_eq '["pypi","error"]' "$(row pypi.example-app '[.kind, .status]')"
assert_contains "$(row pypi.example-app .details.error)" "example-app is not on the index ($url/pypi/example-app/json)"

# Invalid declarations.
declare_latest '{"component":"example-app","id":"pypi.example-app","adapter":"pypi"}'
: >"$DS_HTTPFIX_LOG"
assert_exit 2 latest --out "$report"
assert_contains "$DS_STDERR" "example-app/pypi.example-app: invalid declaration: one of 'package' and 'package_at' is required"
assert_eq "" "$(<"$DS_HTTPFIX_LOG")"
declare_latest "{\"component\":\"example-app\",\"id\":\"pypi.example-app\",\"adapter\":\"pypi\",\"package\":\"example-app\",\"index\":\"not a url\"}"
assert_exit 2 latest --out "$report"
assert_contains "$DS_STDERR" "field 'index': expected a URL"
