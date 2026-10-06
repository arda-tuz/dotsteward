# shellcheck shell=bash
# Failure handling of `pins latest`: invalid declarations stop the command
# with exit 2 before any upstream query; a failing query becomes a job-<n>
# error row (message cut at 300 characters) while every other row is still
# reported; lock values a declaration needs but cannot find become an error
# row with the row id; usage errors and unwritable reports are exit 2.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
url=$DS_HTTPFIX_URL
label=.dotsteward/manifest.x86_64-linux.json

# invalid DECLARATION... NEEDLE: exit 2, the needle on stderr, no query.
invalid() {
  local needle=${*: -1}
  declare_latest "${@:1:$#-1}"
  : >"$DS_CALL_LOG"
  : >"$DS_HTTPFIX_LOG"
  rm -f -- "$report"
  assert_exit 2 latest --out "$report"
  assert_contains "$DS_STDERR" "[pins] ERROR: " "error prefix"
  assert_contains "$DS_STDERR" "$needle"
  assert_not_contains "$DS_STDERR" "Traceback"
  assert_eq "" "$DS_STDOUT" "stdout of an invalid declaration"
  assert_calls
  assert_eq "" "$(<"$DS_HTTPFIX_LOG")" "HTTP requests before validation"
  [[ ! -e $report ]] || ds_fail "a report was written for an invalid declaration"
}

invalid '{"component":"example-x","id":"example.row","adapter":"scrape"}' \
  "$label: latest 1 (component example-x): unknown adapter 'scrape'"
invalid '{"id":"example.row","adapter":"npm","package":"example-dep"}' \
  "$label: latest 1: missing component"
invalid '{"component":"example-x","adapter":"npm","package":"example-dep"}' \
  "example-x/latest 1: invalid declaration: missing field 'id'"
invalid '{"component":"example-x","id":"example.row","adapter":"npm","package":"example-dep","example_field":1}' \
  "example-x/example.row: invalid declaration: unknown field 'example_field'"
invalid "{\"component\":\"example-x\",\"id\":\"example.row\",\"adapter\":\"apt-index\",\"base\":\"$url/apt\"}" \
  "example-x/example.row: invalid declaration: missing field 'package'"
invalid '{"component":"example-x","id":"example.row","adapter":"npm"}' \
  "example-x/example.row: invalid declaration: one of 'package' and 'package_at' is required"
invalid '{"component":"example-x","id":"example.row","adapter":"npm","package":"a","current":"1.0","current_field":"version"}' \
  "example-x/example.row: invalid declaration: 'current' and 'current_field' exclude each other"
invalid '{"component":"example-x","id":"example.row","adapter":"npm","package":"a","only_with":"version"}' \
  "example-x/example.row: invalid declaration: 'only_with' needs 'for_each'"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":"example-{arch}.tar.gz"}' \
  "example-x/example.row: invalid declaration: field 'asset': unknown placeholder {arch} (known: {version}, {tag})"
# Per-platform asset maps: not empty, known systems or platforms only, each
# platform once, every value a release template.
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":{}}' \
  "example-x/example.row: invalid declaration: field 'asset': expected a template string or a non-empty object of templates per system or platform, found {}"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":{"x86_64-linux":"a.tar.gz","riscv64-linux":"b.tar.gz"}}' \
  "example-x/example.row: invalid declaration: field 'asset': unknown system or platform 'riscv64-linux' (known: x86_64-linux, aarch64-darwin, linux, darwin)"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":{"linux":"a.tar.gz","x86_64-linux":"b.tar.gz"}}' \
  "example-x/example.row: invalid declaration: field 'asset': 'linux' and 'x86_64-linux' name the same platform"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":{"darwin":"example-{arch}.zip"}}' \
  "example-x/example.row: invalid declaration: field 'asset': darwin: unknown placeholder {arch} (known: {version}, {tag})"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","asset":{"darwin":7}}' \
  "example-x/example.row: invalid declaration: field 'asset': darwin: expected a non-empty template string, found 7"
invalid '{"component":"example-x","id":"example.row","adapter":"github-release","repo":"example-org/example-term","at":"flake_inputs[x"}' \
  "example-x/example.row: invalid declaration: field 'at': invalid lock path"
invalid '{"component":"example-x","id":"example.row","adapter":"git-compare","repo":"example-org/example-watch","revision_at":"example_watch.inspected_revision","watched":["("]}' \
  "example-x/example.row: invalid declaration: field 'watched': invalid regular expression '('"
invalid '{"component":"example-x","id":"example.row","adapter":"git-compare","repo":"example-org/example-watch","repo_at":"example_watch.source","revision_at":"example_watch.inspected_revision","watched":["x"]}' \
  "example-x/example.row: invalid declaration: 'repo' and 'repo_at' exclude each other"
invalid "{\"component\":\"example-x\",\"id\":\"example.row\",\"adapter\":\"official-manifest\",\"manifest_url\":\"$url/bin/latest.json\"}" \
  "example-x/example.row: invalid declaration: one of 'version_url' and 'version_field' is required"
invalid "{\"component\":\"example-x\",\"id\":\"example.row\",\"adapter\":\"official-manifest\",\"manifest_url\":\"$url/bin/{version}/manifest.json\",\"version_field\":\"version\"}" \
  "example-x/example.row: invalid declaration: 'manifest_url' uses {version}, which needs 'version_url'"
invalid "{\"component\":\"example-x\",\"id\":\"example.row\",\"adapter\":\"deb-url\",\"latest_url\":\"$url/x\",\"version_pattern\":\"[0-9]+\"}" \
  "example-x/example.row: invalid declaration: field 'version_pattern': needs one group or a group named version"
invalid '{"component":"example-x","id":"example.row","adapter":"follows","follows":"x","optional":"yes"}' \
  "example-x/example.row: invalid declaration: field 'optional': expected true or false"
invalid '{"component":"example-x","id":"framework","adapter":"framework"}' \
  "example-x/framework: invalid declaration: adapter 'framework' is built in; it is not declared"
invalid '{"component":"example-x","id":"skills.example","adapter":"skill-source"}' \
  "example-x/skills.example: invalid declaration: adapter 'skill-source' is built in; it is not declared"
invalid '{"component":"example-x","id":"example.row","adapter":"npm","package":"a"}' \
  '{"component":"example-y","id":"example.row","adapter":"follows","follows":"x","current":"1"}' \
  "duplicate latest row id 'example.row' (components example-x and example-y)"
# Duplicates after for_each expansion are caught too.
invalid '{"component":"example-x","id":"npm.@example/example-app","adapter":"npm","package":"a","current":"1"}' \
  '{"component":"example-y","id":"npm.{key}","adapter":"npm","for_each":"skills:npm_tools","package":"{key}","current":"{value}"}' \
  "duplicate latest row id 'npm.@example/example-app' (components example-x and example-y)"

# The manifest mirror itself.
json_edit "$manifest" 'data["pins"]["latest"] = {"not": "a list"}'
assert_exit 2 latest
assert_contains "$DS_STDERR" "[pins] ERROR: $label: pins.latest is not a list"
rm -f -- "$manifest"
assert_exit 2 latest
assert_contains "$DS_STDERR" "[pins] ERROR: missing manifest mirror $label; run 'dotsteward sync'"
cp -- "$latest_fixtures/instance/.dotsteward/manifest.x86_64-linux.json" "$manifest"
sed -i "s|@HTTPFIX@|$url|g" "$manifest"

# An unreadable versions lock.
cp -- "$versions" "$DS_TEST_ROOT/versions.saved"
printf '{ not json\n' >"$versions"
assert_exit 2 latest
assert_contains "$DS_STDERR" "[pins] ERROR: cannot read versions.lock.json"
cp -- "$DS_TEST_ROOT/versions.saved" "$versions"

# --- error rows -----------------------------------------------------------------

# A query that fails becomes job-<n>: kind error, the message cut at 300
# characters, the ids it was meant to answer; the other rows are reported
# and the exit status is 1.
long=example-org/$(printf 'x%.0s' $(seq 1 400))
declare_latest \
  "{\"component\":\"example-x\",\"id\":\"agent_tools.example-long\",\"adapter\":\"github-release\",\"repo\":\"$long\",\"at\":\"agent_tools.example-release\"}" \
  "{\"component\":\"example-y\",\"id\":\"npm.example-gone\",\"adapter\":\"npm\",\"package\":\"example-gone\",\"current\":\"1.0.0\",\"registry\":\"$url/npm\"}" \
  "{\"component\":\"example-app\",\"id\":\"desktop_packages.example-app\",\"adapter\":\"apt-index\",\"base\":\"$url/apt\",\"package\":\"example-app\"}"
assert_exit 1 latest --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
jobs=$(jq -c '[.items[] | select(.id | startswith("job-"))]' "$report")
assert_eq 2 "$(jq length <<<"$jobs")" "two failed jobs"
assert_json - 'all(.[]; .kind == "error" and .status == "error" and .current == null and .latest == null and .source == "" and (.id | test("^job-[0-9]+$")))' <<<"$jobs"
assert_json - 'all(.[]; (.details | keys_unsorted) == ["error", "ids"])' <<<"$jobs"
assert_json - '[.[].details.ids] | sort == [["agent_tools.example-long"], ["npm.example-gone"]]' <<<"$jobs"
long_error=$(jq -r '.[] | select(.details.ids == ["agent_tools.example-long"]) | .details.error' <<<"$jobs")
assert_eq 300 "${#long_error}" "error message length"
assert_contains "$(jq -r '.[] | select(.details.ids == ["npm.example-gone"]) | .details.error' <<<"$jobs")" "404"
assert_eq '"update"' "$(row desktop_packages.example-app .status)"
assert_eq '"review"' "$(row framework .status)"
assert_contains "$DS_STDOUT" $'\nerror    job-'
# Error rows sort after manual rows and before current rows.
order=$(jq -r '.items[].status' "$report" | uniq | tr '\n' ' ')
assert_eq "update review manual error current " "$order"

# Lock values the declaration needs but the lock lacks: an error row with
# the row id (no query is made for it).
declare_latest \
  '{"component":"example-x","id":"agent_tools.example-absent","adapter":"github-release","repo":"example-org/example-term"}' \
  '{"component":"example-x","id":"agent_tools.example-plain","adapter":"npm","at":"agent_tools.example-cli","package_at":".missing_field"}' \
  '{"component":"example-x","id":"npm.{key}","adapter":"npm","for_each":"agent_tools.absent_section","package":"{key}"}' \
  '{"component":"example-x","id":"example_watch","adapter":"git-compare","at":"example_watch","repo_at":".source","revision_at":".absent_revision","watched":["x"]}'
: >"$DS_CALL_LOG"
assert_exit 1 latest --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
assert_eq '["github-release",null,null,"error"]' "$(row agent_tools.example-absent '[.kind, .current, .latest, .status]')"
assert_contains "$(row agent_tools.example-absent .details.error)" "no current version"
assert_contains "$(row agent_tools.example-plain .details.error)" "agent_tools.example-cli.missing_field"
assert_contains "$(row "npm.{key}" .details.error)" "agent_tools.absent_section"
assert_contains "$(row example_watch .details.error)" "example_watch.absent_revision"
assert_call_count 0 gh "api repos/example-org/example-watch/*"

# --- usage ---------------------------------------------------------------------

clear_latest
assert_exit 2 latest --jobs 0
assert_contains "$DS_STDERR" "must be at least 1"
assert_exit 2 latest --jobs many
assert_contains "$DS_STDERR" "not an integer"
assert_exit 2 latest --out "$DS_TEST_ROOT/missing/report.json"
assert_contains "$DS_STDERR" "[pins] ERROR: cannot write $DS_TEST_ROOT/missing/report.json: No such file or directory"
assert_not_contains "$DS_STDERR" "Traceback"
