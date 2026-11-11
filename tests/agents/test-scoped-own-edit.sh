# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The sweep of the scoped skill store never loses an edit the owner made in a copy. A copy that is
# what the lock, the vendored source or the last lock of the history says goes without a trace. An own skill (a repo-owned
# revision) that the lock widens to every agent takes its copy along, with the edit that was not
# captured: install moves it to the shared root, where it waits for a capture
# (test-scoped-own-moved.sh); check says the move as a placement note. A copy of a skill that left the lock and does
# not match its vendored source (the edit of an own skill the lock dropped) is moved to the backups
# of the state root, and install names where.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

store=$HOME/.local/share/dotsteward/scoped-skills
own=same-as-instance-checkout
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills" }'
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
for name in widened dropped; do
  lock_add "$name" --revision "$own"
  lock_edit '(.skills[] | select(.name == $n)) += { agents: ["alpha-agent"] }' --arg n "$name"
done
lock_add pristine
lock_edit '(.skills[] | select(.name == "pristine")) += { agents: ["alpha-agent"] }'
assert_exit 0 run_agents install
for name in widened dropped; do
  printf 'a local edit not captured yet\n' >>"$store/$name/SKILL.md"
done

# The instance is a repository with that lock; then the lock widens one own skill to every agent
# and drops the other and the third-party skill, with their vendored sources.
git -C "$agents_inst" init -q
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore: the skills"
lock_edit '(.skills[] | select(.name == "widened")) |= del(.agents) | del(.skills[] | select(.name == "dropped" or .name == "pristine"))'
rm -rf -- "$agents_inst/agent/skills/dropped" "$agents_inst/agent/skills/pristine"

assert_exit 1 run_agents check --keep-going
assert_contains "$DS_STDERR" "placement of an own skill: $store/widened moves to $HOME/.agents/skills/widened"
assert_not_contains "$DS_STDERR" "scoped skill copy not in the lock: $store/widened"

assert_exit 0 run_agents install
# The own skill with its edit goes to the shared root and waits for a capture there.
assert_contains "$(<"$HOME/.agents/skills/widened/SKILL.md")" "a local edit not captured yet"
[[ ! -e $store/widened && ! -L $HOME/.alpha/skills/widened ]] || ds_fail "the widened copy is still in the store"
assert_contains "$DS_STDOUT" "skill widened: pending-capture: a local change waits for a capture; left as it is"
# The dropped copy with an edit is in the backups, and gone from the agents.
[[ ! -e $store/dropped && ! -L $HOME/.alpha/skills/dropped ]] || ds_fail "the dropped copy is still seen"
backup=$(grep -rl "a local edit not captured yet" "$DOTSTEWARD_STATE_ROOT/backups" 2>/dev/null | head -1)
[[ -n $backup ]] || ds_fail "the edit of the dropped copy is lost"
assert_contains "$DS_STDOUT$DS_STDERR" "scoped skill copy not in the lock had changes: $store/dropped; moved to the backup"
# The pristine third-party copy is simply gone.
[[ ! -e $store/pristine && ! -L $HOME/.alpha/skills/pristine ]] || ds_fail "the pristine copy is still there"
assert_contains "$DS_STDOUT" "removed scoped skill copy not in the lock: $store/pristine"
