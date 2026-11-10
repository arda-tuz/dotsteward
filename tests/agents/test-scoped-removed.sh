# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A skill for some agents only that leaves the lock leaves the machine too: install removes its
# copy in the scoped skill store and the links of the agent roots to it, so the agents stop
# loading it; check names a copy the lock no longer has and changes nothing. The same holds for
# an entry that is no longer scoped. Every directory of the store is one dotsteward put there.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

store=$HOME/.local/share/dotsteward/scoped-skills
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills", "beta-agent": "~/.config/beta/skills" }'
lock_add gone
lock_edit '(.skills[] | select(.name == "gone")) += { agents: ["alpha-agent", "beta-agent"] }'
lock_add kept
lock_edit '(.skills[] | select(.name == "kept")) += { agents: ["beta-agent"] }'
lock_add widened
lock_edit '(.skills[] | select(.name == "widened")) += { agents: ["alpha-agent"] }'
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
assert_exit 0 run_agents install
[[ -d $store/gone && -d $store/kept && -d $store/widened ]] || ds_fail "the scoped copies are in the store"

# One entry leaves the lock, one is for every agent now.
lock_edit 'del(.skills[] | select(.name == "gone")) | (.skills[] | select(.name == "widened")) |= del(.agents)'

before=$(home_state)
assert_exit 1 run_agents check --keep-going
assert_contains "$DS_STDERR" "scoped skill copy not in the lock: $store/gone; run 'dotsteward rebuild --profile workstation --switch' to remove it"
assert_contains "$DS_STDERR" "scoped skill copy not in the lock: $store/widened"
assert_eq "$before" "$(home_state)" "check writes nothing"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "removed scoped skill copy not in the lock: $store/gone"
for absent in "$store/gone" "$HOME/.alpha/skills/gone" "$HOME/.config/beta/skills/gone" \
  "$store/widened" "$HOME/.alpha/skills/widened"; do
  [[ ! -e $absent && ! -L $absent ]] || ds_fail "$absent must be gone"
done
[[ -d $HOME/.agents/skills/widened ]] || ds_fail "the widened skill is in the shared root"
assert_symlink_to "$HOME/.config/beta/skills/kept" "$store/kept"
assert_exit 0 run_agents check
