# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# gh answers from canned JSON routes, applies --jq like gh does, has
# sensible defaults for the identity calls and counts every call.

ds_use_stubs gh

# Defaults: version, a logged-in account and the user record.
assert_contains "$(gh --version)" "gh version"
assert_exit 0 gh auth status
assert_contains "$DS_STDERR$DS_STDOUT" "Logged in to github.com account dotsteward-test"
assert_json - '.login == "dotsteward-test" and .id == 1000' <<<"$(gh api user)"
assert_eq "1000+dotsteward-test" "$(gh api user --jq '"\(.id)+\(.login)"')"
ds_stub_set gh auth logged-out
assert_exit 1 gh auth status
assert_contains "$DS_STDERR" "You are not logged into any GitHub hosts"
assert_exit 4 gh api user
assert_contains "$DS_STDERR" "gh auth login"
ds_stub_set gh auth logged-in

# Canned routes: the --jq/-q filter is applied to the canned body and is not
# part of the matched argument text.
release=$(ds_fixture common/github/release-latest.json)
ds_stub_route gh 'api repos/example-org/example-term/releases/latest' --stdout-file "$release"
assert_eq v0.9.0 "$(gh api repos/example-org/example-term/releases/latest --jq .tag_name)"
assert_eq v0.9.0 "$(gh api repos/example-org/example-term/releases/latest -q .tag_name)"
assert_json - '.assets | length == 2' <<<"$(gh api repos/example-org/example-term/releases/latest)"
assert_call_count 3 gh 'api repos/example-org/example-term/releases/latest*'

# Routes can fail, and only a limited number of times.
ds_stub_route gh 'pr create *' --exit 1 --stderr "pull request create failed: GraphQL error" --times 1
ds_stub_route gh 'pr create *' --stdout "https://github.com/example-org/example-app/pull/7"
assert_exit 1 gh pr create --title "feat: x" --body "y"
assert_exit 0 gh pr create --title "feat: x" --body "y"
assert_eq "https://github.com/example-org/example-app/pull/7" "$DS_STDOUT"
assert_call_count 2 gh 'pr create *'

# Anything without a route is an error that names the arguments.
assert_exit 1 gh repo view example-org/example-app
assert_contains "$DS_STDERR" "gh stub: no canned response for: repo view example-org/example-app"
