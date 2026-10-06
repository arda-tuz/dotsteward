# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C8: the framework upgrade step: SKILL.md names it and links
# references/framework-upgrade.md, and one file runs, in this order, a
# `gh release` command (the release notes), `nix flake update dotsteward`
# and the gate.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
upgrade=$skill/references/framework-upgrade.md
st_expect_clean sc_check_framework_upgrade "$skill"

# Release notes after the input bump, or no gate after it.
st_replace "$upgrade" 'nix flake update dotsteward' ''
printf 'nix flake update dotsteward\n' >>"$upgrade"
st_expect_finding 'C8 example-skill: no file runs `gh release` (the release notes), then `nix flake update dotsteward`, then the gate, in this order' \
  sc_check_framework_upgrade "$skill"
cp "$ST_FIXTURES/example-skill/references/framework-upgrade.md" "$upgrade"
st_replace "$upgrade" 'dotsteward gate --scope update' 'echo done'
st_expect_finding 'then `nix flake update dotsteward`, then the gate, in this order' sc_check_framework_upgrade "$skill"
cp "$ST_FIXTURES/example-skill/references/framework-upgrade.md" "$upgrade"
sed -i '/gh release/d' "$upgrade"
st_expect_finding 'then `nix flake update dotsteward`, then the gate, in this order' sc_check_framework_upgrade "$skill"
cp "$ST_FIXTURES/example-skill/references/framework-upgrade.md" "$upgrade"

# The step may live in SKILL.md itself.
cat "$upgrade" >>"$skill/SKILL.md"
printf '# Framework upgrade\n\nSee SKILL.md.\n' >"$upgrade"
st_expect_clean sc_check_framework_upgrade "$skill"
cp "$ST_FIXTURES/example-skill/SKILL.md" "$skill/SKILL.md"
cp "$ST_FIXTURES/example-skill/references/framework-upgrade.md" "$upgrade"

# SKILL.md must name the step and link its reference.
st_replace "$skill/SKILL.md" 'The command map is in `references/commands.md`; the framework upgrade step is in' \
  'The command map is in `references/commands.md`.'
st_replace "$skill/SKILL.md" '`references/framework-upgrade.md`.' ''
st_expect_finding 'C8 example-skill/SKILL.md: does not link references/framework-upgrade.md' sc_check_framework_upgrade "$skill"
assert_contains "$ST_OUT" 'C8 example-skill/SKILL.md: does not name the framework upgrade step'
