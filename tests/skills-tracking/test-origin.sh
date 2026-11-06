# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Where a new skill comes from decides what happens to it. A file tool of an
# agent wrote its SKILL.md and nothing says it was downloaded: tracked without a
# question. A record of `npx skills` or a .git directory: downloaded, a question.
# Anything else no file tool touched: unknown, a question. What belongs to others
# (claude.ai sync, framework skills, Codex system skills, plugin and project
# skills) never becomes a candidate.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

install_hooks claude codex

new_skill() {
  mkdir -p "$1"
  printf -- '---\nname: %s\n---\n' "${1##*/}" >"$1/SKILL.md"
}

reconcile_json() {
  assert_exit 0 ds_cli skills reconcile --json
}

item() {
  jq -c --arg key "skill:$1" '.items[$key] // {}' "$ss/pending.json"
}

# --- row 1: a record of `npx skills` -------------------------------------------------

new_skill "$HOME/.agents/skills/recorded"
cat >"$HOME/.agents/.skill-lock.json" <<'JSON'
{"version": 3, "skills": {"recorded": {
  "source": "example-org/example-skills",
  "sourceType": "github",
  "sourceUrl": "https://github.com/example-org/example-skills.git",
  "skillPath": "skills/recorded/SKILL.md",
  "skillFolderHash": "0123456789012345678901234567890123456789"}}}
JSON
reconcile_json
assert_json - '.items["skill:recorded"] | .state == "ask" and .origin == "downloaded"
  and .source.url == "https://github.com/example-org/example-skills.git" and .source.path == "skills/recorded/SKILL.md"
  and .source.tree == "0123456789012345678901234567890123456789"' <<<"$DS_STDOUT"

# --- row 2: a .git directory -------------------------------------------------------------

mkdir -p "$DS_TEST_ROOT/upstream"
git init -q "$DS_TEST_ROOT/upstream"
new_skill "$DS_TEST_ROOT/upstream"
git -C "$DS_TEST_ROOT/upstream" add -A
git -C "$DS_TEST_ROOT/upstream" commit -q -m "chore: a skill"
git clone -q "$DS_TEST_ROOT/upstream" "$HOME/.agents/skills/cloned"
reconcile_json
assert_eq "$(git -C "$DS_TEST_ROOT/upstream" rev-parse HEAD)" "$(jq -r '.items["skill:cloned"].source.revision' <<<"$DS_STDOUT")"
assert_eq "$DS_TEST_ROOT/upstream" "$(jq -r '.items["skill:cloned"].source.url' <<<"$DS_STDOUT")"
assert_eq ask "$(pending_state cloned)"
# A file tool writing into a downloaded skill does not make it the user's.
agent_event claude PostToolUse post-tool-use-edit "$HOME/.agents/skills/cloned/SKILL.md"
assert_json "$ss/pending.json" '.items["skill:cloned"].origin == "downloaded" and .items["skill:cloned"].state == "ask"'

# --- row 3: a file tool wrote SKILL.md ------------------------------------------------------

# Claude Code writes a new skill into its own skill root.
new_skill "$HOME/.claude/skills/written"
agent_event claude PostToolUse post-tool-use-write "$HOME/.claude/skills/written/SKILL.md"
assert_json "$ss/pending.json" '.items["skill:written"] | .state == "capture" and .origin == "own"
  and .evidence.agent == "claude" and .evidence.tool == "Write"
  and .path != null'
# A Bash tool that made the tree, then a file tool that edits SKILL.md, as Codex's
# skill creator does: own.
new_skill "$HOME/.codex/skills/initialized"
assert_exit 0 ds_cli skills reconcile
assert_eq ask "$(pending_state initialized)"
agent_event claude PostToolUse post-tool-use-edit "$HOME/.codex/skills/initialized/SKILL.md"
assert_json "$ss/pending.json" '.items["skill:initialized"] | .state == "capture" and .origin == "own"'
# Another file of a skill that is on its way moves the deadline with it.
_kill_sleepers
rm -f "$ss/deadline"
mkdir -p "$HOME/.claude/skills/written/references"
agent_event claude PostToolUse post-tool-use-write "$HOME/.claude/skills/written/references/note.md"
[[ -f $ss/deadline ]] || ds_fail "another file of a new skill arms the deadline"
# Another file of a tree no tool created is no evidence.
new_skill "$HOME/.agents/skills/other-file"
mkdir -p "$HOME/.agents/skills/other-file/references"
agent_event claude PostToolUse post-tool-use-write "$HOME/.agents/skills/other-file/references/note.md"
assert_exit 0 ds_cli skills reconcile
assert_eq ask "$(pending_state other-file)"
# `claude plugin init`: reported as an own plugin, no question.
mkdir -p "$HOME/.claude/skills/own-plugin/.claude-plugin"
printf '{"name": "own-plugin"}\n' >"$HOME/.claude/skills/own-plugin/.claude-plugin/plugin.json"
reconcile_json
assert_json - '.items["plugin:own-plugin"] | .kind == "plugin" and .origin == "own"' <<<"$DS_STDOUT"

# --- a subagent's Write counts as evidence, without a question ------------------------------

new_skill "$HOME/.claude/skills/by-subagent"
agent_event claude PostToolUse post-tool-use-subagent "$HOME/.claude/skills/by-subagent/SKILL.md"
assert_exit 0 ds_cli skills reconcile
assert_json "$ss/pending.json" '.items["skill:by-subagent"] | .state == "capture" and .origin == "own"'

# --- Codex: apply_patch names the paths in its patch, relative to cwd ------------------------

new_skill "$HOME/.codex/skills/patched"
EVENT_CWD=$HOME/.codex/skills
agent_event codex PostToolUse post-tool-use-apply-patch
unset EVENT_CWD
assert_json "$ss/pending.json" '.items["skill:patched"] | .state == "capture" and .origin == "own"
  and .evidence.agent == "codex" and .evidence.tool == "apply_patch"'

# The patch can name a moved file, and a removal is no evidence.
new_skill "$HOME/.codex/skills/moved"
new_skill "$HOME/.codex/skills/removed"
EVENT_CWD=$HOME/.codex/skills
agent_event codex PostToolUse post-tool-use-apply-patch-move
unset EVENT_CWD
assert_json "$ss/pending.json" '.items["skill:moved"] | .state == "capture" and .origin == "own"'
assert_exit 0 ds_cli skills reconcile
assert_eq ask "$(pending_state removed)"
# An absolute path works as well.
new_skill "$HOME/.codex/skills/updated"
agent_event codex PostToolUse post-tool-use-apply-patch-update "$HOME/.codex/skills/updated/SKILL.md"
assert_json "$ss/pending.json" '.items["skill:updated"].origin == "own"'
rm -rf "$HOME/.codex/skills/moved" "$HOME/.codex/skills/removed" "$HOME/.codex/skills/updated"

# --- row 4: nothing says where it came from ----------------------------------------------------

new_skill "$HOME/.agents/skills/unzipped"
agent_event claude PostToolUse post-tool-use-bash "$HOME/.agents/skills/unzipped/SKILL.md"
assert_exit 0 ds_cli skills reconcile
assert_json "$ss/pending.json" '.items["skill:unzipped"] | .state == "ask" and .origin == "unknown"'

# --- what belongs to others never becomes a candidate -------------------------------------------

rm -f "$ss/pending.json"
rm -rf "$HOME/.agents/skills"/* "$HOME/.claude/skills"/* "$HOME/.codex/skills"/*
new_skill "$HOME/.claude/skills/synced/from-claude-ai"
mkdir -p "$HOME/.claude/skills/synced"
new_skill "$HOME/.claude/skills/synced"
new_skill "$HOME/.agents/skills/dotsteward-maintain"
new_skill "$HOME/.codex/skills/.system"
new_skill "$HOME/.agents/skills/.hidden"
new_skill "$HOME/.claude/plugins/cache/market/plugin/skills/plugin-skill"
new_skill "$DS_TEST_ROOT/work/.claude/skills/project-skill"
new_skill "$agents_inst/agent/skills/vendored-elsewhere"
for path in "$HOME/.claude/skills/synced/from-claude-ai/SKILL.md" "$HOME/.agents/skills/dotsteward-maintain/SKILL.md" \
  "$HOME/.codex/skills/.system/SKILL.md" "$HOME/.claude/plugins/cache/market/plugin/skills/plugin-skill/SKILL.md" \
  "$DS_TEST_ROOT/work/.claude/skills/project-skill/SKILL.md" "$agents_inst/agent/skills/vendored-elsewhere/SKILL.md"; do
  agent_event claude PostToolUse post-tool-use-write "$path"
done
reconcile_json
assert_json - '.items == {}' <<<"$DS_STDOUT"
rm -rf "$agents_inst/agent/skills/vendored-elsewhere" "$HOME/.claude/skills/synced" "$HOME/.agents/skills/dotsteward-maintain" \
  "$HOME/.codex/skills/.system" "$HOME/.agents/skills/.hidden"
# A link into the store of scoped skills or of a generation is no candidate.
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills" }'
install_hooks claude
mkdir -p "$HOME/.alpha/skills"
store=$HOME/.local/share/dotsteward/scoped-skills
new_skill "$store/scoped-copy"
ln -s "$store/scoped-copy" "$HOME/.alpha/skills/scoped-copy"
reconcile_json
assert_json - '.items == {}' <<<"$DS_STDOUT"
rm -rf "$HOME/.alpha/skills/scoped-copy" "$store/scoped-copy"

# --- lock entries: an own skill is captured, a pinned one is only reported --------------------

own_skill mine
third=$HOME/.agents/skills/pinned
lock_add pinned --tree
lock_edit '(.skills[] | select(.name == "pinned")) += {revision: "0123456789012345678901234567890123456789", source: "https://github.com/example-org/pinned"}'
cp -a "$(vendored pinned)" "$third"
assert_exit 0 run_agents install
reconcile_json
assert_json - '.items == {}' <<<"$DS_STDOUT"
_kill_sleepers
rm -f "$ss/deadline" "$ss/capture.log"
agent_event claude PostToolUse post-tool-use-edit "$third/SKILL.md"
assert_eq local-edit "$(pending_state pinned)"
[[ ! -e $ss/deadline ]] || ds_fail "a pinned skill is not captured"
# A change an own skill got through Bash is seen by the Stop reconcile.
printf 'changed with a shell\n' >>"$HOME/.agents/skills/mine/SKILL.md"
touch -d '+2 seconds' "$HOME/.agents/skills/mine/SKILL.md"
AGENT_ENV=(DOTSTEWARD_CAPTURE_DELAY=600)
agent_event claude Stop stop
AGENT_ENV=()
assert_json "$ss/pending.json" '.items["skill:mine"] | .state == "capture" and .origin == "own"'
[[ -e $ss/deadline ]] || ds_fail "a change through Bash arms the deadline at Stop"
# Back as it was: nothing to capture any more.
cp -a "$(vendored mine)/SKILL.md" "$HOME/.agents/skills/mine/SKILL.md"
touch -d '+4 seconds' "$HOME/.agents/skills/mine/SKILL.md"
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state mine)"

# A home-managed entry belongs to its generation: no evidence, no capture.
lock_add generation-bound --revision "$own_revision" --deployment home-manager
store_copy=$agents_store/hm-generation-bound
cp -a "$(vendored generation-bound)" "$store_copy"
ln -s "$store_copy" "$HOME/.agents/skills/generation-bound"
agent_event claude PostToolUse post-tool-use-edit "$HOME/.agents/skills/generation-bound/SKILL.md"
assert_eq none "$(pending_state generation-bound)"
assert_exit 0 ds_cli skills reconcile --full
assert_eq none "$(pending_state generation-bound)"

# --- a skill deleted here: two looks, so that a refresh in flight is no deletion -----------------

mv "$HOME/.agents/skills/mine" "$DS_TEST_ROOT/mine-moved"
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state mine)"
assert_json "$ss/pending.json" '.missing["skill:mine"] != null'
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state mine)"
# It came back within the window: forgotten.
mv "$DS_TEST_ROOT/mine-moved" "$HOME/.agents/skills/mine"
assert_exit 0 ds_cli skills reconcile
assert_json "$ss/pending.json" '(.missing // {}) | has("skill:mine") | not'
# Gone for 60 seconds and more: deleted.
mv "$HOME/.agents/skills/mine" "$DS_TEST_ROOT/mine-moved"
assert_exit 0 ds_cli skills reconcile
jq '.missing["skill:mine"] -= 120' "$ss/pending.json" >"$ss/pending.tmp"
mv -- "$ss/pending.tmp" "$ss/pending.json"
assert_exit 0 ds_cli skills reconcile
assert_eq deleted "$(pending_state mine)"
mv "$DS_TEST_ROOT/mine-moved" "$HOME/.agents/skills/mine"
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state mine)"

# --- a name held by another machine, and an answer "never" --------------------------------------

export DOTSTEWARD_MACHINE=here
install_hooks claude
lock_add elsewhere --revision "$own_revision"
lock_edit '(.skills[] | select(.name == "elsewhere")) += {machines: ["there"]}'
new_skill "$HOME/.agents/skills/elsewhere"
assert_exit 0 ds_cli skills reconcile
assert_eq name-taken "$(pending_state elsewhere)"
mkdir -p "$agents_inst/hosts"
printf 'schema_version = 1\n[declined]\nskills = ["refused"]\n' >"$agents_inst/hosts/here.toml"
new_skill "$HOME/.agents/skills/refused"
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state refused)"

# --- mtime-preserving copies: a full reconcile reads every own skill ------------------------------

printf 'copied with its time\n' >>"$HOME/.agents/skills/mine/SKILL.md"
touch -d '2001-01-01' "$HOME/.agents/skills/mine/SKILL.md"
assert_exit 0 ds_cli skills reconcile
assert_eq none "$(pending_state mine)"
assert_exit 0 ds_cli skills reconcile --full
assert_eq capture "$(pending_state mine)"
