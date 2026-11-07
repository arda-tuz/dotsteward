# shellcheck shell=bash
# Vendored skills: a third-party skill whose upstream paths changed is replaced
# as a whole directory after a clean scan, with its revision and digests. A skill
# with a recorded transform, a local delta, a scan finding or a missing upstream
# directory is a review item and stays. Own skills are never touched.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
vendored=$inst/agent/skills/example-vendored
own=$inst/agent/skills/example-skill
own_state() {
  (cd "$own" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
  jq -c '.skills[] | select(.name == "example-skill")' "$skills"
}
own_before=$(own_state)

skill_row() {
  row skills.example-vendored skill-source "${skill_old:0:12}" "${1:0:12}" review '{"head":"'"$1"'","release":null,"ahead_by":1,"changed_paths":["skills/example-vendored/references/notes.md"]}'
}

rows "$(skill_row "$skill_new")"
assert_exit 0 apply --latest "$rows"
assert_eq "$(<"$sources/example/skills/skills/example-vendored/references/notes.md")" "$(<"$vendored/references/notes.md")"
[[ -f "$vendored/references/added.md" ]] || ds_fail "missing $vendored/references/added.md"
assert_eq "\"$skill_new\"" "$(json_get "$skills" '.skills[] | select(.name == "example-vendored") | .revision')"
assert_eq "\"$(lib_directory_sha256 "$vendored")\"" "$(json_get "$skills" '.skills[] | select(.name == "example-vendored") | .directory_sha256')"
# Nix would not see a new file otherwise.
assert_contains "$(git -C "$inst" ls-files -- agent/skills/example-vendored)" "references/added.md"
assert_eq "$own_before" "$(own_state)" "an own skill changed"
assert_exit 0 pins check

# Reset to the old revision for the cases that must not move.
reset_world() {
  git -C "$inst" reset -q --hard
  git -C "$inst" clean -qfd
  : >"$FAKE_NIX_STATE/calls"
}
reset_world

# A recorded transform is prose: only an agent can replay it. It is work that waits, no decision
# that holds a run: the item stands in the review and the exit status stays 0.
json_edit "$skills" 'data["skills"][1]["source_transform"] = "remove a key from the front matter"'
before=$(tree_state)
assert_exit 0 apply --latest "$rows"
assert_eq "skill-transform skills.example-vendored" "$(item_codes)"
assert_contains "$(jq -c '.items[0]' "$state/review.json")" "remove a key from the front matter"
assert_eq "$before" "$(tree_state)"
reset_world

# The vendored copy is not what upstream had at the pinned revision.
printf 'a local edit\n' >>"$vendored/SKILL.md"
json_edit "$skills" '
import hashlib
import pathlib
entry = data["skills"][1]
entry["skill_sha256"] = hashlib.sha256(pathlib.Path("'"$vendored"'/SKILL.md").read_bytes()).hexdigest()
'
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "skill-local-delta skills.example-vendored" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
reset_world

# The scan finds a private key in the new version. The text is built here: a
# committed one would fail the scan of this repository.
dir=$sources/example/skills
{
  printf -- '-----BEGIN %s-----\n' "RSA PRIVATE KEY"
  printf 'MIIEowIBAAKCAQEA%s\n' "$(printf 'x%.0s' {1..40})"
} >"$dir/skills/example-vendored/references/key.pem"
git -C "$dir" add -A
git -C "$dir" commit -q -m "feat: a third version"
skill_bad=$(git -C "$dir" rev-parse HEAD)
_apply_publish example/skills
rows "$(skill_row "$skill_bad")"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "skill-scan-finding skills.example-vendored" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
reset_world

# The directory is gone upstream.
git -C "$dir" rm -rq skills/example-vendored
git -C "$dir" commit -q -m "feat: move the skill away"
skill_gone=$(git -C "$dir" rev-parse HEAD)
_apply_publish example/skills
rows "$(skill_row "$skill_gone")"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "skill-source-missing skills.example-vendored" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# The upstream cannot be read: a failed group, nothing changes.
reset_world
rm -rf -- "$github/example/skills"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "skill:example-vendored"
assert_eq "$before" "$(tree_state)"
assert_eq "$own_before" "$(own_state)" "an own skill changed"
