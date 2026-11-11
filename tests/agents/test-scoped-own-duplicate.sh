# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own skill (a repo-owned revision) with a copy at both placements, the scoped store and the
# shared root (left by an earlier release, or copied by hand), when the lock widens or narrows it:
# the copy with the edit that was not captured wins and moves to the placement of the lock, the
# copy that is what the lock says goes to the backups of the state root, and the agents all see
# the edited copy. Check names it as a placement note and changes nothing. When both copies have
# edits of their own, install stops and names both, keeping both: the owner keeps the edited copy
# that should stay at the placement of the lock and captures it; nothing says to remove an edit.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

store=$HOME/.local/share/dotsteward/scoped-skills
shared=$HOME/.agents/skills
own=same-as-instance-checkout
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills" }'
mkdir -p "$HOME/.codex/skills" "$shared"
lock_add narrowed --revision "$own"
lock_add widened --revision "$own"
lock_edit '(.skills[] | select(.name == "widened")) += { agents: ["alpha-agent"] }'
assert_exit 0 run_agents install
# Narrowed: a stale copy in the store, the edit in the shared copy. Widened: a stale copy in the
# shared root, the edit in the store copy.
cp -R -- "$shared/narrowed" "$store/narrowed"
printf 'an edit in the shared copy\n' >>"$shared/narrowed/SKILL.md"
cp -R -- "$store/widened" "$shared/widened"
printf 'an edit in the store copy\n' >>"$store/widened/SKILL.md"
lock_edit '(.skills[] | select(.name == "widened")) |= del(.agents)
  | (.skills[] | select(.name == "narrowed")) += { agents: ["alpha-agent"] }'

before=$(home_state)
assert_exit 0 run_agents check
assert_contains "$DS_STDERR" "placement of an own skill: $shared/narrowed moves to $store/narrowed"
assert_contains "$DS_STDERR" "placement of an own skill: $store/widened moves to $shared/widened"
assert_not_contains "$DS_STDERR" "remove it there"
assert_eq "$before" "$(home_state)" "check writes nothing"

assert_exit 0 run_agents install
assert_contains "$(<"$store/narrowed/SKILL.md")" "an edit in the shared copy"
[[ ! -e $shared/narrowed && ! -L $shared/narrowed ]] || ds_fail "the narrowed skill is still in the shared root"
assert_symlink_to "$HOME/.alpha/skills/narrowed" "$store/narrowed"
assert_contains "$(<"$shared/widened/SKILL.md")" "an edit in the store copy"
[[ ! -e $store/widened && ! -L $HOME/.alpha/skills/widened ]] || ds_fail "the widened skill is still in the store"
for name in narrowed widened; do
  assert_contains "$DS_STDOUT" "skill $name: pending-capture: a local change waits for a capture; left as it is"
done
backups=$(find "$DOTSTEWARD_STATE_ROOT/backups" -name SKILL.md 2>/dev/null | wc -l)
assert_eq 2 "$backups" "the copies that were what the lock says, in the backups"
assert_exit 0 run_agents check
assert_not_contains "$DS_STDERR" "placement of an own skill"

# Both copies have edits of their own: install stops, names both and removes neither.
cp -R -- "$store/narrowed" "$shared/narrowed"
printf 'another edit in the shared copy\n' >>"$shared/narrowed/SKILL.md"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "own skill narrowed has two copies with edits of their own: $store/narrowed and $shared/narrowed"
assert_contains "$DS_STDERR" "keep the edited copy that should stay in $store/narrowed and capture it with 'dotsteward skills capture --name narrowed'"
assert_not_contains "$DS_STDERR" "remove it there"
assert_contains "$(<"$shared/narrowed/SKILL.md")" "another edit in the shared copy"
assert_contains "$(<"$store/narrowed/SKILL.md")" "an edit in the shared copy"
