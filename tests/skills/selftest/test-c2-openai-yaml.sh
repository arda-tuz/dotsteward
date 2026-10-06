# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C2: agents/openai.yaml has interface.display_name, short_description and a
# default_prompt that mentions $<name>.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
yaml=$skill/agents/openai.yaml
st_expect_clean sc_check_openai_yaml "$skill"

# Unquoted and single-quoted values, comments and extra keys are fine.
cat >"$yaml" <<'YAML'
# Codex interface metadata
interface:
  display_name: Example Skill
  short_description: 'Synthetic skill'
  default_prompt: "Use $example-skill now."
  brand_color: "#336699"
policy:
  allow_implicit_invocation: true
YAML
st_expect_clean sc_check_openai_yaml "$skill"

# Each required key, empty or missing.
for key in display_name short_description default_prompt; do
  cp "$ST_FIXTURES/example-skill/agents/openai.yaml" "$yaml"
  sed -i "/^  $key:/d" "$yaml"
  st_expect_finding "C2 example-skill/agents/openai.yaml: interface.$key is missing or empty" sc_check_openai_yaml "$skill"
  cp "$ST_FIXTURES/example-skill/agents/openai.yaml" "$yaml"
  sed -i "s/^  $key:.*/  $key: \"\"/" "$yaml"
  st_expect_finding "C2 example-skill/agents/openai.yaml: interface.$key is missing or empty" sc_check_openai_yaml "$skill"
done

# A key outside the interface mapping does not count.
cat >"$yaml" <<'YAML'
display_name: "Example Skill"
interface:
  short_description: "Synthetic skill"
  default_prompt: "Use $example-skill now."
YAML
st_expect_finding 'interface.display_name is missing or empty' sc_check_openai_yaml "$skill"

# The default prompt must invoke the skill by its own name.
cp "$ST_FIXTURES/example-skill/agents/openai.yaml" "$yaml"
sed -i 's/\$example-skill/$other-skill/' "$yaml"
st_expect_finding 'C2 example-skill/agents/openai.yaml: interface.default_prompt does not mention $example-skill' \
  sc_check_openai_yaml "$skill"
sed -i 's/\$other-skill/example-skill/' "$yaml"
st_expect_finding 'interface.default_prompt does not mention $example-skill' sc_check_openai_yaml "$skill"
# A longer name that starts with the skill name is a different skill.
sed -i 's/example-skill/$example-skill-two/' "$yaml"
st_expect_finding 'interface.default_prompt does not mention $example-skill' sc_check_openai_yaml "$skill"

rm "$yaml"
st_expect_finding 'C2 example-skill: agents/openai.yaml is missing or not a regular file' sc_check_openai_yaml "$skill"
