# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and rb_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `rebuild --switch` on a machine whose user changed a skill: an own skill keeps the
# change, a third-party skill is backed up and refreshed, and a checkout behind what
# capture published does not take the copy back. The owner's skills survive a rebuild.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

lock=$rb_inst/agent/skills.lock.json

# vendor NAME REVISION: a skill in the repository and in the lock, and its local copy.
vendor() {
  local dir=$rb_inst/agent/skills/$1
  mkdir -p "$dir"
  printf -- '---\nname: %s\n---\n\n# %s\n' "$1" "$1" >"$dir/SKILL.md"
  printf 'MIT\n' >"$dir/LICENSE"
  relock "$1" "$2"
  mkdir -p "$HOME/.agents/skills"
  cp -a "$dir" "$HOME/.agents/skills/$1"
}

digest() {
  bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$1"
}

# relock NAME REVISION: the entry of NAME follows its vendored files.
relock() {
  local dir=$rb_inst/agent/skills/$1 tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --arg name "$1" --arg revision "$2" --arg skill "$(sha256sum -- "$dir/SKILL.md" | awk '{print $1}')" \
    --arg directory "$(digest "$dir")" '
    .skills = ([.skills[] | select(.name != $name)] + [{name: $name, directory: $name, revision: $revision,
      skill_sha256: $skill, directory_sha256: $directory}])' "$lock" >"$tmp"
  mv -- "$tmp" "$lock"
}

vendor mine same-as-instance-checkout
vendor theirs 0123456789012345678901234567890123456789
instance_commit "chore: two skills"

# The first rebuild records what is in sync.
assert_exit 0 run_rebuild --profile workstation --switch
assert_json "$DOTSTEWARD_STATE_ROOT/skills/base.json" '.["skill:mine"].base_sha256 != null'
assert_json "$DOTSTEWARD_STATE_ROOT/skills/base.json" 'has("skill:theirs") | not'

# Both copies change; the rebuild takes back only the third-party one.
printf 'my change\n' >>"$HOME/.agents/skills/mine/SKILL.md"
printf 'a local edit\n' >>"$HOME/.agents/skills/theirs/SKILL.md"
assert_exit 0 run_rebuild --profile workstation --switch
assert_contains "$DS_STDOUT" "skill mine: pending-capture"
assert_contains "$DS_STDOUT" "backed up and refreshed: theirs"
assert_contains "$(cat "$HOME/.agents/skills/mine/SKILL.md")" "my change"
assert_not_contains "$(cat "$HOME/.agents/skills/theirs/SKILL.md")" "a local edit"

# A capture landed on the remote and this checkout has not caught up with it.
git -C "$rb_inst" checkout -q -b captured
printf 'my change\n' >>"$rb_inst/agent/skills/mine/SKILL.md"
relock mine same-as-instance-checkout
instance_commit "chore(skills): capture mine"
captured=$(git -C "$rb_inst" rev-parse HEAD)
captured_digest=$(jq -r '.skills[] | select(.name == "mine") | .directory_sha256' "$lock")
git -C "$rb_inst" checkout -q -
base=$DOTSTEWARD_STATE_ROOT/skills/base.json
jq --arg commit "$captured" --arg digest "$captured_digest" \
  '.["skill:mine"].base_commit = $commit | .["skill:mine"].base_sha256 = $digest' "$base" >"$base.tmp"
mv -- "$base.tmp" "$base"
assert_exit 0 run_rebuild --profile workstation --switch
assert_contains "$DS_STDOUT" "skill mine: behind"
assert_contains "$(cat "$HOME/.agents/skills/mine/SKILL.md")" "my change"
