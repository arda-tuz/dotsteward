# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C1: SKILL.md frontmatter (name equal to the directory, description of at
# most 1024 characters) and no owner data or symlinks in the skill tree.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
st_expect_clean sc_check_frontmatter "$skill"
st_expect_clean sc_check_tree "$skill"

# The name must equal the directory and use the skill name syntax.
st_replace "$skill/SKILL.md" 'name: example-skill' 'name: other-skill'
st_expect_finding 'C1 example-skill/SKILL.md: frontmatter name [other-skill] differs from the directory name [example-skill]' \
  sc_check_frontmatter "$skill"
mismatch=$(st_skill Upper_Case "$DS_TEST_ROOT/odd")
st_expect_finding 'C1 Upper_Case/SKILL.md: name [Upper_Case] is not lowercase words joined by single hyphens' \
  sc_check_frontmatter "$mismatch"
long_name=$(printf 'a%.0s' {1..65})
long=$(st_skill "$long_name" "$DS_TEST_ROOT/odd")
st_expect_finding "name [$long_name] is longer than 64 characters" sc_check_frontmatter "$long"

# Quoted values are unquoted; extra keys are allowed.
st_replace "$skill/SKILL.md" 'name: other-skill' $'name: "example-skill"\nlicense: MIT'
st_expect_clean sc_check_frontmatter "$skill"
st_replace "$skill/SKILL.md" 'name: "example-skill"' "name: 'example-skill'"
st_expect_clean sc_check_frontmatter "$skill"

# A block scalar description is folded; 1024 characters pass, 1025 fail.
# Multi-byte characters count once.
desc_1024="$(printf 'x%.0s' {1..1021})"$'\xc3\xa9'"yz"
st_replace "$skill/SKILL.md" 'description:' "description: $desc_1024"
st_expect_clean sc_check_frontmatter "$skill"
st_replace "$skill/SKILL.md" 'description:' "description: ${desc_1024}z"
st_expect_finding 'C1 example-skill/SKILL.md: description has 1025 characters (at most 1024)' sc_check_frontmatter "$skill"
st_replace "$skill/SKILL.md" 'description:' $'description: >\n  Folded block\n  description text.'
st_expect_clean sc_check_frontmatter "$skill"
st_replace "$skill/SKILL.md" 'description: >' $'description: |\n'
st_replace "$skill/SKILL.md" '  Folded block' ''
st_replace "$skill/SKILL.md" '  description text.' ''
st_expect_finding 'C1 example-skill/SKILL.md: frontmatter description is missing or empty' sc_check_frontmatter "$skill"

# No description key, no frontmatter, an unterminated frontmatter, an XML tag.
skill2=$(st_skill example-skill "$DS_TEST_ROOT/two")
sed -i '/^description:/d' "$skill2/SKILL.md"
st_expect_finding 'frontmatter description is missing or empty' sc_check_frontmatter "$skill2"
printf '# No frontmatter\n' >"$skill2/SKILL.md"
st_expect_finding 'C1 example-skill/SKILL.md: no frontmatter (the first line must be ---)' sc_check_frontmatter "$skill2"
printf -- '---\nname: example-skill\ndescription: Never closed.\n' >"$skill2/SKILL.md"
st_expect_finding 'C1 example-skill/SKILL.md: frontmatter is not closed by a --- line' sc_check_frontmatter "$skill2"
printf -- '---\nname: example-skill\ndescription: Uses <b>tags</b>.\n---\n' >"$skill2/SKILL.md"
st_expect_finding 'C1 example-skill/SKILL.md: description contains an XML tag' sc_check_frontmatter "$skill2"
rm "$skill2/SKILL.md"
st_expect_finding 'C1 example-skill: SKILL.md is missing or not a regular file' sc_check_frontmatter "$skill2"
ln -s ../SKILL.md "$skill2/SKILL.md"
st_expect_finding 'C1 example-skill: SKILL.md is missing or not a regular file' sc_check_frontmatter "$skill2"

# The tree: symlinks are refused (directory digests ignore them), and the
# generic privacy rules of `dotsteward scan` apply, without the matched text.
skill3=$(st_skill example-skill "$DS_TEST_ROOT/three")
ln -s commands.md "$skill3/references/alias.md"
st_expect_finding 'C1 example-skill/references/alias.md: symlinks are not allowed in a skill' sc_check_tree "$skill3"
rm "$skill3/references/alias.md"
# The home path is assembled at run time, so this file stays clean.
user="someone$RANDOM"
printf 'Notes live in /%s/%s/notes.\n' home "$user" >>"$skill3/references/commands.md"
st_expect_finding 'C1 example-skill: privacy: home-path references/commands.md:' sc_check_tree "$skill3"
assert_not_contains "$ST_OUT" "$user" "findings are redacted"
