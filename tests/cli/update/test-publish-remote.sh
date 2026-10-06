# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# U3, the remote side of update publish ([gate] I17, I19): after a fresh
# fetch origin/<branch> must still be the base; the push is never forced
# and its refusal by the remote is reported; the remote branch must then be
# HEAD. A remote that already holds HEAD (a publish run again) is reported
# as already published, exit 0, with nothing pushed.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

# write_hook NAME BODY: an executable hook of the bare repository.
write_hook() {
  printf '#!%s\n%s\n' "$BASH" "$2" >"$up_bare/hooks/$1"
  chmod 0755 "$up_bare/hooks/$1"
}

assert_exit 0 run_update prepare --official-sources-only --scope maintain
base=$(head_oid)
change_and_commit "docs: describe the change"
write_validation

# --- the remote moved after prepare ---------------------------------------------

push_from_elsewhere "docs: change elsewhere"
moved=$(remote_oid)
reset_logs
assert_exit 1 run_update publish --scope maintain
assert_eq "[dotsteward] ERROR: remote main changed since prepare: $moved, not the base OID $base" "$DS_STDERR"
assert_eq "$moved" "$(remote_oid)"
assert_eq "$moved" "$(git -C "$up_inst" rev-parse refs/remotes/origin/main)"
assert_contains "$(network_calls)" "git-upload-pack alice/workstation.git"
assert_not_contains "$(network_calls)" "git-receive-pack"
git -C "$up_bare" update-ref refs/heads/main "$base"

# --- the fetch fails ------------------------------------------------------------

reset_logs
assert_exit 1 env DS_FAKESSH_FAIL=1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update publish --scope maintain
assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch origin/main within 60 s"
assert_eq "$base" "$(remote_oid)"

# --- the remote refuses the push --------------------------------------------------

write_hook pre-receive 'echo "policy: pushes are closed" >&2; exit 1'
reset_logs
assert_exit 1 run_update publish --scope maintain
assert_contains "$DS_STDERR" "policy: pushes are closed"
assert_eq "[dotsteward] ERROR: push failed" "$(tail -n 1 <<<"$DS_STDERR")"
assert_eq "$base" "$(remote_oid)"
assert_contains "$(network_calls)" "git-receive-pack alice/workstation.git"
rm -f -- "$up_bare/hooks/pre-receive"

# --- the remote branch is not HEAD after the push -------------------------------

write_hook post-receive "git update-ref refs/heads/main $base"
reset_logs
assert_exit 1 run_update publish --scope maintain
assert_eq "[dotsteward] ERROR: could not verify the remote OID: main is $base, expected $(head_oid)" \
  "$(tail -n 1 <<<"$DS_STDERR")"
assert_eq "$base" "$(remote_oid)"
rm -f -- "$up_bare/hooks/post-receive"

# --- never forced -----------------------------------------------------------------

# A remote that refuses non-fast-forward updates accepts the publish.
git -C "$up_bare" config receive.denyNonFastForwards true
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
published=$(head_oid)
git -C "$up_bare" config --unset receive.denyNonFastForwards

# --- already published --------------------------------------------------------------

# candidate.json still holds the old base; the remote already holds HEAD.
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "[dotsteward] main is already $published on the remote; nothing to push" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_not_contains "$(network_calls)" "git-receive-pack"
assert_eq "$published" "$(remote_oid)"

# The local guards still apply first: an unvalidated HEAD is refused even
# when the remote holds it.
write_validation '.tree_oid = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"'
reset_logs
assert_exit 1 run_update publish --scope maintain
assert_eq "[dotsteward] ERROR: HEAD tree is not the validated tree; run 'dotsteward gate --scope maintain' first" \
  "$DS_STDERR"
assert_no_network

# A remote that moved past HEAD is still a refusal.
write_validation
push_from_elsewhere "docs: change after the publish"
reset_logs
assert_exit 1 run_update publish --scope maintain
assert_contains "$DS_STDERR" "[dotsteward] ERROR: remote main changed since prepare: $(remote_oid), not the base OID $base"
assert_call_count 0 nix
