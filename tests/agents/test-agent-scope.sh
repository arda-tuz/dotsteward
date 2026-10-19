# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Skills for some agents only: a lock entry with agents = [AGENT, ...] is
# installed into the scoped skill store
# ${XDG_DATA_HOME:-~/.local/share}/dotsteward/scoped-skills/<directory>,
# never into the shared root ~/.agents/skills or a link root such as
# ~/.claude/skills, and linked from the skill root of each named agent
# (manifest skill_layout.agent_roots, contributed by components), so only
# those agents load it. check verifies the copy and the links and changes
# nothing; a drifted copy is backed up and refreshed like a shared one; a
# dangling link in an agent root that points into the store is swept. An
# agent without a declared root, a home-managed scoped skill and a scoped
# skill that is also in the shared root are refused.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

store=$HOME/.local/share/dotsteward/scoped-skills
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills", "beta-agent": "~/.config/beta/skills" }'

lock_add scoped
lock_edit '(.skills[] | select(.name == "scoped")) += { agents: ["alpha-agent", "beta-agent"] }'
lock_add solo
lock_edit '(.skills[] | select(.name == "solo")) += { agents: ["beta-agent"] }'
lock_add shared
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"

# --- check on the fresh home names the missing copy and installs nothing ------------------

before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill missing: scoped; run 'dotsteward rebuild --profile workstation --switch' to install it"
assert_eq "$before" "$(home_state)" "check writes nothing"

# --- install: the store copy and the agent links, nothing shared --------------------------

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "installed skill scoped into $store/scoped"
assert_contains "$DS_STDOUT" "installed skill solo into $store/solo"
[[ -d $store/scoped && ! -L $store/scoped ]] || ds_fail "the scoped skill is a physical copy in the store"
assert_eq "$(cat "$store/scoped/SKILL.md")" "$(cat "$(vendored scoped)/SKILL.md")"
assert_symlink_to "$HOME/.alpha/skills/scoped" "$store/scoped"
assert_symlink_to "$HOME/.config/beta/skills/scoped" "$store/scoped"
assert_symlink_to "$HOME/.config/beta/skills/solo" "$store/solo"
for absent in "$HOME/.alpha/skills/solo" "$HOME/.agents/skills/scoped" "$HOME/.agents/skills/solo" \
  "$HOME/.claude/skills/scoped" "$HOME/.claude/skills/solo" "$HOME/.alpha/skills/shared"; do
  [[ ! -e $absent && ! -L $absent ]] || ds_fail "$absent must not exist"
done
# The shared skill keeps its usual places.
[[ -d $HOME/.agents/skills/shared ]] || ds_fail "the shared skill is in the shared root"
assert_symlink_to "$HOME/.claude/skills/shared" ../../.agents/skills/shared

assert_exit 0 run_agents check
assert_eq "$DS_STDOUT" "[dotsteward] agent tools and skills verified (profile workstation)"
assert_exit 0 run_agents install
assert_not_contains "$DS_STDOUT" "installed skill"

# --- drift, foreign links and sweep ----------------------------------------------------

printf 'local edit\n' >>"$store/scoped/SKILL.md"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "installed skill differs from the lock: scoped ($store/scoped)"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "skill differed from the lock; backed up and refreshed: scoped"
assert_eq "$(cat "$store/scoped/SKILL.md")" "$(cat "$(vendored scoped)/SKILL.md")"

rm -- "$HOME/.alpha/skills/scoped"
ln -s "$DS_TEST_ROOT/elsewhere" "$HOME/.alpha/skills/scoped"
mkdir -p "$DS_TEST_ROOT/elsewhere"
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "skill link points to an unexpected target: $HOME/.alpha/skills/scoped"
done
rm -- "$HOME/.alpha/skills/scoped"
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.alpha/skills/scoped" "$store/scoped"

# A link into the store whose skill is gone is dangling: check reports it,
# install removes it; a foreign dangling link stays.
ln -s "$store/retired" "$HOME/.config/beta/skills/retired"
ln -s "$DS_TEST_ROOT/not-managed" "$HOME/.config/beta/skills/foreign"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "dangling skill link not removed: $HOME/.config/beta/skills/retired"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "removed dangling skill link: $HOME/.config/beta/skills/retired"
[[ ! -L $HOME/.config/beta/skills/retired ]] || ds_fail "the dangling store link is removed"
[[ -L $HOME/.config/beta/skills/foreign ]] || ds_fail "the foreign link stays"
rm -- "$HOME/.config/beta/skills/foreign"

# --- refusals -----------------------------------------------------------------------------

# A scoped skill also in the shared root.
cp -R "$store/solo" "$HOME/.agents/skills/solo"
for mode in check install; do
  assert_exit 1 run_agents "$mode"
  assert_contains "$DS_STDERR" "skill solo is for beta-agent only but is also in the shared skill root: $HOME/.agents/skills/solo; remove it there"
done
rm -rf -- "$HOME/.agents/skills/solo"

# An agent without a declared root.
lock_edit '(.skills[] | select(.name == "solo")) .agents = ["gamma-agent"]'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill solo names the agent gamma-agent, which has no skill root (known: alpha-agent, beta-agent)"

# The lock shape: a non-empty list of plain, unique names, copy deployment only.
lock_edit '(.skills[] | select(.name == "solo")) .agents = []'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill solo: agents must be a non-empty list of plain agent names"
lock_edit '(.skills[] | select(.name == "solo")) .agents = ["beta-agent", "beta-agent"]'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill solo: agents must be a non-empty list of plain agent names"
lock_edit '(.skills[] | select(.name == "solo")) .agents = ["beta-agent"] | (.skills[] | select(.name == "solo")) .deployment = "home-manager"'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill solo: agents needs the copy deployment"
lock_edit '(.skills[] | select(.name == "solo")) .deployment = "copy"'

# --- XDG_DATA_HOME moves the store -------------------------------------------------------

rm -- "$HOME/.alpha/skills/scoped" "$HOME/.config/beta/skills/scoped" "$HOME/.config/beta/skills/solo"
export XDG_DATA_HOME=$DS_TEST_ROOT/xdg-data
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill missing: scoped"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "installed skill scoped into $XDG_DATA_HOME/dotsteward/scoped-skills/scoped"
assert_symlink_to "$HOME/.alpha/skills/scoped" "$XDG_DATA_HOME/dotsteward/scoped-skills/scoped"
assert_exit 0 run_agents check
