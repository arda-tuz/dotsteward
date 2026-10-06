# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C7: the overlay precedence sentence, the classification step (context,
# then overlay, then classification, before the first write of the flow),
# the canonical references/classification.md and the hand-over skill.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
md=$skill/SKILL.md
st_expect_clean sc_check_precedence "$skill"
st_expect_clean sc_check_classification "$skill" dotsteward-contribute

# The sentence may be wrapped and emphasized, but its words are exact.
sentence='On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.'
st_replace "$md" "$sentence" $'**On the gate, publish preconditions, decision ownership, secrets,\nforce push and the local-only rule, this skill wins over any overlay.**'
st_expect_clean sc_check_precedence "$skill"
st_replace "$md" '**On the gate' 'On the gate, publish preconditions, secrets,'
st_expect_finding 'C7 example-skill/SKILL.md: the overlay precedence sentence is missing' sc_check_precedence "$skill"
cp "$ST_FIXTURES/example-skill/SKILL.md" "$md"

# The classification reference must be the canonical bytes.
printf '\nA private addition.\n' >>"$skill/references/classification.md"
st_expect_finding 'C7 example-skill/references/classification.md: differs from the canonical tests/fixtures/skills-contract/classification.md' \
  sc_check_classification "$skill" dotsteward-contribute
rm "$skill/references/classification.md"
st_expect_finding 'C7 example-skill/references/classification.md: missing' \
  sc_check_classification "$skill" dotsteward-contribute
cp "$ST_FIXTURES/classification.md" "$skill/references/classification.md"

# The hand-over skill must be named in SKILL.md.
st_expect_finding 'C7 example-skill/SKILL.md: does not hand over to dotsteward-maintain' \
  sc_check_classification "$skill" dotsteward-maintain

# Order: context --json, then an overlay mention, then the classification
# reference, then the first write of the flow.
st_replace "$md" 'dotsteward context --json' 'true'
st_expect_finding 'C7 example-skill/SKILL.md: `dotsteward context --json` is never run' \
  sc_check_classification "$skill" dotsteward-contribute
cp "$ST_FIXTURES/example-skill/SKILL.md" "$md"
st_replace "$md" '2. If the context names an overlay for this skill, read it now.' '2. Read nothing else.'
st_expect_finding 'C7 example-skill/SKILL.md: no overlay step after `dotsteward context --json`' \
  sc_check_classification "$skill" dotsteward-contribute
cp "$ST_FIXTURES/example-skill/SKILL.md" "$md"
st_replace "$md" '3. Classify the request with `references/classification.md` before any write. Framework and mixed' \
  '3. Framework and mixed'
printf '\nThe classes are in references/classification.md.\n' >>"$md"
st_expect_finding 'C7 example-skill/SKILL.md:' sc_check_classification "$skill" dotsteward-contribute
assert_contains "$ST_OUT" 'the first write (`dotsteward update prepare`) comes before the classification step (references/classification.md)'
cp "$ST_FIXTURES/example-skill/SKILL.md" "$md"
st_replace "$md" '3. Classify the request with `references/classification.md` before any write. Framework and mixed' \
  '3. Framework and mixed'
st_expect_finding 'C7 example-skill/SKILL.md: no classification step (references/classification.md) after the overlay step' \
  sc_check_classification "$skill" dotsteward-contribute
