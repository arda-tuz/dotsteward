# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# skills restore never deletes what it does not own (review-c2 C2-B1): when the place of an
# own plugin (or of a skill) holds something else, a skill of this machine or notes, restore
# refuses and names the place, and every file stays. skills status names such a place as
# taken, not as missing, so nothing points at restore; it puts the kind before the name.
# restore of a plugin says where it went, with no word of links.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
new_plugin a tool
tool_wrote a "$(plugin_dir a tool)/.claude-plugin/plugin.json"
settle_plugin a tool
ds_code a skills capture --now

# --- b: a skill of b holds the place, and the state of b is fresh --------------------------

new_machine b
place=$(plugin_dir b tool)
mkdir -p "$place"
printf -- '---\nname: tool\ndescription: A skill of b.\n---\nb content\n' >"$place/SKILL.md"
assert_exit 1 ds b skills restore tool
assert_contains "$DS_STDERR" "$place"
assert_eq "b content" "$(tail -n 1 "$place/SKILL.md")"
[[ ! -e $place/.claude-plugin ]] || ds_fail "restore leaves the place alone"
# status calls it taken.
assert_exit 0 ds b skills reconcile --full
assert_exit 0 ds b skills status
assert_contains "$DS_STDOUT" "plugin:tool: name-taken: occupied"
assert_not_contains "$DS_STDOUT" "tool: missing"

# --- c: notes in the place, neither plugin nor skill ---------------------------------------

new_machine c
place=$(plugin_dir c tool)
mkdir -p "$place"
printf 'my notes\n' >"$place/notes.txt"
assert_exit 1 ds c skills restore tool
assert_contains "$DS_STDERR" "$place"
assert_eq "my notes" "$(cat "$place/notes.txt")"
# The same for a skill: the place of a skill holds a file of the user.
mkdir -p "$(home_of c)/.agents/skills/example-skill"
printf 'not a skill\n' >"$(home_of c)/.agents/skills/example-skill/notes.txt"
assert_exit 1 ds c skills restore example-skill
assert_eq "not a skill" "$(cat "$(home_of c)/.agents/skills/example-skill/notes.txt")"
# An empty place is restored, and the message says where.
rm -rf -- "$place"
ds_code c skills restore tool
[[ -f $place/.claude-plugin/plugin.json ]] || ds_fail "restore brings the plugin"
assert_contains "$DS_STDERR" "$place"
assert_not_contains "$DS_STDERR" "links it"
