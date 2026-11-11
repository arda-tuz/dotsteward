# shellcheck shell=bash
# The built-in framework row: the tag of the instance's dotsteward input
# (flake.lock original.ref) against the newest release of its upstream
# (a github owner/repo or a git URL), review when newer. A commit pin
# (original.rev, as `contribute upgrade --main` writes it) is current while
# the commit contains the newest release and review once a newer release
# exists, from the upstream's commits. Manual for an input that is neither
# or is a local path, error rows for a missing input or lock file, unknown
# input types and a commit the upstream does not have.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
clear_latest
lock=$inst/flake.lock

set_original() {
  json_edit "$lock" "data['nodes']['dotsteward']['original'] = __import__('json').loads('''$1''')"
}

# gh fails: no release list, so an error row; the framework has no release
# then (an empty list): the newest stable tag of the upstream answers.
ds_stub_clear_routes gh
latest_gh_routes_without_framework() {
  ds_stub_route gh "api repos/example-org/example-skills/compare/*" --stdout-file "$latest_fixtures/gh/compare-skills.json"
  release_route example-org/example-tool "$latest_fixtures/gh/example-tool-release.json"
  release_route example-org/example-lib
  release_route example-org/example-term
}
latest_gh_routes_without_framework
assert_exit 1 latest --out "$report"
assert_eq '"error"' "$(row framework .status)"
assert_contains "$(row framework .details.error)" "the release list of example/dotsteward could not be read"
release_route example/dotsteward
: >"$DS_CALL_LOG"
assert_exit 0 latest --out "$report"
assert_eq '{"id":"framework","kind":"framework","current":"v0.1.0","latest":"v0.2.0","status":"review","source":"https://github.com/example/dotsteward/releases","details":{"tag":"v0.2.0","upstream":"github:example/dotsteward"}}' \
  "$(row framework)"
assert_call_count 1 gh "api repos/example/dotsteward/releases*per_page=100*"

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

# A commit pin: current while the commit contains the newest release
# (the release commit itself, or a main commit after it), review when the
# commit is older than the newest release.
released=$(rev example/dotsteward v0.2.0)
older=$(rev example/dotsteward v0.1.0)
set_original "{\"owner\": \"example\", \"repo\": \"dotsteward\", \"rev\": \"$released\", \"type\": \"github\"}"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"framework\",\"kind\":\"framework\",\"current\":\"${released:0:12}\",\"latest\":\"v0.2.0\",\"status\":\"current\",\"source\":\"https://github.com/example/dotsteward/releases\",\"details\":{\"tag\":\"v0.2.0\",\"upstream\":\"github:example/dotsteward\",\"rev\":\"$released\",\"contains\":true}}" \
  "$(row framework)"
set_original "{\"owner\": \"example\", \"repo\": \"dotsteward\", \"rev\": \"$older\", \"type\": \"github\"}"
assert_exit 0 latest --out "$report"
assert_eq "[\"${older:0:12}\",\"v0.2.0\",\"review\",false]" "$(row framework '[.current, .latest, .status, .details.contains]')"
ds_git_commit "$sources/example/dotsteward" CHANGES.txt "unreleased" "fix: a change on main after v0.2.0"
publish example/dotsteward
ahead=$(rev example/dotsteward main)
set_original "{\"owner\": \"example\", \"repo\": \"dotsteward\", \"rev\": \"$ahead\", \"type\": \"github\"}"
assert_exit 0 latest --out "$report"
assert_eq "[\"${ahead:0:12}\",\"v0.2.0\",\"current\",true]" "$(row framework '[.current, .latest, .status, .details.contains]')"

# The git form of a commit pin (?ref=refs/heads/main&rev=...): git alone.
: >"$DS_CALL_LOG"
set_original "{\"type\": \"git\", \"url\": \"file://$github/example/dotsteward\", \"ref\": \"refs/heads/main\", \"rev\": \"$older\"}"
assert_exit 0 latest --out "$report"
assert_eq "[\"${older:0:12}\",\"v0.2.0\",\"review\",\"$older\"]" "$(row framework '[.current, .latest, .status, .details.rev]')"
assert_call_count 0 gh "api repos/example/dotsteward/*"

# A commit the upstream does not have: an error row.
set_original '{"owner": "example", "repo": "dotsteward", "rev": "0123456789abcdef0123456789abcdef01234567", "type": "github"}'
assert_exit 1 latest --out "$report"
assert_eq '["0123456789ab","error"]' "$(row framework '[.current, .status]')"
assert_not_contains "$DS_STDERR" "Traceback"

# Neither a release tag nor a commit, or a local checkout: manual.
set_original '{"owner": "example", "repo": "dotsteward", "type": "github"}'
assert_exit 0 latest --out "$report"
assert_eq '{"id":"framework","kind":"framework","current":null,"latest":null,"status":"manual","source":"https://github.com/example/dotsteward/releases","details":{"note":"the dotsteward input is not pinned to a release tag or a commit","upstream":"github:example/dotsteward"}}' \
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
