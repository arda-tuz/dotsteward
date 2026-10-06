# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The instance skills lock and the vendored sources are verified before a
# skill touches the home (SPEC 5.2, 8.1; understanding report test 13): the
# lock must be a regular file with schema_version "1.0" and
# expected_skill_count equal to its entries, each entry needs name,
# directory and skill_sha256 and a known deployment (copy, home-manager or
# none); a missing vendored SKILL.md, a SKILL.md digest or a directory digest
# that differs from the lock is fatal for that skill in both modes.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha
mkdir -p "$HOME/.agents/skills" "$HOME/.codex/skills"

expect_refusal() {
  local before mode
  before=$(home_state)
  for mode in check install; do
    assert_exit 1 run_agents "$mode"
    assert_contains "$DS_STDERR" "$1"
    assert_eq "$before" "$(home_state)" "$mode leaves the home unchanged"
  done
}

source_dir=$(vendored alpha)
cp -a "$source_dir" "$DS_TEST_ROOT/alpha-pristine"

printf 'tampered\n' >>"$source_dir/SKILL.md"
expect_refusal "skill source digest differs from the lock: alpha ($source_dir/SKILL.md)"
rm -rf "$source_dir" && cp -a "$DS_TEST_ROOT/alpha-pristine" "$source_dir"

printf 'tampered\n' >>"$source_dir/references/guide.md"
expect_refusal "skill source digest differs from the lock: alpha ($source_dir)"
rm -rf "$source_dir" && cp -a "$DS_TEST_ROOT/alpha-pristine" "$source_dir"

rm "$source_dir/SKILL.md"
expect_refusal "skill source missing: alpha ($source_dir)"
rm -rf "$source_dir" && cp -a "$DS_TEST_ROOT/alpha-pristine" "$source_dir"

# The lock itself.
cp -- "$agents_lock" "$DS_TEST_ROOT/lock-pristine"
jq '.expected_skill_count = 2' "$DS_TEST_ROOT/lock-pristine" >"$agents_lock"
expect_refusal "invalid skills lock $agents_lock: expected_skill_count is 2, the lock has 1 skills"
jq '.schema_version = "2.0"' "$DS_TEST_ROOT/lock-pristine" >"$agents_lock"
expect_refusal "invalid skills lock $agents_lock: schema_version is not \"1.0\""
jq '.skills[0].deployment = "elsewhere"' "$DS_TEST_ROOT/lock-pristine" >"$agents_lock"
expect_refusal "invalid skills lock $agents_lock: skill alpha: unknown deployment elsewhere"
jq 'del(.skills[0].skill_sha256)' "$DS_TEST_ROOT/lock-pristine" >"$agents_lock"
expect_refusal "invalid skills lock $agents_lock: skill 1: name, directory and skill_sha256 must be non-empty strings"
printf 'not json\n' >"$agents_lock"
expect_refusal "invalid skills lock $agents_lock: not valid JSON"
rm "$agents_lock"
ln -s "$DS_TEST_ROOT/lock-pristine" "$agents_lock"
expect_refusal "skills lock is not a regular file: $agents_lock"
rm "$agents_lock"
expect_refusal "skills lock is not a regular file: $agents_lock"
cp -- "$DS_TEST_ROOT/lock-pristine" "$agents_lock"

# An explicit copy deployment is the default one.
jq '.skills[0].deployment = "copy"' "$DS_TEST_ROOT/lock-pristine" >"$agents_lock"
assert_exit 0 run_agents install
[[ -d $HOME/.agents/skills/alpha && ! -L $HOME/.agents/skills/alpha ]] || ds_fail "copy deployment installs a copy"
assert_exit 0 run_agents check
