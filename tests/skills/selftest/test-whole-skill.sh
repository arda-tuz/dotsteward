# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The entry points the per-skill tests use: sc_check_framework_skill (C1-C7,
# C8 with --framework-upgrade) and sc_check_plugin_skill (C1-C6) collect
# every finding, and sc_assert_clean fails the test with all of them.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

st_skill >/dev/null
st_expect_clean sc_check_framework_skill example-skill --handover dotsteward-contribute \
  --require-conventional-types --framework-upgrade
st_skill example-skill "$SC_REPO_ROOT/plugins/dotsteward/skills" >/dev/null
st_expect_clean sc_check_plugin_skill example-skill

# sc_assert_clean passes without findings and lists every finding otherwise.
sc_reset
sc_assert_clean
skill=$SC_REPO_ROOT/skills/example-skill
rm "$skill/LICENSE" "$skill/agents/openai.yaml"
sc_reset
sc_check_framework_skill example-skill --handover dotsteward-contribute
assert_eq 2 "${#SC_FINDINGS[@]}" "findings: ${SC_FINDINGS[*]}"
assert_exit 1 sc_assert_clean
assert_contains "$DS_STDERR" 'assertion failed: 2 skill contract findings:'
assert_contains "$DS_STDERR" 'C2 example-skill: agents/openai.yaml is missing or not a regular file'
assert_contains "$DS_STDERR" 'C3 example-skill: LICENSE is missing or not a regular file'

# A missing skill is one finding, not a cascade.
sc_reset
sc_check_framework_skill nosuch-skill --handover dotsteward-contribute
assert_eq "C1 nosuch-skill: no skill directory at skills/nosuch-skill" "${SC_FINDINGS[*]}"
sc_reset
sc_check_plugin_skill nosuch-skill
assert_eq "C1 nosuch-skill: no skill directory at plugins/dotsteward/skills/nosuch-skill" "${SC_FINDINGS[*]}"

# Unknown options are usage errors.
assert_exit 1 sc_check_framework_skill example-skill --bogus
assert_contains "$DS_STDERR" 'sc_check_framework_skill: unknown option: --bogus'
