# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# U4 and U6, a successful update publish ([gate] I1, I4, I17): HEAD is
# pushed to instance.branch of instance.remote without force, the remote
# branch is verified, and nothing is built, activated or written to the
# state. The base comes from --expected-base, else candidate.json of this
# instance, else `git merge-base HEAD origin/<branch>` (publish does not need
# prepare).
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

# --- with prepare ---------------------------------------------------------------

assert_exit 0 run_update prepare --official-sources-only --scope maintain
base=$(head_oid)
change_and_commit "docs: first"
change_and_commit "fix(docs): second"
write_validation
state_before=$(cd "$up_state" && find . -type f -printf '%p %s %T@\n' | LC_ALL=C sort)
reset_logs
assert_exit 0 run_update publish --scope maintain
head=$(head_oid)
assert_eq "$head" "$(remote_oid)"
assert_eq "[dotsteward] published $head to main without force; publishing does not activate the local system" \
  "$DS_STDOUT"
# git reports the push itself on standard error.
assert_contains "$DS_STDERR" "${base:0:7}..${head:0:7}"
assert_not_contains "$DS_STDERR" "forced update"
assert_not_contains "$DS_STDERR" "[dotsteward] WARNING"
assert_eq "$(printf '%s\n' "git@github.com git-upload-pack alice/workstation.git" \
  "git@github.com git-receive-pack alice/workstation.git" \
  "git@github.com git-upload-pack alice/workstation.git")" "$(network_calls)"
assert_call_count 0 nix
assert_call_count 0 curl
assert_call_count 0 gh
assert_eq "$state_before" "$(cd "$up_state" && find . -type f -printf '%p %s %T@\n' | LC_ALL=C sort)"
assert_eq "" "$(temp_dirs)"
assert_eq "$head" "$(git -C "$up_inst" rev-parse refs/remotes/origin/main)"

# --- without prepare: merge-base HEAD origin/main -----------------------------------

rm -f -- "$up_candidate"
base=$head
change_and_commit "docs: third"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"

# candidate.json of another root is ignored.
write_candidate "$(git -C "$up_inst" rev-list --max-parents=0 HEAD)" "$DS_TEST_ROOT/other"
change_and_commit "docs: fourth"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"

# --- --expected-base wins over candidate.json -------------------------------------

base=$(head_oid)
write_candidate "$(git -C "$up_inst" rev-parse HEAD~1)"
change_and_commit "docs: fifth"
write_validation
reset_logs
# The recorded base is an ancestor, but the remote is not at it.
assert_exit 1 run_update publish --scope maintain
assert_contains "$DS_STDERR" "remote main changed since prepare"
assert_exit 0 run_update publish --scope maintain --expected-base "$base"
assert_eq "$(head_oid)" "$(remote_oid)"

# --- the configured branch ------------------------------------------------------------

git -C "$up_inst" checkout -q -b trunk
set_toml instance branch '"trunk"'
commit_all "chore: use trunk"
git -C "$up_inst" push -q origin trunk 2>/dev/null
assert_exit 0 run_update prepare --official-sources-only --scope maintain
main_before=$(remote_oid)
change_and_commit "docs: on trunk"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "[dotsteward] published $(head_oid) to trunk without force; publishing does not activate the local system" \
  "$DS_STDOUT"
assert_eq "$(head_oid)" "$(git -C "$up_bare" rev-parse refs/heads/trunk)"
assert_eq "$main_before" "$(remote_oid)" "main moved"
