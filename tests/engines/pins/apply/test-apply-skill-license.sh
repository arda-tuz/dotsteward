# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# A vendored skill whose upstream keeps its license above the skill directory has that
# license beside it, in agent/skill-licenses/<directory> (skills capture writes it). When
# the pin moves, the license moves with it: the nearest one above the directory at the new
# revision replaces the old copy, staged with the skill.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
licenses=$inst/agent/skill-licenses/example-vendored
mkdir -p "$licenses"
printf 'Synthetic license, the first version\n' >"$licenses/LICENSE"
git -C "$inst" add agent/skill-licenses
git -C "$inst" commit -q -m "chore: the license beside the skill"

dir=$sources/example/skills
printf 'Synthetic license, the second version\n' >"$dir/LICENSE"
git -C "$dir" add LICENSE
git -C "$dir" commit -q -m "chore: a new license"
skill_licensed=$(git -C "$dir" rev-parse HEAD)
_apply_publish example/skills

rows "$(row skills.example-vendored skill-source "${skill_old:0:12}" "${skill_licensed:0:12}" review \
  '{"head":"'"$skill_licensed"'","release":null,"ahead_by":2,"changed_paths":["skills/example-vendored/references/notes.md"]}')"
assert_exit 0 apply --latest "$rows"
assert_eq "\"$skill_licensed\"" "$(json_get "$skills" '.skills[] | select(.name == "example-vendored") | .revision')"
assert_eq "Synthetic license, the second version" "$(<"$licenses/LICENSE")"
assert_contains "$(git -C "$inst" diff --cached --name-only)" "agent/skill-licenses/example-vendored/LICENSE"
assert_exit 0 pins check
