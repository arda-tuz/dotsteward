# shellcheck shell=bash
# The built-in framework row: the tag of the instance's dotsteward input
# (flake.lock original.ref) against the newest release of its upstream
# (D17: a github owner/repo or a git URL), review when newer, manual for an
# input that is not a release tag or is a local path, error rows for a
# missing input or lock file and unknown input types.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
clear_latest
lock=$inst/flake.lock

set_original() {
  json_edit "$lock" "data['nodes']['dotsteward']['original'] = __import__('json').loads('''$1''')"
}

# gh fails: the newest stable tag of the upstream answers.
ds_stub_clear_routes gh
latest_gh_routes_without_framework() {
  ds_stub_route gh "api repos/example-org/example-skills/compare/*" --stdout-file "$latest_fixtures/gh/compare-skills.json"
  ds_stub_route gh "api repos/example-org/example-tool/releases/latest" --stdout-file "$latest_fixtures/gh/example-tool-release.json"
}
latest_gh_routes_without_framework
assert_exit 0 latest --out "$report"
assert_eq '{"id":"framework","kind":"framework","current":"v0.1.0","latest":"v0.2.0","status":"review","source":"https://github.com/example/dotsteward/releases","details":{"tag":"v0.2.0","upstream":"github:example/dotsteward"}}' \
  "$(row framework)"
assert_call_count 1 gh "api repos/example/dotsteward/releases/latest"

# Pinned to the newest release, or ahead of it: current.
set_original '{"owner": "example", "ref": "v0.2.0", "repo": "dotsteward", "type": "github"}'
assert_exit 0 latest --out "$report"
assert_eq '["v0.2.0","v0.2.0","current"]' "$(row framework '[.current, .latest, .status]')"
set_original '{"owner": "example", "ref": "v0.3.0", "repo": "dotsteward", "type": "github"}'
assert_exit 0 latest --out "$report"
assert_eq '["v0.3.0","v0.2.0","current"]' "$(row framework '[.current, .latest, .status]')"

# A git URL upstream: tags from git ls-remote, never the GitHub API.
: >"$DS_CALL_LOG"
set_original "{\"type\": \"git\", \"url\": \"file://$github/example/dotsteward\", \"ref\": \"refs/tags/v0.1.0\"}"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"framework\",\"kind\":\"framework\",\"current\":\"v0.1.0\",\"latest\":\"v0.2.0\",\"status\":\"review\",\"source\":\"file://$github/example/dotsteward\",\"details\":{\"tag\":\"v0.2.0\",\"upstream\":\"file://$github/example/dotsteward\"}}" \
  "$(row framework)"
assert_call_count 0 gh "api repos/example/dotsteward/*"

# Not a release tag, or a local checkout: manual.
set_original '{"owner": "example", "repo": "dotsteward", "type": "github"}'
assert_exit 0 latest --out "$report"
assert_eq '{"id":"framework","kind":"framework","current":null,"latest":null,"status":"manual","source":"https://github.com/example/dotsteward/releases","details":{"note":"the dotsteward input is not pinned to a release tag","upstream":"github:example/dotsteward"}}' \
  "$(row framework)"
set_original '{"owner": "example", "ref": "main", "repo": "dotsteward", "type": "github"}'
assert_exit 0 latest --out "$report"
assert_eq '["main","manual"]' "$(row framework '[.current, .status]')"
set_original '{"path": "/srv/dotsteward", "type": "path"}'
assert_exit 0 latest --out "$report"
assert_eq '{"id":"framework","kind":"framework","current":null,"latest":null,"status":"manual","source":"/srv/dotsteward","details":{"note":"the dotsteward input is a local path; it has no releases","upstream":"/srv/dotsteward"}}' \
  "$(row framework)"

# Broken shapes are error rows.
set_original '{"type": "tarball", "url": "https://example.invalid/dotsteward.tar.gz"}'
assert_exit 1 latest --out "$report"
assert_eq '["framework",null,null,"error"]' "$(row framework '[.kind, .current, .latest, .status]')"
assert_contains "$(row framework .details.error)" "unsupported dotsteward input type 'tarball'"

json_edit "$lock" 'del data["nodes"]["root"]["inputs"]["dotsteward"]'
assert_exit 1 latest --out "$report"
assert_contains "$(row framework .details.error)" "flake.lock has no dotsteward input"

rm -f -- "$lock"
assert_exit 1 latest --out "$report"
assert_contains "$(row framework .details.error)" "cannot read flake.lock"
assert_not_contains "$DS_STDERR" "Traceback"
