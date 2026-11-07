# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rebuild --switch records the activation in <state>/current/activation.json
# (mode 0600, written atomically) as soon as the generation is activated:
# generation (the activation package), profile, revision and tree_oid (the
# instance HEAD), root (the checkout), framework_override (or null) and
# activated_at. `dotsteward txn publish` reads it to require a passing
# E2E for an activated tree. --build-only records nothing, and a failed
# activation keeps the previous record.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

activation=$rb_current/activation.json

assert_exit 0 run_rebuild --profile workstation --build-only
[[ ! -e $activation ]] || ds_fail "rebuild --build-only recorded an activation"

assert_exit 0 run_rebuild --profile workstation --switch
generation=$(<"$rb_current/last-built-activation")
assert_file_mode "$activation" 600
assert_json "$activation" '(keys_unsorted) == ["schema_version", "generation", "profile", "revision", "tree_oid",
  "root", "framework_override", "activated_at"]'
jq -e --arg generation "$generation" --arg revision "$(git -C "$rb_inst" rev-parse HEAD)" \
  --arg tree "$(git -C "$rb_inst" rev-parse 'HEAD^{tree}')" --arg root "$rb_inst" '
  .schema_version == "1.0" and .generation == $generation and .profile == "workstation"
  and .revision == $revision and .tree_oid == $tree and .root == $root and .framework_override == null
  and (.activated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$activation" >/dev/null ||
  ds_fail "unexpected record: $(<"$activation")"
assert_eq "" "$(find "$rb_current" -name '.activation.json.*' -print)" "temporary files left behind"
record=$(<"$activation")

# A build alone leaves the record of the last activation.
printf '# second\n' >>"$rb_inst/flake.nix"
instance_commit "second revision"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq "$record" "$(<"$activation")"

# A failed activation keeps it.
ds_stub_route activate '*' --exit 5
assert_exit 5 run_rebuild --profile workstation --switch
assert_eq "$record" "$(<"$activation")"
ds_stub_clear_routes activate

# A framework override is recorded; the generation activated first counts
# even when a later step of the switch fails.
ref='git+file:///srv/dotsteward?rev=0123456789abcdef0123456789abcdef01234567'
printf '7\n' >"$DS_TEST_ROOT/lmf-exit"
assert_exit 7 run_rebuild --profile fresh --switch --framework-override "$ref"
rm -f -- "$DS_TEST_ROOT/lmf-exit"
jq -e --arg generation "$(<"$rb_current/last-built-activation")" --arg ref "$ref" \
  --arg revision "$(git -C "$rb_inst" rev-parse HEAD)" '
  .generation == $generation and .profile == "fresh" and .revision == $revision
  and .framework_override == $ref' "$activation" >/dev/null || ds_fail "unexpected record: $(<"$activation")"
