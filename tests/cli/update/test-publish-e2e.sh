# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# No publish after a red E2E: when the transaction activated a tree on this
# machine (`rebuild --switch` records <state root>/current/activation.json:
# the revision, its tree, the generation and the profile), update publish
# requires that the activated tree is the HEAD tree and that the E2E result
# (<state root>/update/e2e.json) passed for that tree, that generation and
# that profile, with the repository checks: an E2E run of another profile
# checked other hooks. A transaction activated a tree when the
# activated tree is the HEAD tree or the activated revision is a commit
# after the base. Publishing without an activation stays allowed: an
# activation of the base (an earlier transaction) asks for nothing.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

activation=$DOTSTEWARD_STATE_ROOT/current/activation.json
generation=/nix/store/00000000000000000000000000000000-home-manager-generation

# write_activation REVISION [GENERATION]: the record of rebuild --switch.
write_activation() {
  mkdir -p "$(dirname "$activation")"
  jq -n --arg revision "$1" --arg tree "$(git -C "$up_inst" rev-parse "$1^{tree}")" \
    --arg generation "${2:-$generation}" --arg root "$up_inst" '{
    schema_version: "1.0", generation: $generation, profile: "workstation", revision: $revision,
    tree_oid: $tree, root: $root, framework_override: null, activated_at: "2026-01-01T00:00:00Z"}' >"$activation"
}

# write_e2e RESULT [JQ_FILTER]: the record of an E2E run of the HEAD tree
# and the generation.
write_e2e() {
  mkdir -p "$up_state"
  jq -n --arg result "$1" --arg tree "$(head_tree)" --arg head "$(head_oid)" --arg generation "$generation" \
    --arg root "$up_inst" '{
    schema_version: "1.0", result: $result, tree_oid: $tree, head_oid: $head, generation: $generation,
    profile: "workstation", framework_override: null, repo_checks: true,
    findings: (if $result == "passed" then 0 else 1 end), root: $root,
    recorded_at: "2026-01-01T00:00:00Z"}' | jq "${2:-.}" >"$up_state/e2e.json"
}

refused() {
  local before
  before=$(remote_oid)
  assert_exit 1 run_update publish --scope maintain
  assert_contains "$DS_STDERR" "$1"
  assert_eq "$before" "$(remote_oid)" "a refused publish pushed"
}

assert_exit 0 run_update prepare --official-sources-only --scope maintain
base=$(head_oid)
change_and_commit "docs: first"
first=$(head_oid)
write_validation

# The HEAD tree is active on this machine, without a passing E2E for it.
write_activation "$first"
hint="run 'dotsteward e2e --profile workstation --expected-remote-base $base' first"
refused "the tree of HEAD is active on this machine (generation $generation, rebuild --switch) but no passing E2E is recorded for this tree and generation; $hint"
write_e2e failed
refused "no passing E2E is recorded for this tree and generation; $hint"
write_e2e passed '.generation = "/nix/store/11111111111111111111111111111111-home-manager-generation"'
refused "no passing E2E is recorded for this tree and generation"
write_e2e passed '.repo_checks = false'
refused "no passing E2E is recorded for this tree and generation"
write_e2e passed '.tree_oid = "0000000000000000000000000000000000000000"'
refused "no passing E2E is recorded for this tree and generation"
# A passing E2E of the same tree and generation for another profile (which
# may enable fewer components, so fewer hooks ran) does not verify the
# activation of this one.
write_e2e passed '.profile = "minimal"'
refused "no passing E2E is recorded for this tree and generation; $hint (the recorded E2E checked the profile minimal, not workstation)"

# The transaction activated an earlier commit: HEAD was never activated.
write_e2e passed
change_and_commit "docs: second"
write_validation
refused "this transaction activated ${first:0:12} on this machine (rebuild --switch), not the tree of HEAD; activate HEAD and run E2E for it first: dotsteward rebuild --profile workstation --switch, then dotsteward e2e --profile workstation --expected-remote-base $base"

# HEAD activated and verified: published.
write_activation "$(head_oid)"
write_e2e passed
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"

# The next transaction does not activate: the activation of its base (the
# last one) asks for nothing, and no E2E record is needed.
rm -f -- "$up_state/e2e.json" "$up_candidate"
change_and_commit "docs: third"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"

# Without an activation record publishing is allowed as before.
rm -f -- "$activation"
change_and_commit "docs: fourth"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
