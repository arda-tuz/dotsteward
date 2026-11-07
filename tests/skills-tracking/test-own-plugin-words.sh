# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What agents install says about an own plugin calls it a plugin (review-c2 C2-m4): the note
# of its placement and the refusal to refresh a linked copy.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
p=$(plugin_dir a shared)
new_plugin a shared
tool_wrote a "$p/.claude-plugin/plugin.json"
settle_plugin a shared
ds_code a skills capture --now
new_machine b
bp=$(plugin_dir b shared)
assert_exit 0 ds b agents install --profile workstation --skip-validation
mkdir -p "$world/b-src"
mv -- "$bp" "$world/b-src/shared"
ln -s "$world/b-src/shared" "$bp"
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$DS_STDERR" "placement of an own plugin: own plugin shared"
assert_not_contains "$DS_STDERR" "own skill"
printf 'v2\n' >>"$p/skills/shared-helper/SKILL.md"
tool_wrote a "$p/skills/shared-helper/SKILL.md" post-tool-use-edit
settle_plugin a shared
ds_code a skills capture --now
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b agents install --profile workstation --skip-validation
assert_contains "$DS_STDERR" "plugin outside the managed roots not refreshed: shared"
assert_not_contains "$DS_STDERR" "skill outside"
