# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute setup` (SPEC 9.4 step 2): owner mode clones the
# upstream, fork mode clones the fork and adds an `upstream` remote; a fork
# is created with `gh repo fork --clone=false` only with --create-fork; a
# second run fetches instead of cloning; the clone gets the contributor's
# GitHub noreply identity and core.hooksPath=.githooks; owner mode refuses
# without the denylist, fork mode warns. Refusals happen before any write.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

assert_identity() {
  assert_eq dotsteward-test "$(git -C "$ct_clone" config --local user.name)" "user.name"
  assert_eq "$CT_NOREPLY" "$(git -C "$ct_clone" config --local user.email)" "user.email"
  assert_eq .githooks "$(git -C "$ct_clone" config --local core.hooksPath)" "core.hooksPath"
}

# --- owner refusals before any write ----------------------------------------------

# No denylist.
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] ERROR: owner mode needs the denylist ~/.config/dotsteward/denylist.txt"
[[ ! -e $ct_clone ]] || ds_fail "setup cloned without the denylist"
# A denylist without entries.
write_denylist_lines '# only a comment' ''
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "owner mode needs the denylist ~/.config/dotsteward/denylist.txt"
[[ ! -e $ct_clone ]] || ds_fail "setup cloned with an empty denylist"
assert_eq "" "$(network_calls)" "network connections before the refusal"

# Not logged in to gh: the identity is unknown (and owner mode falls back).
write_denylist
ds_stub_set gh auth logged-out
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] ERROR: gh is not logged in; run 'gh auth login' first"
[[ ! -e $ct_clone ]] || ds_fail "setup cloned without a gh login"
ds_stub_set gh auth logged-in

# The clone path exists and is not a git repository.
mkdir -p "$ct_clone"
printf 'notes\n' >"$ct_clone/notes.txt"
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] ERROR: $ct_clone exists and is not a git clone"
rm -rf -- "$ct_clone"

# --- owner --------------------------------------------------------------------

assert_exit 0 run_contribute setup
assert_contains "$DS_STDOUT" "[dotsteward] cloned $CT_UPSTREAM_URL into $ct_clone"
assert_contains "$DS_STDOUT" "[dotsteward] contribute setup done: owner mode"
assert_eq "$CT_UPSTREAM_URL" "$(git -C "$ct_clone" config --get remote.origin.url)" "origin"
assert_eq "$(upstream_main)" "$(git -C "$ct_clone" rev-parse refs/remotes/origin/main)" "origin/main"
assert_identity
if git -C "$ct_clone" remote get-url upstream >/dev/null 2>&1; then
  ds_fail "owner mode added an upstream remote"
fi
assert_call_count 0 gh 'repo fork*'

# A second run fetches: the clone stays and sees the new upstream commit.
printf 'local work\n' >"$ct_clone/scratch.txt"
push_upstream docs/new.md 'new' 'docs: add a page'
assert_exit 0 run_contribute setup
assert_contains "$DS_STDOUT" "[dotsteward] fetched origin in $ct_clone"
assert_not_contains "$DS_STDOUT" "cloned"
assert_eq "$(upstream_main)" "$(git -C "$ct_clone" rev-parse refs/remotes/origin/main)" "origin/main after the fetch"
assert_eq "local work" "$(<"$ct_clone/scratch.txt")" "the clone's files"
assert_identity

# The clone's origin is another repository: fork mode, whose origin must be
# the fork, refuses to rewire it.
git -C "$ct_clone" remote set-url origin git@github.com:example-org/other.git
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] WARNING: owner mode is not available"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the origin of $ct_clone is git@github.com:example-org/other.git, expected $CT_FORK_URL"
rm -rf -- "$ct_clone"

# --- fork ---------------------------------------------------------------------

: >"$DS_CALL_LOG"
write_instance fork
push_upstream docs/upstream-only.md 'ahead' 'docs: upstream moves ahead of the fork'
assert_exit 0 run_contribute setup
assert_contains "$DS_STDOUT" "[dotsteward] cloned $CT_FORK_URL into $ct_clone"
assert_contains "$DS_STDOUT" "[dotsteward] contribute setup done: fork mode"
assert_eq "$CT_FORK_URL" "$(git -C "$ct_clone" config --get remote.origin.url)" "origin"
assert_eq "$CT_UPSTREAM_URL" "$(git -C "$ct_clone" config --get remote.upstream.url)" "upstream"
assert_eq "$(upstream_main)" "$(git -C "$ct_clone" rev-parse refs/remotes/upstream/main)" "upstream/main"
assert_eq "$(fork_main)" "$(git -C "$ct_clone" rev-parse refs/remotes/origin/main)" "origin/main"
assert_identity
assert_call_count 0 gh 'repo fork*'

# A second run keeps the remotes and fetches both.
assert_exit 0 run_contribute setup
assert_contains "$DS_STDOUT" "[dotsteward] fetched origin in $ct_clone"
assert_contains "$DS_STDOUT" "[dotsteward] fetched upstream in $ct_clone"

# An upstream remote that points elsewhere is refused.
git -C "$ct_clone" remote set-url upstream git@github.com:example-org/other.git
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the upstream remote of $ct_clone is git@github.com:example-org/other.git, expected $CT_UPSTREAM_URL"
git -C "$ct_clone" remote set-url upstream "$CT_UPSTREAM_URL"

# Fork mode warns about a missing denylist; it does not refuse.
rm -f "$ct_denylist"
assert_exit 0 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] WARNING: no denylist at ~/.config/dotsteward/denylist.txt"
rm -rf -- "$ct_clone"
write_denylist

# --- fork creation needs consent ------------------------------------------------

: >"$DS_CALL_LOG"
gh_routes ssh true missing
assert_exit 1 run_contribute setup
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the fork $CT_FORK_SLUG does not exist"
assert_contains "$DS_STDERR" "--create-fork"
assert_call_count 0 gh 'repo fork*'
[[ ! -e $ct_clone ]] || ds_fail "setup cloned without a fork"

# With --create-fork the fork is created and then cloned.
ds_stub_clear_routes gh
ds_stub_route gh 'config get git_protocol*' --stdout ssh
ds_stub_route gh "api repos/$CT_FORK_SLUG" --exit 1 --stderr 'gh: Not Found (HTTP 404)' --times 1
ds_stub_route gh "repo fork $CT_UPSTREAM_SLUG --clone=false" --stderr "Created fork $CT_FORK_SLUG"
assert_exit 0 run_contribute setup --create-fork
assert_call_count 1 gh "repo fork $CT_UPSTREAM_SLUG --clone=false"
assert_contains "$DS_STDOUT" "[dotsteward] created the fork $CT_FORK_SLUG"
assert_eq "$CT_FORK_URL" "$(git -C "$ct_clone" config --get remote.origin.url)" "origin of the new fork clone"
rm -rf -- "$ct_clone"

# A configured fork under another owner is created in that organization
# with the configured name.
write_instance fork 'fork = "example-team/framework"'
ds_fakessh_map git@github.com:example-team/framework.git "$ct_fork_bare"
ds_stub_clear_routes gh
ds_stub_route gh 'config get git_protocol*' --stdout ssh
ds_stub_route gh 'api repos/example-team/framework' --exit 1 --stderr 'gh: Not Found (HTTP 404)' --times 1
ds_stub_route gh "repo fork $CT_UPSTREAM_SLUG --clone=false --org example-team --fork-name framework"
assert_exit 0 run_contribute setup --create-fork
assert_call_count 1 gh "repo fork $CT_UPSTREAM_SLUG --clone=false --org example-team --fork-name framework"
assert_eq git@github.com:example-team/framework.git "$(git -C "$ct_clone" config --get remote.origin.url)"
rm -rf -- "$ct_clone"
gh_routes ssh true exists

# --- https --------------------------------------------------------------------

# gh says nothing about its protocol: https URLs, rewritten to the local bare
# repository by git's own URL rewriting.
write_instance owner
gh_routes none true exists
git config --global "url.$ct_upstream_bare.insteadOf" "$CT_UPSTREAM_HTTPS"
assert_exit 0 run_contribute setup
assert_eq "$CT_UPSTREAM_HTTPS" "$(git -C "$ct_clone" config --get remote.origin.url)" "https origin"
assert_eq "$(upstream_main)" "$(git -C "$ct_clone" rev-parse refs/remotes/origin/main)" "origin/main over https"

assert_eq "" "$(temp_leftovers)" "temporary files left behind"
[[ ! -e $ct_runs ]] || ds_fail "setup created the contribute state directory"
assert_call_count 0 nix
