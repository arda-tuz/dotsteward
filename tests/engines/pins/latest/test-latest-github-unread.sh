# shellcheck shell=bash
# A github-release row whose release list cannot be read completely never comes from the tags,
# since only the list says which tag is a draft or a prerelease: gh failing (no token, the API
# rate limit) or a family past the pages read is an error row, which the writer leaves for the
# next run. The list is read page by page (30 releases a page: a page of 100 of a repository with
# many assets times out at GitHub) until a page holds a stable release of the family, at most ten
# pages; the tags answer only when the whole list holds no release of the family.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
dir=$(remote_repo example-org/example-cli)
for tag in cli-v1.3.0 cli-v1.5.0 cli-v1.6.0 cli-v1.7.0; do
  ds_git_commit "$dir" VERSION "$tag" "chore: $tag"
  git -C "$dir" tag "$tag"
done
publish example-org/example-cli
declare_latest '{"component":"example-cli","id":"agent_tools.example-release","adapter":"github-release","repo":"example-org/example-cli","tag_prefix":"cli-v","at":"agent_tools.example-release","asset":"example-cli-linux-x64.tar.gz"}'

# page N FILE: the Nth page of the release list of example-cli.
page() {
  ds_stub_route gh "api repos/example-org/example-cli/releases?per_page=30&page=$1" --stdout-file "$2"
}
others() {
  jq -n --argjson from "$1" '[range($from; $from + 30) | {tag_name: "desktop-v9.\(.).0", draft: false, prerelease: false, assets: []}]'
}

# gh answers with an error, as without a token or over the rate limit: an error row.
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-cli/releases*" --exit 1 \
  --stderr "gh: API rate limit exceeded for 203.0.113.7. (HTTP 403)"
latest_gh_routes
assert_exit 1 latest --out "$report"
assert_eq '["error",null]' "$(row agent_tools.example-release '[.status, .latest]')"
assert_contains "$(row agent_tools.example-release .details.error)" "the release list of example-org/example-cli could not be read"
assert_contains "$(row agent_tools.example-release .details.error)" "HTTP 403"

# The first page holds only another family; the second the family, with a draft and a prerelease.
others 0 >"$DS_TEST_ROOT/page1.json"
jq -n '[{tag_name: "cli-v1.7.0", draft: true, prerelease: false, assets: []},
  {tag_name: "cli-v1.6.0", draft: false, prerelease: true, assets: []},
  {tag_name: "cli-v1.5.0", draft: false, prerelease: false, assets: []}]' >"$DS_TEST_ROOT/page2.json"
ds_stub_clear_routes gh
page 1 "$DS_TEST_ROOT/page1.json"
page 2 "$DS_TEST_ROOT/page2.json"
latest_gh_routes
: >"$DS_CALL_LOG"
assert_exit 0 latest --out "$report"
assert_eq '["1.5.0","update","cli-v1.5.0"]' "$(row agent_tools.example-release '[.latest, .status, .details.tag]')"
assert_call_count 0 gh "api repos/example-org/example-cli/releases*page=3"

# Ten full pages without the family: an error row, never the tags.
ds_stub_clear_routes gh
for number in 1 2 3 4 5 6 7 8 9 10 11; do
  others $((number * 30)) >"$DS_TEST_ROOT/page$number.json"
  page "$number" "$DS_TEST_ROOT/page$number.json"
done
latest_gh_routes
: >"$DS_CALL_LOG"
assert_exit 1 latest --out "$report"
assert_eq '"error"' "$(row agent_tools.example-release .status)"
assert_contains "$(row agent_tools.example-release .details.error)" "no stable release of the family cli-v in the 300 newest releases"
assert_call_count 0 gh "api repos/example-org/example-cli/releases*page=11"

# The whole list read, no release of the family at all: the newest stable tag answers.
printf '[]\n' >"$DS_TEST_ROOT/empty.json"
ds_stub_clear_routes gh
page 1 "$DS_TEST_ROOT/empty.json"
latest_gh_routes
assert_exit 0 latest --out "$report"
assert_eq '["1.7.0","update",{"tag":"cli-v1.7.0"}]' "$(row agent_tools.example-release '[.latest, .status, .details]')"
