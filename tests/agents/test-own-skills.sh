# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A skill of the user's own (its lock revision is a repo-owned sentinel) is
# never overwritten by `agents install`, whatever `rebuild` is asked to do, and
# never turns `agents check` red. Three digests decide: l (the normal form of
# the local copy), r (the lock of the checkout) and b (what this machine last
# had in sync, <state>/skills/base.json):
#
#   l != r, base_commit no ancestor of HEAD   untouched, note behind
#   l == r                                    b = r
#   l != r, r == b                            untouched, note pending-capture
#   l != r, l == b                            backup and refresh, note incoming
#   all different, or no b and l != r         untouched, note conflict
#   no l, but b                               not installed, note deleted
#   no l and no b                             installed (check: skill-missing)
#
# Third-party skills keep skill-drift and their refresh. `agents check` writes
# nothing, the first install records b for what is in sync. The tests also hold
# the normal form to directory_sha256 of lib.sh byte for byte, and `skills
# status` to the same answers.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

state=$DS_TEST_ROOT/state
export DOTSTEWARD_STATE_ROOT=$state
base=$state/skills/base.json
own=same-as-instance-checkout

lib_digest() {
  bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$1"
}

# refresh_lock NAME: the vendored copy of NAME changed; the lock follows.
refresh_lock() {
  local source
  source=$(vendored "$1")
  lock_edit '(.skills[] | select(.name == $name)) |= (.skill_sha256 = $skill | .directory_sha256 = $dir)' \
    --arg name "$1" --arg skill "$(sha256sum -- "$source/SKILL.md" | awk '{print $1}')" --arg dir "$(lib_digest "$source")"
}

lock_digest() {
  jq -r --arg name "$1" 'first(.skills[] | select(.name == $name)) | .directory_sha256' "$agents_lock"
}

base_digest() {
  jq -r --arg key "skill:$1" '.[$key].base_sha256 // "none"' "$base"
}

# skill_state NAME: the state of NAME in `skills status --json`.
skill_state() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status --json </dev/null |
    jq -r --arg name "$1" 'first(.own[] | select(.name == $name)) | .state'
}

# assert_check_passes NOTE: `agents check` passes, reports no finding and
# prints the note; it changes nothing in the home or in the state.
assert_check_passes() {
  local before state_before
  before=$(home_state)
  state_before=$(find "$state" -type f -printf '%p %T@\n' 2>/dev/null | LC_ALL=C sort)
  assert_exit 0 run_agents check --json
  assert_json - '.result == "passed" and .findings == []' <<<"$DS_STDOUT"
  assert_contains "$DS_STDERR" "$1"
  assert_eq "$before" "$(home_state)" "check leaves the home unchanged"
  assert_eq "$state_before" "$(find "$state" -type f -printf '%p %T@\n' 2>/dev/null | LC_ALL=C sort)" "check writes no state"
}

# new_case: an empty lock, an empty home and no state, so a case runs only the
# skills it is about.
new_case() {
  rm -rf "$HOME/.agents" "$HOME/.claude/skills" "$HOME/.codex/skills" "$agents_inst/agent/skills" \
    "$state/skills" "$state/backups"
  mkdir -p "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills" "$agents_inst/agent/skills"
  lock_edit '.skills = []'
}

# fresh NAME: a new own skill, installed with both links, in sync.
fresh() {
  lock_add "$1" --revision "$own"
  cp -a "$(vendored "$1")" "$HOME/.agents/skills/$1"
  assert_exit 0 run_agents install
}

# --- l == r: the first install records b, check writes nothing -------------------

new_case
lock_add first --revision "$own"
cp -a "$(vendored first)" "$HOME/.agents/skills/first"
assert_exit 0 run_agents check --json
assert_json - '.result == "passed"' <<<"$DS_STDOUT"
[[ ! -e $base ]] || ds_fail "check must not write base.json"
assert_exit 0 run_agents install
assert_file_mode "$state/skills" 0700
assert_file_mode "$base" 0600
assert_eq "$(lock_digest first)" "$(base_digest first)"
assert_eq "$HOME/.agents/skills/first" "$(jq -r '.["skill:first"].local_path' "$base")"
assert_eq in-sync "$(skill_state first)"

# --- l != r, r == b: a local edit is never overwritten -----------------------------

new_case
fresh edited
printf 'local change\n' >>"$HOME/.agents/skills/edited/SKILL.md"
assert_check_passes pending-capture
before=$(home_state)
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" pending-capture
assert_eq "$before" "$(home_state)" "install leaves a local edit alone"
[[ ! -d $state/backups ]] || ds_fail "nothing to back up for a local edit"
assert_eq pending-capture "$(skill_state edited)"
printf 'second change\n' >>"$HOME/.agents/skills/edited/SKILL.md"
assert_exit 0 run_agents install
assert_contains "$(cat "$HOME/.agents/skills/edited/SKILL.md")" "second change"

# --- l != r, l == b: the repository moved, the local copy did not -------------------

new_case
fresh incoming
printf 'from another machine\n' >>"$(vendored incoming)/SKILL.md"
refresh_lock incoming
assert_check_passes incoming
assert_eq incoming "$(skill_state incoming)"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "backed up and refreshed: incoming"
assert_contains "$(cat "$HOME/.agents/skills/incoming/SKILL.md")" "from another machine"
assert_eq "$(lock_digest incoming)" "$(base_digest incoming)"
[[ -n $(find "$state/backups" -mindepth 1 -maxdepth 1 -name '*-skills') ]] || ds_fail "the old copy is backed up"
assert_eq in-sync "$(skill_state incoming)"

# --- all three differ: conflict, nothing moves ------------------------------------

new_case
fresh both
printf 'repository side\n' >>"$(vendored both)/SKILL.md"
refresh_lock both
printf 'local side\n' >>"$HOME/.agents/skills/both/SKILL.md"
assert_check_passes conflict
before=$(home_state)
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" conflict
assert_eq "$before" "$(home_state)" "install leaves a conflict alone"
assert_json "$state/skills/pending.json" '.items["skill:both"].state == "conflict"'
assert_eq conflict "$(skill_state both)"

# --- no b, l != r: the first pass over a skill the user changed earlier -------------

new_case
fresh earlier
jq 'del(.["skill:earlier"])' "$base" >"$base.tmp" && mv -- "$base.tmp" "$base"
chmod 0600 "$base"
printf 'changed before tracking\n' >>"$HOME/.agents/skills/earlier/SKILL.md"
assert_check_passes conflict
before=$(home_state)
assert_exit 0 run_agents install
assert_eq "$before" "$(home_state)" "install leaves a first-pass difference alone"
assert_contains "$(cat "$HOME/.agents/skills/earlier/SKILL.md")" "changed before tracking"

# --- no l, b: deleted here, not installed again; a dangling link is no finding ------

new_case
fresh removed
rm -rf "$HOME/.agents/skills/removed"
[[ -L $HOME/.claude/skills/removed ]] || ds_fail "the link root holds the link of the skill"
assert_check_passes deleted
# What reads the effective scope misses it no more than `agents check` does.
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills effective --json
assert_json - '.skip.skills == ["removed"] and .reasons["skill:removed"] == "deleted"' <<<"$DS_STDOUT"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" deleted
[[ ! -e $HOME/.agents/skills/removed ]] || ds_fail "a deleted skill is not installed again"
[[ ! -L $HOME/.claude/skills/removed ]] || ds_fail "the sweep removes the dangling link"
assert_json "$state/skills/pending.json" '.items["skill:removed"].state == "deleted"'
assert_eq deleted "$(skill_state removed)"
# Back again, by hand: it is just another skill in sync.
cp -a "$(vendored removed)" "$HOME/.agents/skills/removed"
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills effective --json
assert_json - '.skip.skills == [] and .reasons == {}' <<<"$DS_STDOUT"
assert_exit 0 run_agents install
assert_eq in-sync "$(skill_state removed)"
assert_json "$state/skills/pending.json" '.items | has("skill:removed") | not'

# --- no l, no b: an accepted skill of the lock is installed ------------------------

new_case
lock_add missing --revision "$own"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill missing: missing"
assert_exit 0 run_agents install
assert_eq "$(cat "$(vendored missing)/SKILL.md")" "$(cat "$HOME/.agents/skills/missing/SKILL.md")"
assert_eq "$(lock_digest missing)" "$(base_digest missing)"

# --- a checkout behind what capture pushed: the old lock does not win --------------

new_case
git init -q "$agents_inst"
fresh behind
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore: the instance"
behind_old=$(lock_digest behind)
git -C "$agents_inst" checkout -q -b captured
printf 'captured on this machine\n' >>"$(vendored behind)/SKILL.md"
refresh_lock behind
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore(skills): capture behind"
captured=$(git -C "$agents_inst" rev-parse HEAD)
captured_digest=$(lock_digest behind)
git -C "$agents_inst" checkout -q main
assert_eq "$behind_old" "$(lock_digest behind)"
printf 'captured on this machine\n' >>"$HOME/.agents/skills/behind/SKILL.md"
jq --arg digest "$captured_digest" --arg commit "$captured" \
  '.["skill:behind"].base_sha256 = $digest | .["skill:behind"].base_commit = $commit' "$base" >"$base.tmp"
mv -- "$base.tmp" "$base"
chmod 0600 "$base"
assert_check_passes behind
before=$(home_state)
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" behind
assert_eq "$before" "$(home_state)" "an old lock does not take the local copy back"
assert_contains "$(cat "$HOME/.agents/skills/behind/SKILL.md")" "captured on this machine"
assert_eq "$captured_digest" "$(base_digest behind)"
assert_eq behind "$(skill_state behind)"
# A commit the checkout does not know at all counts as behind too.
jq '.["skill:behind"].base_commit = "0123456789012345678901234567890123456789"' "$base" >"$base.tmp"
mv -- "$base.tmp" "$base"
chmod 0600 "$base"
assert_check_passes behind
jq --arg commit "$captured" '.["skill:behind"].base_commit = $commit' "$base" >"$base.tmp"
mv -- "$base.tmp" "$base"
chmod 0600 "$base"
# The checkout catches up: in sync without a backup or a copy.
git -C "$agents_inst" merge -q --ff-only captured
assert_eq "$captured_digest" "$(lock_digest behind)"
assert_exit 0 run_agents install
[[ ! -d $state/backups ]] || ds_fail "catching up neither copies nor backs up"
assert_eq in-sync "$(skill_state behind)"


# A copy taken back to the old lock while the checkout is behind: that is no sync with the
# repository, so b stays and the pull that follows finds a change, not an incoming copy.
new_case
rm -rf "$agents_inst/.git"
git init -q "$agents_inst"
fresh reverted
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore: the instance"
git -C "$agents_inst" checkout -q -b captured
printf 'captured on this machine\n' >>"$(vendored reverted)/SKILL.md"
refresh_lock reverted
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore(skills): capture reverted"
captured=$(git -C "$agents_inst" rev-parse HEAD)
captured_digest=$(lock_digest reverted)
git -C "$agents_inst" checkout -q main
jq --arg digest "$captured_digest" --arg commit "$captured" \
  '.["skill:reverted"].base_sha256 = $digest | .["skill:reverted"].base_commit = $commit' "$base" >"$base.tmp"
mv -- "$base.tmp" "$base"
chmod 0600 "$base"
assert_exit 0 run_agents install
assert_eq "$captured_digest" "$(base_digest reverted)" "b does not go back"
git -C "$agents_inst" merge -q --ff-only captured
assert_eq pending-capture "$(skill_state reverted)"
rm -rf "$agents_inst/.git"

# --- a third-party skill keeps drift and refresh next to own skills -----------------

new_case
lock_add third --tree
cp -a "$(vendored third)" "$HOME/.agents/skills/third"
assert_exit 0 run_agents install
printf 'local change\n' >>"$HOME/.agents/skills/third/SKILL.md"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "installed skill differs from the lock: third"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "backed up and refreshed: third"
assert_not_contains "$(cat "$HOME/.agents/skills/third/SKILL.md")" "local change"

# --- a sentinel of [compat] repo_owned_revision is an own skill too ------------------

new_case
printf '\n[compat]\nrepo_owned_revision = "same-as-example-checkout"\n' >>"$agents_inst/workstation.toml"
lock_add compat --revision same-as-example-checkout
cp -a "$(vendored compat)" "$HOME/.agents/skills/compat"
assert_exit 0 run_agents install
printf 'local change\n' >>"$HOME/.agents/skills/compat/SKILL.md"
assert_check_passes pending-capture
assert_exit 0 run_agents install
assert_contains "$(cat "$HOME/.agents/skills/compat/SKILL.md")" "local change"

# --- a home-managed own skill stays bound to its generation ------------------------

new_case
lock_add managed --revision "$own" --deployment home-manager
store_managed=$agents_store/hm-managed
cp -a "$(vendored managed)" "$store_managed"
ln -s "$store_managed" "$HOME/.agents/skills/managed"
assert_exit 0 run_agents install
printf 'drift\n' >>"$store_managed/SKILL.md"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "home-managed skill digest differs from the lock: managed"
cp -a "$(vendored managed)/SKILL.md" "$store_managed/SKILL.md"

# --- the normal form: what the copy leaves out does not count ----------------------

new_case
lock_add normal --revision "$own" --directory normal
source=$(vendored normal)
printf 'with space\n' >"$source/a b.md"
printf 'backslash\n' >"$source/back\\slash.md"
printf 'newline\n' >"$source/new"$'\n'"line.md"
printf 'built/\n' >"$source/.gitignore"
printf 'linked content\n' >"$source/references/linked.md"
refresh_lock normal
local_copy=$HOME/.agents/skills/normal
cp -a "$source" "$local_copy"
mkdir -p "$local_copy/__pycache__" "$local_copy/.git/objects" "$local_copy/__pypackages__/x" "$local_copy/built" "$local_copy/state"
printf 'cache\n' >"$local_copy/__pycache__/mod.pyc"
printf 'bytecode\n' >"$local_copy/references/mod.pyc"
printf 'x\n' >"$local_copy/.git/objects/x"
printf 'x\n' >"$local_copy/__pypackages__/x/y"
printf '{}\n' >"$local_copy/metadata.json"
printf 'built\n' >"$local_copy/built/out"
printf 'instance ignored\n' >"$local_copy/state/kept-out"
printf 'state/\n*.log\n' >"$agents_inst/.gitignore"
# A link inside the tree counts as its target: the vendored copy holds the file.
rm -f "$local_copy/references/linked.md"
printf 'linked content\n' >"$local_copy/target.md"
printf 'linked content\n' >"$source/target.md"
refresh_lock normal
ln -s ../target.md "$local_copy/references/linked.md"
assert_exit 0 run_agents install
assert_eq in-sync "$(skill_state normal)"
assert_eq "$(lib_digest "$source")" "$(lock_digest normal)"
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status --json
assert_json - '.own[] | select(.name == "normal") | .local_sha256 == .lock_sha256' <<<"$DS_STDOUT"
assert_json - '.own[] | select(.name == "normal") | .dropped == ["built/out", "state/kept-out"]' <<<"$DS_STDOUT"
# A file the instance .gitignore holds back is named; a change to it is no change.
printf 'more\n' >>"$local_copy/state/kept-out"
assert_eq in-sync "$(skill_state normal)"

# --- a link out of the tree or a broken one is reported, the copy stays --------------

new_case
fresh linked
printf 'outside the tree\n' >"$DS_TEST_ROOT/outside-file"
ln -s "$DS_TEST_ROOT/outside-file" "$HOME/.agents/skills/linked/outside"
ln -s missing "$HOME/.agents/skills/linked/broken"
assert_check_passes pending-capture
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status --json
assert_json - '.own[] | select(.name == "linked") | .unsafe_links == ["broken", "outside"]' <<<"$DS_STDOUT"
assert_exit 0 run_agents install
[[ -L $HOME/.agents/skills/linked/outside ]] || ds_fail "the links stay"
rm -f "$HOME/.agents/skills/linked/outside" "$HOME/.agents/skills/linked/broken"

# --- placement: a real directory in a link root moves to the canonical root ---------

new_case
lock_add placed --revision "$own"
cp -a "$(vendored placed)" "$HOME/.claude/skills/placed"
printf 'written where the agent writes\n' >>"$HOME/.claude/skills/placed/SKILL.md"
assert_check_passes placement
# No b yet: the first pass over a copy that differs asks; it moves all the same.
assert_eq conflict "$(skill_state placed)"
assert_exit 0 run_agents install
[[ -d $HOME/.agents/skills/placed && ! -L $HOME/.agents/skills/placed ]] || ds_fail "the copy moves to the canonical root"
assert_symlink_to "$HOME/.claude/skills/placed" ../../.agents/skills/placed
assert_contains "$(cat "$HOME/.agents/skills/placed/SKILL.md")" "written where the agent writes"
assert_exit 0 run_agents check --json
assert_json - '.result == "passed"' <<<"$DS_STDOUT"

# A missing link of an own skill is a note for check and made by install.
rm -f "$HOME/.claude/skills/placed"
assert_check_passes placement
assert_exit 0 run_agents install
assert_symlink_to "$HOME/.claude/skills/placed" ../../.agents/skills/placed

# --- a scoped own skill takes the same decision ------------------------------------

new_case
manifest_edit '.skill_layout.agent_roots = { "alpha-agent": "~/.alpha/skills" }'
lock_add scoped --revision "$own"
lock_edit '(.skills[] | select(.name == "scoped")) += { agents: ["alpha-agent"] }'
assert_exit 0 run_agents install
store=$HOME/.local/share/dotsteward/scoped-skills
printf 'scoped local change\n' >>"$store/scoped/SKILL.md"
assert_check_passes pending-capture
before=$(home_state)
assert_exit 0 run_agents install
assert_eq "$before" "$(home_state)" "install leaves a scoped local edit alone"
assert_eq pending-capture "$(skill_state scoped)"

# --- skills status: human lines and the JSON document --------------------------------

new_case
fresh first
fresh edited
printf 'local change\n' >>"$HOME/.agents/skills/edited/SKILL.md"
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status
assert_contains "$DS_STDOUT" "edited: pending-capture"
assert_not_contains "$DS_STDOUT" "first:"
assert_contains "$DS_STDOUT" "in sync"
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status --json
assert_json - '.schema_version == 1 and (.own | type) == "array" and (.pending | type) == "object"' <<<"$DS_STDOUT"
assert_exit 2 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills status --nonsense
assert_exit 2 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills
