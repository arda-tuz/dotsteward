# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C6: a list of conventional commit types in a skill equals the CLI's
# (commit.conventional_types of `dotsteward context --json` on a synthetic
# instance).
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
st_expect_clean sc_check_conventional_types "$skill"
st_expect_clean sc_check_conventional_types "$skill" --required
# The CLI was asked once per run, through --instance with a synthetic
# instance: a Git checkout of tests/fixtures/skills-contract/instance whose
# origin is its configured remote. It lives until the next sc_reset.
assert_eq 2 "$(grep -c -- ' context --json$' "$SC_FAKE_CLI_LOG")"
call=$(grep -- ' context --json$' "$SC_FAKE_CLI_LOG" | tail -n 1)
[[ $call =~ ^--instance\ (.+)\ context\ --json$ ]] || ds_fail "unexpected context call [$call]"
instance=${BASH_REMATCH[1]}
cmp "$ST_FIXTURES/instance/workstation.toml" "$instance/workstation.toml"
assert_eq 'git@github.com:example/workstation.git' "$(git -C "$instance" remote get-url origin)"
assert_eq '' "$(git -C "$instance" status --porcelain)"
sc_reset
[[ ! -e $instance ]] || ds_fail "sc_reset must remove the synthetic instance"

# The order of the list does not matter; its set does.
export SC_FAKE_CONVENTIONAL_TYPES='revert style ci build test chore docs refactor perf fix feat'
st_expect_clean sc_check_conventional_types "$skill"
export SC_FAKE_CONVENTIONAL_TYPES='feat fix perf refactor docs chore test build ci'
st_expect_finding 'C6 example-skill/SKILL.md:29: conventional commit types [build chore ci docs feat fix perf refactor revert style test] differ from the CLI [build chore ci docs feat fix perf refactor test]: extra revert style' \
  sc_check_conventional_types "$skill"
export SC_FAKE_CONVENTIONAL_TYPES='feat fix perf refactor docs chore test build ci style revert wip'
st_expect_finding 'missing wip' sc_check_conventional_types "$skill"
unset SC_FAKE_CONVENTIONAL_TYPES

# A list in a reference is checked as well; a paragraph or list item that
# names the concept without at least two types is not a list.
printf '\nConventional types come from `commit.conventional_types` of the context.\n' >>"$skill/references/commands.md"
printf '\nA conventional subject such as `feat` is enough here.\n' >>"$skill/references/commands.md"
st_expect_clean sc_check_conventional_types "$skill"
printf '\nAllowed conventional types: `feat`, `fix`.\n' >>"$skill/references/commands.md"
st_expect_finding 'C6 example-skill/references/commands.md:' sc_check_conventional_types "$skill"
assert_contains "$ST_OUT" 'missing build chore ci docs perf refactor revert style test'

# --required: a skill without any list fails; without --required it passes.
skill2=$(st_skill example-skill "$DS_TEST_ROOT/two")
st_replace "$skill2/SKILL.md" 'Use a conventional commit subject' 'Use the subject rules of the context.'
st_replace "$skill2/SKILL.md" '`build`, `ci`, `style`, `revert`' ''
st_expect_clean sc_check_conventional_types "$skill2"
st_expect_finding 'C6 example-skill: no list of conventional commit types (expected one)' \
  sc_check_conventional_types "$skill2" --required

# The CLI must answer.
export SC_FAKE_CONTEXT_FAIL=1
st_expect_finding 'C6 example-skill: `dotsteward context --json` failed on the synthetic instance' \
  sc_check_conventional_types "$skill"
export SC_FAKE_CONTEXT_FAIL=0
export SC_FAKE_CONVENTIONAL_TYPES=''
st_expect_finding 'C6 example-skill: `dotsteward context --json` has no commit.conventional_types' \
  sc_check_conventional_types "$skill"
