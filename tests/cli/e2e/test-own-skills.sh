# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# The green rule of skill tracking: an instance that has local skills and never asked
# for tracking behaves as before. `e2e` stays green whatever the user did to a skill of
# their own, says what it saw and leaves the copy alone; the checkout may be behind what
# another machine published. Nothing writes hook settings. A third-party skill keeps its
# finding.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

export DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/state
copy=$HOME/.agents/skills/mine

lock_add mine --revision same-as-instance-checkout
lock_add theirs
assert_exit 0 run_agents install
publish_instance "chore: an own skill and a third-party skill"

# green_with TEXT: e2e passes, says TEXT, and the copy still has what the user wrote.
green_with() {
  assert_exit 0 run_e2e
  assert_contains "$DS_STDOUT" "e2e checks passed"
  assert_contains "$DS_STDOUT$DS_STDERR" "$1"
}

assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "e2e checks passed"
assert_not_contains "$DS_STDOUT$DS_STDERR" "skill mine:"

# The user changes their skill.
printf 'my change\n' >>"$copy/SKILL.md"
green_with "skill mine: pending-capture"
assert_contains "$(cat "$copy/SKILL.md")" "my change"

# Another machine published this skill and the checkout has not caught up.
other=$DS_TEST_ROOT/other-clone
git clone -q "$e2e_bare" "$other"
printf 'their change\n' >>"$other/agent/skills/mine/SKILL.md"
digest=$(bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$other/agent/skills/mine")
jq --arg digest "$digest" --arg skill "$(sha256sum -- "$other/agent/skills/mine/SKILL.md" | awk '{print $1}')" \
  '(.skills[] | select(.name == "mine")) |= (.directory_sha256 = $digest | .skill_sha256 = $skill)' \
  "$other/agent/skills.lock.json" >"$DS_TEST_ROOT/lock.json"
cp -- "$DS_TEST_ROOT/lock.json" "$other/agent/skills.lock.json"
git -C "$other" add -A
git -C "$other" commit -q -m "chore(skills): capture mine"
git -C "$other" push -q origin main
green_with "1 commit behind origin main"
assert_contains "$DS_STDOUT$DS_STDERR" "skill mine: pending-capture"
assert_contains "$(cat "$copy/SKILL.md")" "my change"

# The checkout catches up: both sides changed it, and that is a question, not a failure.
git -C "$agents_inst" pull -q --ff-only origin main
green_with "skill mine: conflict"
assert_contains "$(cat "$copy/SKILL.md")" "my change"
assert_exit 0 run_agents install
assert_contains "$(cat "$copy/SKILL.md")" "my change"
assert_not_contains "$(cat "$copy/SKILL.md")" "their change"
assert_exit 0 run_e2e

# A third-party skill keeps its finding.
printf 'a local edit\n' >>"$HOME/.agents/skills/theirs/SKILL.md"
assert_exit 1 run_e2e --json
assert_contains "$DS_STDOUT" "skill-drift"
assert_not_contains "$DS_STDOUT" '"path": "'"$copy"
assert_exit 0 run_agents install
assert_exit 0 run_e2e

# No command wrote hook settings for an instance that did not ask for them.
for file in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" "$HOME/.config/dotsteward/hook-context.json"; do
  [[ ! -e $file ]] || ds_fail "written without tracking: $file"
done
assert_eq "" "$(git -C "$agents_inst" status --porcelain)" "the checkout changed"
