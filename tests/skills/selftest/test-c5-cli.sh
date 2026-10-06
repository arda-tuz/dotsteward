# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C5: every `dotsteward <sub> [--flag]` in a fenced block of SKILL.md or a
# reference exists: `dotsteward <sub> --help` succeeds and prints every flag
# (and the step word of two-word commands such as `update prepare`).
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"

skill=$(st_skill)
commands=$skill/references/commands.md

# The fixture uses pipes, command substitutions, redirections, assignments,
# `timeout`, `if`, subshells, line continuations, global --instance, the
# launcher form and both fence styles; prose, comments, placeholders and a
# `dotsteward` that is not in command position are ignored.
st_expect_clean sc_check_cli "$skill"
# Every command was asked for its help, the one-word commands and the steps;
# --help of a command is asked only once.
calls=$(<"$SC_FAKE_CLI_LOG")
for expected in 'context --help' 'gate --help' 'e2e --help' 'rebuild --help' 'update --help' \
  'update prepare --help' 'update status --help' 'update publish --help'; do
  [[ $'\n'$calls$'\n' == *$'\n'"$expected"$'\n'* ]] || ds_fail "help not asked: [$expected] in [$calls]"
done
assert_eq 1 "$(grep -c -x 'gate --help' "$SC_FAKE_CLI_LOG")" "help is cached"
assert_not_contains "$calls" 'not-a-flag'
assert_not_contains "$calls" '<command>'

add_block() {
  printf '\n```bash\n%s\n```\n' "$1" >>"$commands"
}
reset_commands() {
  cp "$ST_FIXTURES/example-skill/references/commands.md" "$commands"
}

# An unknown command.
add_block 'dotsteward nosuch --json'
st_expect_finding 'C5 example-skill/references/commands.md:27: `dotsteward nosuch`: no such command (`dotsteward nosuch --help` exited 1)' \
  sc_check_cli "$skill"
reset_commands

# An unknown flag, in the main command and inside a command substitution.
add_block 'dotsteward gate --scope maintain --no-such-flag'
st_expect_finding 'C5 example-skill/references/commands.md:27: `dotsteward gate`: --no-such-flag is not in its --help' \
  sc_check_cli "$skill"
reset_commands
add_block 'dotsteward e2e --expected-remote-base "$(dotsteward update status --base-oid)"'
st_expect_finding '`dotsteward update status`: --base-oid is not in its --help' sc_check_cli "$skill"
reset_commands

# A flag known only to another command does not count, and `--flag=value`
# is checked by its name.
add_block 'dotsteward rebuild --profile main --scope=update'
st_expect_finding '`dotsteward rebuild`: --scope is not in its --help' sc_check_cli "$skill"
reset_commands

# A step that the command does not list.
add_block 'dotsteward update rollback --scope update'
st_expect_finding '`dotsteward update rollback`: rollback is not in `dotsteward update --help`' sc_check_cli "$skill"
reset_commands

# The flags of a step may come from the step's own --help (update prepare)
# or the command's (update publish).
add_block 'dotsteward update prepare --official-sources-only'
add_block 'dotsteward update publish --expected-base "$base"'
st_expect_clean sc_check_cli "$skill"
reset_commands

# An unknown global flag, and the launcher form of an unknown command.
add_block 'dotsteward --verbose gate --scope update'
st_expect_finding '`dotsteward`: --verbose is not in its --help' sc_check_cli "$skill"
assert_eq 1 "$(grep -c -x -- '--help' "$SC_FAKE_CLI_LOG")" "the top-level help is asked for global flags"
reset_commands
add_block './.dotsteward/cli.sh nosuch'
st_expect_finding '`dotsteward nosuch`: no such command' sc_check_cli "$skill"
reset_commands

# Commands in SKILL.md count too; prose outside fences does not.
printf '\n```sh\ndotsteward gate --nope\n```\n' >>"$skill/SKILL.md"
printf 'Run dotsteward nosuch --whatever in prose.\n' >>"$skill/SKILL.md"
st_expect_finding 'C5 example-skill/SKILL.md:' sc_check_cli "$skill"
assert_contains "$ST_OUT" '`dotsteward gate`: --nope is not in its --help'
assert_not_contains "$ST_OUT" 'nosuch'

# An unclosed fence is a finding (the rest of the file would be ignored).
cp "$ST_FIXTURES/example-skill/SKILL.md" "$skill/SKILL.md"
printf '\n```bash\ndotsteward gate --scope update\n' >>"$skill/SKILL.md"
st_expect_finding 'C5 example-skill/SKILL.md: unclosed fenced block' sc_check_cli "$skill"
