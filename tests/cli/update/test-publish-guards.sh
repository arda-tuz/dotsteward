# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# U1, the local refusals of update publish, in order ([gate] I15, SPEC 6.2,
# D9): a clean tree, a base (resolved like the gate's), at least one commit
# after the base, the base an ancestor of HEAD, the HEAD tree equal to the
# tree of a passed validation.json, the validated scope equal to the publish
# scope and a validation made without a framework override. Every refusal
# happens before any network call, so nothing is fetched or pushed.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

assert_exit 0 run_update prepare --official-sources-only --scope maintain
base=$(head_oid)

# refused MESSAGE ARG...: publish ARG... is refused with MESSAGE, offline,
# with the remote untouched.
refused() {
  local message=$1
  shift
  reset_logs
  assert_exit 1 run_update publish "$@"
  assert_eq "[dotsteward] ERROR: $message" "$DS_STDERR"
  assert_eq "" "$DS_STDOUT"
  assert_no_network
  assert_call_count 0 nix
  assert_eq "$base" "$(remote_oid)" "the remote moved"
}

# No commit after the base.
refused "nothing to publish after the base OID $base" --scope maintain

change_and_commit "docs: describe the change"
write_validation

# A dirty tree: untracked, modified, staged.
printf 'new\n' >"$up_inst/new.txt"
refused "update publish needs a committed, clean candidate" --scope maintain
rm -f -- "$up_inst/new.txt"
printf 'more\n' >>"$up_inst/docs/guide.md"
refused "update publish needs a committed, clean candidate" --scope maintain
git -C "$up_inst" add docs/guide.md
refused "update publish needs a committed, clean candidate" --scope maintain
git -C "$up_inst" reset -q --hard
# The user's status.showUntrackedFiles = no hides nothing.
git config --global status.showUntrackedFiles no
printf 'new\n' >"$up_inst/new.txt"
refused "update publish needs a committed, clean candidate" --scope maintain
rm -f -- "$up_inst/new.txt"
git config --global --unset status.showUntrackedFiles

# Ignored files are not changes: the guards pass up to the network.
mkdir -p "$up_inst/ignored"
printf 'x\n' >"$up_inst/ignored/file"
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
rm -rf -- "$up_inst/ignored"
base=$(head_oid)
assert_exit 0 run_update prepare --official-sources-only --scope maintain

# An invalid base, from the option or from candidate.json.
change_and_commit "docs: second change"
write_validation
refused "no valid base OID; run 'dotsteward update prepare' first or pass --expected-base" \
  --scope maintain --expected-base "${base:0:12}"
missing=0123456789abcdef0123456789abcdef01234567
refused "base OID is not a commit of this clone: $missing" --scope maintain --expected-base "$missing"
write_candidate "$missing"
refused "base OID is not a commit of this clone: $missing" --scope maintain
write_candidate "$base"

# A clone whose branch was never pushed (no candidate.json, no origin/main):
# publish ships changes on top of a published base, so it names the first
# push instead.
rm -f -- "$up_candidate"
git -C "$up_inst" update-ref -d refs/remotes/origin/main
refused "origin/main does not exist in this clone; push the first commit of a new instance with: git -C $up_inst push -u origin main (after 'dotsteward gate --scope maintain' passed), or run 'git -C $up_inst fetch origin' when the remote has main already" \
  --scope maintain
git -C "$up_inst" update-ref refs/remotes/origin/main "$base"
write_candidate "$base"

# The base is not an ancestor of HEAD.
git -C "$up_inst" checkout -q -b side "$base~1"
printf 'side\n' >"$up_inst/side.txt"
git -C "$up_inst" add side.txt
git -C "$up_inst" commit -q -m "docs: side branch"
side=$(head_oid)
git -C "$up_inst" checkout -q main
git -C "$up_inst" branch -q -D side
refused "base OID $side is not an ancestor of HEAD" --scope maintain --expected-base "$side"

# HEAD is the base given explicitly.
refused "nothing to publish after the base OID $(head_oid)" --scope maintain --expected-base "$(head_oid)"

# The HEAD tree is not the validated tree: no record, an unreadable record,
# a record of another tree, a record that did not pass.
hint="HEAD tree is not the validated tree; run 'dotsteward gate --scope maintain' first"
rm -f -- "$up_validation"
refused "$hint" --scope maintain
printf 'not json\n' >"$up_validation"
refused "$hint" --scope maintain
write_validation '.tree_oid = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"'
refused "$hint" --scope maintain
write_validation '.result = "failed"'
refused "$hint" --scope maintain
write_validation '[.]'
refused "$hint" --scope maintain
# The hint names the publish scope.
write_validation '.tree_oid = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"'
refused "HEAD tree is not the validated tree; run 'dotsteward gate --scope update' first" --scope update

# The validated scope differs from the publish scope (both directions).
write_validation '.scope = "update"'
refused "the validation was made for the update scope, not maintain; run 'dotsteward gate --scope maintain --force' first" \
  --scope maintain
write_validation
refused "the validation was made for the maintain scope, not update; run 'dotsteward gate --scope update --force' first"
refused "the validation was made for the maintain scope, not update; run 'dotsteward gate --scope update --force' first" \
  --scope update
write_validation '.scope = null'
refused "the validation was made for the (none) scope, not maintain; run 'dotsteward gate --scope maintain --force' first" \
  --scope maintain

# The validation used a framework override (D9).
write_validation '.framework_override = "path:/tmp/dotsteward-candidate"'
refused "the validation used the framework override path:/tmp/dotsteward-candidate; run 'dotsteward gate --scope maintain' without an override first" \
  --scope maintain

# A record without the override field (schema 1.0, written by an older gate)
# has no override; root, base, nix and gate versions are not compared.
write_validation 'del(.framework_override, .gate_version, .denylist_sha256) | .schema_version = "1.0"
  | .root = "/elsewhere" | .nix_version = "nix (Nix) 1.0" | .base_oid = "1111111111111111111111111111111111111111"'
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
