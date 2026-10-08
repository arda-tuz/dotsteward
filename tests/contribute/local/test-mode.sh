# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The contribute mode matrix: owner only when upstream.contribute
# is owner, `gh auth status` succeeds, the upstream grants push and the
# local clone's origin is the upstream (or there is no clone yet); every
# other combination is fork mode, reported with its reason on stderr and in
# the JSON document, never an error. The upstream comes from the dotsteward
# node of the instance flake.lock. Mode never writes anything.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

mode_json() {
  assert_exit 0 run_contribute mode --json
  printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/mode.json"
  jq -e . "$DS_TEST_ROOT/mode.json" >/dev/null || ds_fail "mode --json is not one JSON document: $DS_STDOUT"
}

# --- owner --------------------------------------------------------------------

mode_json
assert_json "$DS_TEST_ROOT/mode.json" '.schema_version == 1'
assert_json "$DS_TEST_ROOT/mode.json" '.mode == "owner" and .configured == "owner" and .fallback == null'
assert_json "$DS_TEST_ROOT/mode.json" ".upstream == \"$CT_UPSTREAM_SLUG\" and .upstream_url == \"$CT_UPSTREAM_URL\""
assert_json "$DS_TEST_ROOT/mode.json" '.upstream_remote == "origin"'
assert_json "$DS_TEST_ROOT/mode.json" ".clone == \"$ct_clone\" and .fork == null and .fork_url == null"
assert_json "$DS_TEST_ROOT/mode.json" '.gh_login == "dotsteward-test"'
assert_eq "" "$DS_STDERR" "owner mode warns about nothing"
assert_call_count 1 gh 'auth status*'
assert_call_count 1 gh "api repos/$CT_UPSTREAM_SLUG*"
assert_call_count 0 nix

# Human output.
assert_exit 0 run_contribute mode
assert_contains "$DS_STDOUT" "[dotsteward] contribute mode: owner"
assert_contains "$DS_STDOUT" "upstream $CT_UPSTREAM_SLUG"

# --- owner falls back to fork ---------------------------------------------------

expect_fallback() {
  local reason=$1
  mode_json
  assert_json "$DS_TEST_ROOT/mode.json" '.mode == "fork" and .configured == "owner"'
  assert_json "$DS_TEST_ROOT/mode.json" "(.fallback | type) == \"string\" and (.fallback | contains(\"$reason\"))"
  assert_json "$DS_TEST_ROOT/mode.json" '.upstream_remote == "upstream"'
  assert_contains "$DS_STDERR" "[dotsteward] WARNING: owner mode is not available ($reason"
  assert_contains "$DS_STDERR" "using fork mode"
}

# Not logged in to gh: no fork can be named either.
ds_stub_set gh auth logged-out
expect_fallback "gh is not logged in"
assert_json "$DS_TEST_ROOT/mode.json" '.fork == null and .gh_login == null'
ds_stub_set gh auth logged-in

# No push permission.
gh_routes ssh false exists
expect_fallback "no push permission on $CT_UPSTREAM_SLUG"
assert_json "$DS_TEST_ROOT/mode.json" ".fork == \"$CT_FORK_SLUG\" and .fork_url == \"$CT_FORK_URL\""

# The permission cannot be read.
gh_routes ssh error exists
expect_fallback "cannot read the permissions of $CT_UPSTREAM_SLUG"

# The clone's origin is not the upstream.
gh_routes ssh true exists
git init -q -b main "$ct_clone"
git -C "$ct_clone" remote add origin "$CT_FORK_URL"
expect_fallback "the origin of $ct_clone is not the upstream"
# The same repository under another URL form is the upstream.
for url in "$CT_UPSTREAM_HTTPS" https://github.com/Example-Org/dotsteward ssh://git@github.com/example-org/dotsteward.git; do
  git -C "$ct_clone" remote set-url origin "$url"
  mode_json
  assert_json "$DS_TEST_ROOT/mode.json" '.mode == "owner" and .fallback == null'
done
rm -rf -- "$ct_clone"

# The upstream is not on GitHub.
cp "$ct_inst/flake.lock" "$DS_TEST_ROOT/flake.lock.github"
jq '.nodes.dotsteward.original = {type: "git", url: "ssh://git@example.invalid/team/dotsteward.git"}' \
  "$DS_TEST_ROOT/flake.lock.github" >"$ct_inst/flake.lock"
expect_fallback "the upstream is not a GitHub repository"
assert_json "$DS_TEST_ROOT/mode.json" '.upstream == "git+ssh://git@example.invalid/team/dotsteward.git"'
assert_json "$DS_TEST_ROOT/mode.json" '.upstream_url == "ssh://git@example.invalid/team/dotsteward.git"'
assert_json "$DS_TEST_ROOT/mode.json" ".fork == \"$CT_FORK_SLUG\""

# A git input on github.com is a GitHub upstream; its URL is kept.
jq '.nodes.dotsteward.original = {type: "git", url: "https://github.com/example-org/dotsteward.git", ref: "v0.1.0"}' \
  "$DS_TEST_ROOT/flake.lock.github" >"$ct_inst/flake.lock"
mode_json
assert_json "$DS_TEST_ROOT/mode.json" ".mode == \"owner\" and .upstream == \"$CT_UPSTREAM_SLUG\""
assert_json "$DS_TEST_ROOT/mode.json" ".upstream_url == \"$CT_UPSTREAM_HTTPS\""
cp "$DS_TEST_ROOT/flake.lock.github" "$ct_inst/flake.lock"

# --- fork ---------------------------------------------------------------------

: >"$DS_CALL_LOG"
write_instance fork
mode_json
assert_json "$DS_TEST_ROOT/mode.json" '.mode == "fork" and .configured == "fork" and .fallback == null'
assert_json "$DS_TEST_ROOT/mode.json" ".fork == \"$CT_FORK_SLUG\" and .fork_url == \"$CT_FORK_URL\""
assert_json "$DS_TEST_ROOT/mode.json" '.upstream_remote == "upstream"'
assert_eq "" "$DS_STDERR" "configured fork mode is not a fallback"
assert_call_count 0 gh "api repos/$CT_UPSTREAM_SLUG*"

# upstream.fork names the fork.
write_instance fork 'fork = "example-team/dotsteward"'
mode_json
assert_json "$DS_TEST_ROOT/mode.json" '.fork == "example-team/dotsteward"'
assert_json "$DS_TEST_ROOT/mode.json" '.fork_url == "git@github.com:example-team/dotsteward.git"'

# gh prefers https (or says nothing): the GitHub URLs use https.
for protocol in https none; do
  gh_routes "$protocol" true exists
  write_instance owner
  mode_json
  assert_json "$DS_TEST_ROOT/mode.json" ".upstream_url == \"$CT_UPSTREAM_HTTPS\""
  write_instance fork
  mode_json
  assert_json "$DS_TEST_ROOT/mode.json" '.fork_url == "https://github.com/dotsteward-test/dotsteward.git"'
done
gh_routes ssh true exists

# --- refusals -----------------------------------------------------------------

# No dotsteward input in flake.lock: the upstream is unknown.
printf '{\n  "nodes": {"root": {"inputs": {}}},\n  "root": "root",\n  "version": 7\n}\n' >"$ct_inst/flake.lock"
assert_exit 1 run_contribute mode
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance flake.lock has no dotsteward input"
rm -f "$ct_inst/flake.lock"
assert_exit 1 run_contribute mode
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance flake.lock has no dotsteward input"
cp "$DS_TEST_ROOT/flake.lock.github" "$ct_inst/flake.lock"

# An upstream that is not a git repository cannot be cloned.
jq '.nodes.dotsteward.original = {type: "path", path: "/srv/dotsteward"}' \
  "$DS_TEST_ROOT/flake.lock.github" >"$ct_inst/flake.lock"
assert_exit 1 run_contribute mode
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unsupported framework upstream for contribute: path:/srv/dotsteward"
cp "$DS_TEST_ROOT/flake.lock.github" "$ct_inst/flake.lock"

# Mode wrote nothing and made no connection.
[[ ! -e $ct_runs ]] || ds_fail "mode created the contribute state directory"
assert_eq "" "$(network_calls)" "network connections"
assert_eq "" "$(temp_leftovers)" "temporary files left behind"
