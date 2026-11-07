# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# The result of every E2E run is recorded in <state root>/update/e2e.json
# (mode 0600, written atomically), keyed by the tree of the instance
# checkout's HEAD and the verified generation: result (passed only when
# every check passed), tree_oid, head_oid, generation (null without one),
# profile, framework_override, repo_checks (false with
# --skip-repo-checks), findings (their number), root and recorded_at.
# `dotsteward txn publish` reads it; --list records nothing.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

record=$DOTSTEWARD_STATE_ROOT/update/e2e.json
ds_use_stubs example-app
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
publish_instance

# --list runs nothing and records nothing.
assert_exit 0 run_e2e --list
[[ ! -e $record ]] || ds_fail "e2e --list recorded a result"

# A passing run with the active generation.
make_generation
activate_generation
assert_exit 0 run_e2e
assert_file_mode "$DOTSTEWARD_STATE_ROOT/update" 700
assert_file_mode "$record" 600
generation=$(realpath -e -- "$agents_gen")
assert_json "$record" '(keys_unsorted) == ["schema_version", "result", "tree_oid", "head_oid", "generation",
  "profile", "framework_override", "repo_checks", "findings", "root", "recorded_at"]'
jq -e --arg tree "$(git -C "$agents_inst" rev-parse 'HEAD^{tree}')" --arg head "$(git -C "$agents_inst" rev-parse HEAD)" \
  --arg generation "$generation" --arg root "$agents_inst" '
  .schema_version == "1.0" and .result == "passed" and .tree_oid == $tree and .head_oid == $head
  and .generation == $generation and .profile == "workstation" and .framework_override == null
  and .repo_checks == true and .findings == 0 and .root == $root
  and (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$record" >/dev/null ||
  ds_fail "unexpected record: $(<"$record")"
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT/update" -name '.e2e.json.*' -print)" "temporary files left behind"

# A failing run replaces it with a failed result for the same tree.
printf 'exit 3\n' | add_e2e_hook example-app broken main
publish_instance
make_generation
assert_exit 1 run_e2e --keep-going
jq -e --arg tree "$(git -C "$agents_inst" rev-parse 'HEAD^{tree}')" '
  .result == "failed" and .tree_oid == $tree and .findings == 1' "$record" >/dev/null ||
  ds_fail "unexpected record: $(<"$record")"
manifest_edit '.checks.e2e = []'
publish_instance
make_generation

# A built generation (--generation), a framework override and skipped
# repository checks are recorded as such.
built=$DS_TEST_ROOT/built-generation
cp -R "$agents_gen" "$built"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="path:$DS_TEST_ROOT/candidate" \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation \
  --generation "$built" --skip-repo-checks </dev/null
jq -e --arg generation "$(realpath -e -- "$built")" --arg override "path:$DS_TEST_ROOT/candidate" '
  .result == "passed" and .generation == $generation and .framework_override == $override
  and .repo_checks == false' "$record" >/dev/null || ds_fail "unexpected record: $(<"$record")"

# Without any generation (the manifest mirror only): generation null.
rm -f -- "$HOME/.local/state/home-manager/gcroots/current-home"
assert_exit 0 run_e2e
assert_json "$record" '.result == "passed" and .generation == null'
