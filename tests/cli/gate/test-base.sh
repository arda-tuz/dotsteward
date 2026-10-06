# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Base resolution ([gate] I4): --expected-base, else the base_oid of
# candidate.json when its root is this instance, else
# `git merge-base HEAD origin/<branch>`; the result must be a full object id.
# The base is recorded in validation.json.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

first=$(git -C "$gate_inst" rev-list --max-parents=0 HEAD)
published=$(head_oid)
mkdir -p "$gate_inst/notes"
printf 'a\n' >"$gate_inst/notes/a.txt"
commit_all "docs: add a note"

# merge-base HEAD origin/main.
assert_exit 0 run_gate --scope maintain
assert_eq "$published" "$(jq -r .base_oid "$gate_validation")"

# candidate.json of another root is ignored.
mkdir -p "$gate_state"
jq -n --arg b "$first" --arg r "$DS_TEST_ROOT/other" '{schema_version: "1.1", base_oid: $b, root: $r}' \
  >"$gate_candidate"
assert_exit 0 run_gate --scope maintain --force
assert_eq "$published" "$(jq -r .base_oid "$gate_validation")"

# candidate.json of this instance wins over merge-base.
jq -n --arg b "$first" --arg r "$gate_inst" '{schema_version: "1.1", base_oid: $b, root: $r}' \
  >"$gate_candidate"
assert_exit 0 run_gate --scope maintain --force
assert_eq "$first" "$(jq -r .base_oid "$gate_validation")"

# --expected-base wins over candidate.json.
assert_exit 0 run_gate --scope maintain --force --expected-base "$published"
assert_eq "$published" "$(jq -r .base_oid "$gate_validation")"

# An invalid base is refused before any Nix command.
: >"$DS_CALL_LOG"
for bad in abc "${published:0:39}" "${published}0" "${published^^}" HEAD; do
  assert_exit 1 run_gate --scope maintain --force --expected-base "$bad"
  assert_eq "[dotsteward] ERROR: no valid base OID; run 'dotsteward update prepare' first or pass --expected-base" "$DS_STDERR"
done
# A well-formed object id that names no commit of this clone.
missing=0123456789abcdef0123456789abcdef01234567
assert_exit 1 run_gate --scope maintain --force --expected-base "$missing"
assert_eq "[dotsteward] ERROR: base OID is not a commit of this clone: $missing" "$DS_STDERR"
tree=$(git -C "$gate_inst" rev-parse 'HEAD^{tree}')
assert_exit 1 run_gate --scope maintain --force --expected-base "$tree"
assert_eq "[dotsteward] ERROR: base OID is not a commit of this clone: $tree" "$DS_STDERR"
assert_calls

# Without candidate.json and without origin/main there is no base.
rm -f -- "$gate_candidate"
git -C "$gate_inst" update-ref -d refs/remotes/origin/main
assert_exit 1 run_gate --scope maintain --force
assert_eq "[dotsteward] ERROR: no valid base OID; run 'dotsteward update prepare' first or pass --expected-base" "$DS_STDERR"
assert_calls

# A candidate.json that is not JSON counts as absent.
printf 'not json\n' >"$gate_candidate"
assert_exit 1 run_gate --scope maintain --force
assert_contains "$DS_STDERR" "no valid base OID"
assert_calls
