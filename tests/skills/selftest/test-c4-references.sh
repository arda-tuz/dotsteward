# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C4: references/*.md: every reference mentioned exists, every reference file
# is linked from SKILL.md (no orphans), and references/ holds only Markdown
# files.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
st_expect_clean sc_check_references "$skill"

# Cross-skill paths are another skill's business and are not resolved here.
printf 'Version changes use ../dotsteward-update/references/update-contract.md and\n' >>"$skill/SKILL.md"
printf 'skills/dotsteward-update/references/sources-and-hashes.md.\n' >>"$skill/SKILL.md"
st_expect_clean sc_check_references "$skill"

# A mention of a missing reference, in SKILL.md or in a reference.
printf 'Details: references/missing.md.\n' >>"$skill/SKILL.md"
st_expect_finding 'C4 example-skill/SKILL.md:' sc_check_references "$skill"
assert_contains "$ST_OUT" 'references/missing.md is mentioned but does not exist'
sed -i '$d' "$skill/SKILL.md"
printf 'See also [the other page](references/gone.md).\n' >>"$skill/references/commands.md"
st_expect_finding 'C4 example-skill/references/commands.md:' sc_check_references "$skill"
assert_contains "$ST_OUT" 'references/gone.md is mentioned but does not exist'
sed -i '$d' "$skill/references/commands.md"
st_expect_clean sc_check_references "$skill"

# An orphan: a reference that SKILL.md never links (a mention from another
# reference does not count).
printf '# Orphan\n' >"$skill/references/orphan.md"
printf 'Also read references/orphan.md.\n' >>"$skill/references/commands.md"
st_expect_finding 'C4 example-skill/references/orphan.md: not linked from SKILL.md' sc_check_references "$skill"
rm "$skill/references/orphan.md"
sed -i '$d' "$skill/references/commands.md"

# Only Markdown files, no subdirectories.
printf 'x\n' >"$skill/references/data.json"
st_expect_finding 'C4 example-skill/references/data.json: references/ holds only *.md files' sc_check_references "$skill"
rm "$skill/references/data.json"
mkdir "$skill/references/nested"
st_expect_finding 'C4 example-skill/references/nested: references/ holds only *.md files' sc_check_references "$skill"
rmdir "$skill/references/nested"

# references/ is required and must not be empty.
rm -r "$skill/references"
st_expect_finding 'C4 example-skill: references/ is missing or has no *.md file' sc_check_references "$skill"
