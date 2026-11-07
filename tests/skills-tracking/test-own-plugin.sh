# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin of Claude Code (design 4.7): a directory in ~/.claude/skills with a
# .claude-plugin/plugin.json, which `claude plugin init` makes and Claude Code loads as
# <name>@skills-dir. It is tracked without a question, like an own skill: the copy lands in
# agent/plugins/<directory> with an own_plugins entry of the lock, another machine gets it
# as a real directory from `agents install`, a local change there is never overwritten, and
# --here keeps it to one machine. A clone of somebody else's plugin is asked about, and an
# update of what is not tracked never tracks it. Nothing here starts claude or codex.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
plugin=$(home_of a)/.claude/skills/example-plugin
start=$(remote_tip)

# --- a file tool wrote plugin.json: tracked, no question --------------------------------

new_plugin a example-plugin
tool_wrote a "$plugin/.claude-plugin/plugin.json"
assert_eq capture "$(plugin_item a example-plugin .state)"
assert_eq own "$(plugin_item a example-plugin .origin)"
assert_eq plugin "$(plugin_item a example-plugin .kind)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
HOOK_ENV=()
assert_not_contains "$HOOK_OUT" example-plugin "an own plugin is no question"
settle_plugin a example-plugin
ds_code a skills capture --now --json
assert_json - '.status == "ok" and .captured == ["example-plugin"]' <<<"$DS_STDOUT"
tip=$(remote_tip)
assert_eq "$start" "$(git -C "$remote" rev-parse "$tip^")" "one commit on the old tip"
assert_eq "chore(plugins): capture example-plugin" "$(git -C "$remote" log -1 --format=%s "$tip")"
entry=$(remote_plugin example-plugin)
assert_json - '.name == "example-plugin" and .directory == "example-plugin" and .agents == ["claude"]
  and (.directory_sha256 | length == 64) and (has("machines") | not)' <<<"$entry"
assert_eq "$(local_digest "$plugin")" "$(jq -r .directory_sha256 <<<"$entry")"
assert_eq "$(cat "$plugin/.claude-plugin/plugin.json")" "$(remote_file agent/plugins/example-plugin/.claude-plugin/plugin.json)"
assert_eq "$(cat "$plugin/skills/example-plugin-helper/SKILL.md")" \
  "$(remote_file agent/plugins/example-plugin/skills/example-plugin-helper/SKILL.md)"
# A plugin is no skill: the skills of the lock stay as they were.
assert_eq '["example-skill"]' "$(remote_lock '[.skills[].name]')"
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/example-plugin/.claude-plugin/plugin.json 2>/dev/null; then
  ds_fail "a plugin does not land among the skills"
fi
assert_eq "$(jq -r .directory_sha256 <<<"$entry")" "$(plugin_base a example-plugin)"
assert_eq "{}" "$(plugin_item a example-plugin .)" "nothing waits"
[[ -d $plugin && ! -L $plugin ]] || ds_fail "capture leaves the plugin where it is"
# The tree passes the checks of the instance.
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a static --only skills
assert_exit 0 ds a pins check
# Seen again, it is known: no item, no commit.
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a example-plugin .)"
ds_code a skills capture --now --json
assert_json - '.captured == []' <<<"$DS_STDOUT"
assert_eq "$tip" "$(remote_tip)"
# agents install on the machine that made it leaves it as it is.
assert_exit 0 ds a agents install --profile workstation --skip-validation
[[ -d $plugin && ! -L $plugin ]] || ds_fail "agents install keeps the own plugin a real directory"
assert_eq "$(jq -r .directory_sha256 <<<"$entry")" "$(local_digest "$plugin")"

# --- an edit of a file of the plugin is captured again ------------------------------------

printf '\nMore.\n' >>"$plugin/skills/example-plugin-helper/SKILL.md"
tool_wrote a "$plugin/skills/example-plugin-helper/SKILL.md" post-tool-use-edit
assert_eq capture "$(plugin_item a example-plugin .state)"
settle_plugin a example-plugin
ds_code a skills capture --now
assert_eq "$(local_digest "$plugin")" "$(remote_plugin example-plugin | jq -r .directory_sha256)"
assert_contains "$(remote_file agent/plugins/example-plugin/skills/example-plugin-helper/SKILL.md)" "More."

# --- another machine: a real directory in ~/.claude/skills, never overwritten -------------

new_machine b
b_plugin=$(home_of b)/.claude/skills/example-plugin
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ -d $b_plugin && ! -L $b_plugin ]] || ds_fail "the other machine gets a real directory"
assert_eq "$(remote_plugin example-plugin | jq -r .directory_sha256)" "$(local_digest "$b_plugin")"
assert_eq "$(local_digest "$b_plugin")" "$(plugin_base b example-plugin)"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b example-plugin .)"
# A local change there stays, and waits for its capture.
printf '\nOnly on b.\n' >>"$b_plugin/skills/example-plugin-helper/SKILL.md"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$(cat "$b_plugin/skills/example-plugin-helper/SKILL.md")" "Only on b."
assert_exit 0 ds b agents check --profile workstation
assert_exit 0 ds b skills reconcile --full
assert_eq capture "$(plugin_item b example-plugin .state)"
# Removed there by hand: deleted, not installed again.
rm -rf "$b_plugin"
assert_exit 0 ds b skills reconcile
age_field b plugin:example-plugin detected_at 0
missing=$(state_of b)/skills/pending.json
jq '.missing["plugin:example-plugin"] -= 120' "$missing" >"$missing.tmp"
mv -- "$missing.tmp" "$missing"
assert_exit 0 ds b skills reconcile
assert_eq deleted "$(plugin_item b example-plugin .state)"
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ ! -e $b_plugin ]] || ds_fail "a plugin deleted here is not installed again"
assert_exit 0 ds b skills restore example-plugin
[[ -f $b_plugin/.claude-plugin/plugin.json ]] || ds_fail "restore brings it back"
assert_eq "{}" "$(plugin_item b example-plugin .)"

# --- --here: only on this machine ---------------------------------------------------------

new_plugin a here-plugin
tool_wrote a "$(home_of a)/.claude/skills/here-plugin/.claude-plugin/plugin.json"
settle_plugin a here-plugin
ds_code a skills track here-plugin --here
assert_json - '.machines == ["a"] and .agents == ["claude"]' <<<"$(remote_plugin here-plugin)"
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b skills effective --json
assert_json - '.skip.plugins | index("here-plugin") != null' <<<"$DS_STDOUT"
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ ! -e $(home_of b)/.claude/skills/here-plugin ]] || ds_fail "the other machine does not get it"
assert_exit 0 ds b skills reconcile --full
assert_eq "{}" "$(plugin_item b here-plugin .)"

# --- a clone of somebody else's plugin: asked, and --all needs --own ------------------------

mkdir -p "$world/plugin-upstream"
git init -q -b main "$world/plugin-upstream"
mkdir -p "$world/plugin-upstream/.claude-plugin"
printf '{"name": "cloned-plugin", "version": "1.0.0"}\n' >"$world/plugin-upstream/.claude-plugin/plugin.json"
git -C "$world/plugin-upstream" add -A
git -C "$world/plugin-upstream" commit -q -m "chore: a plugin"
git clone -q "$world/plugin-upstream" "$(home_of a)/.claude/skills/cloned-plugin"
settle_plugin a cloned-plugin
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a cloned-plugin .state)"
assert_eq downloaded "$(plugin_item a cloned-plugin .origin)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" cloned-plugin
tip=$(remote_tip)
# An update of it, even by a file tool, keeps the question and tracks nothing.
printf '{"name": "cloned-plugin", "version": "1.1.0"}\n' >"$(home_of a)/.claude/skills/cloned-plugin/.claude-plugin/plugin.json"
tool_wrote a "$(home_of a)/.claude/skills/cloned-plugin/.claude-plugin/plugin.json" post-tool-use-edit
assert_eq ask "$(plugin_item a cloned-plugin .state)"
settle_plugin a cloned-plugin
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"
EXPECT_STATUS=1 ds_code a skills track cloned-plugin --all
assert_contains "$DS_STDERR" "--own"
assert_eq "$tip" "$(remote_tip)"
ds_code a skills track cloned-plugin --never
assert_contains "$(remote_file hosts/a.toml)" cloned-plugin
assert_eq declined "$(plugin_item a cloned-plugin .state)"
assert_eq '{}' "$(remote_plugin cloned-plugin)"
assert_exit 0 ds a skills reconcile --full
assert_eq declined "$(plugin_item a cloned-plugin .state)"

# Reconciling and the hooks started neither agent.
assert_eq "" "$(cat "$DS_TEST_ROOT/agent-calls")"
