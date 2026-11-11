# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own skill (a repo-owned revision) that the lock widens from one agent to every agent, or
# narrows from every agent to one, keeps its copy: the copy moves with the placement. Widened,
# the copy of the scoped store moves to the shared root and every agent sees it; narrowed, the
# shared copy moves to the scoped store and only the agent of the lock sees it. Check names each
# move as a placement note and changes nothing; install moves the copies, and neither skill is
# taken for one the owner deleted. A copy with an edit that was not captured moves with its edit.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

store=$HOME/.local/share/dotsteward/scoped-skills
shared=$HOME/.agents/skills
own=same-as-instance-checkout
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills" }'
mkdir -p "$HOME/.codex/skills" "$shared"
for name in widened edited; do
  lock_add "$name" --revision "$own"
  lock_edit '(.skills[] | select(.name == $n)) += { agents: ["alpha-agent"] }' --arg n "$name"
done
lock_add narrowed --revision "$own"
assert_exit 0 run_agents install
for copy in "$store/widened" "$store/edited" "$shared/narrowed"; do
  [[ -f $copy/SKILL.md ]] || ds_fail "$copy is missing after the first install"
done
printf 'a local edit not captured yet\n' >>"$store/edited/SKILL.md"

lock_edit '(.skills[] | select(.name == "widened" or .name == "edited")) |= del(.agents)
  | (.skills[] | select(.name == "narrowed")) += { agents: ["alpha-agent"] }'

before=$(home_state)
assert_exit 0 run_agents check
for name in widened edited; do
  assert_contains "$DS_STDERR" "placement of an own skill: $store/$name moves to $shared/$name"
done
assert_contains "$DS_STDERR" "placement of an own skill: $shared/narrowed moves to $store/narrowed"
assert_not_contains "$DS_STDOUT$DS_STDERR" "not installed again"
assert_not_contains "$DS_STDOUT$DS_STDERR" "scoped skill copy not in the lock"
assert_eq "$before" "$(home_state)" "check writes nothing"

assert_exit 0 run_agents install
assert_not_contains "$DS_STDOUT$DS_STDERR" "not installed again"
assert_not_contains "$DS_STDOUT$DS_STDERR" "scoped skill copy not in the lock"
for name in widened edited; do
  assert_contains "$DS_STDOUT" "moved skill $name from $store/$name to $shared/$name"
  [[ -f $shared/$name/SKILL.md && ! -L $shared/$name ]] || ds_fail "the widened skill $name is not in the shared root"
  [[ ! -e $store/$name && ! -L $HOME/.alpha/skills/$name ]] || ds_fail "the scoped copy of $name is still seen"
done
assert_contains "$(<"$shared/edited/SKILL.md")" "a local edit not captured yet"
assert_contains "$DS_STDOUT" "skill edited: pending-capture: a local change waits for a capture; left as it is"
assert_contains "$DS_STDOUT" "moved skill narrowed from $shared/narrowed to $store/narrowed"
[[ -f $store/narrowed/SKILL.md && ! -e $shared/narrowed && ! -L $shared/narrowed ]] ||
  ds_fail "the narrowed skill is not in the scoped store alone"
assert_symlink_to "$HOME/.alpha/skills/narrowed" "$store/narrowed"

assert_exit 0 run_agents check
assert_not_contains "$DS_STDERR" "placement of an own skill"
