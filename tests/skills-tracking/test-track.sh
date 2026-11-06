# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The answers to the question. --all puts a downloaded skill into the lock with its
# upstream pinned: the commit of a clone, or the commit whose tree a record of `npx skills`
# names; without such a commit it says so and offers --own. --here keeps it to this
# machine. --never is remembered in the host file of this machine, and never asked again.
# `forget` takes a skill from all machines, `restore` brings a deleted one back.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
agents_skills=$(home_of a)/.agents/skills

# upstream_repo DIR: a repository with skills/fetched and a license; three commits.
upstream=$world/upstream.git
upstream_work=$world/upstream
git init -q -b main "$upstream_work"
mkdir -p "$upstream_work/skills/fetched" "$upstream_work/skills/unrelated"
printf -- '---\nname: fetched\n---\n\nversion one\n' >"$upstream_work/skills/fetched/SKILL.md"
printf 'MIT\n' >"$upstream_work/skills/fetched/LICENSE"
git -C "$upstream_work" add -A
git -C "$upstream_work" commit -q -m "chore: version one"
one=$(git -C "$upstream_work" rev-parse HEAD)
tree_one=$(git -C "$upstream_work" rev-parse "HEAD:skills/fetched")
printf -- '---\nname: fetched\n---\n\nversion two\n' >"$upstream_work/skills/fetched/SKILL.md"
git -C "$upstream_work" add -A
git -C "$upstream_work" commit -q -m "chore: version two"
two=$(git -C "$upstream_work" rev-parse HEAD)
tree_two=$(git -C "$upstream_work" rev-parse "HEAD:skills/fetched")
printf 'other\n' >"$upstream_work/skills/unrelated/note"
git -C "$upstream_work" add -A
git -C "$upstream_work" commit -q -m "chore: something else"
three=$(git -C "$upstream_work" rev-parse HEAD)
git clone -q --bare "$upstream_work" "$upstream"
git -C "$upstream" config uploadpack.allowFilter true

record() {
  jq -n --arg url "file://$upstream" --arg tree "$1" '{version: 3, skills: {fetched: {
    source: "example-org/skills", sourceType: "github", sourceUrl: $url,
    skillPath: "skills/fetched/SKILL.md", skillFolderHash: $tree}}}' >"$(home_of a)/.agents/.skill-lock.json"
}

place_fetched() {
  mkdir -p "$agents_skills/fetched"
  git -C "$upstream_work" show "$1:skills/fetched/SKILL.md" >"$agents_skills/fetched/SKILL.md"
  printf 'MIT\n' >"$agents_skills/fetched/LICENSE"
  find "$agents_skills/fetched" -exec touch -h -d '2001-01-01' {} +
}

# --- a record of `npx skills`: the commit whose tree it names ------------------------------

record "$tree_two"
place_fetched "$two"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a fetched .state)"
ds_code a skills track fetched --all
entry=$(remote_entry fetched)
assert_eq "file://$upstream" "$(jq -r .source <<<"$entry")"
assert_eq "$three" "$(jq -r .revision <<<"$entry")" "HEAD has the same tree of the skill: HEAD is pinned"
assert_eq skills/fetched "$(jq -r .source_path <<<"$entry")"
assert_eq "{}" "$(item a fetched .)"
assert_eq "version two" "$(remote_file agent/skills/fetched/SKILL.md | tail -n 1)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a pins check
# Asked no more, and a change of it is no capture.
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a fetched .)"

# An older tree: the log of the path leads to the commit.
new_machine b
record_b() {
  jq -n --arg url "file://$upstream" --arg tree "$tree_one" '{version: 3, skills: {older: {
    sourceUrl: $url, skillPath: "skills/fetched/SKILL.md", skillFolderHash: $tree}}}' >"$(home_of b)/.agents/.skill-lock.json"
}
record_b
mkdir -p "$(home_of b)/.agents/skills/older"
printf -- '---\nname: older\n---\n\nversion one\n' >"$(home_of b)/.agents/skills/older/SKILL.md"
printf 'MIT\n' >"$(home_of b)/.agents/skills/older/LICENSE"
find "$(home_of b)/.agents/skills/older" -exec touch -h -d '2001-01-01' {} +
assert_exit 0 ds b skills reconcile
ds_code b skills track older --all
assert_eq "$one" "$(remote_entry older | jq -r .revision)"

# No commit has this tree: it says so, offers --own, and nothing happens.
jq -n --arg url "file://$upstream" '{version: 3, skills: {lost: {
  sourceUrl: $url, skillPath: "skills/fetched/SKILL.md", skillFolderHash: "0123456789012345678901234567890123456789"}}}' \
  >"$(home_of b)/.agents/.skill-lock.json"
mkdir -p "$(home_of b)/.agents/skills/lost"
printf -- '---\nname: lost\n---\n' >"$(home_of b)/.agents/skills/lost/SKILL.md"
assert_exit 0 ds b skills reconcile
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code b skills track lost --all
assert_contains "$DS_STDERR" "--own"
assert_eq "$tip" "$(remote_tip)"
assert_eq ask "$(item b lost .state)"
find "$(home_of b)/.agents/skills/lost" -exec touch -h -d '2001-01-01' {} +
ds_code b skills track lost --all --own
assert_json - '.revision == "same-as-instance-checkout"' <<<"$(remote_entry lost)"
assert_eq "{}" "$(item b lost .)"

# --- a clone: its remote and HEAD; a third-party skill needs a license ----------------------

mkdir -p "$world/skill-upstream"
git init -q -b main "$world/skill-upstream"
printf -- '---\nname: cloned\n---\n' >"$world/skill-upstream/SKILL.md"
git -C "$world/skill-upstream" add -A
git -C "$world/skill-upstream" commit -q -m "chore: a skill at the top"
git clone -q "$world/skill-upstream" "$agents_skills/cloned"
find "$agents_skills/cloned" -exec touch -h -d '2001-01-01' {} +
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a cloned .state)"
tip=$(remote_tip)
# Without a license the static check says no: blocked, not published.
EXPECT_STATUS=1 ds_code a skills track cloned --all
assert_eq "$tip" "$(remote_tip)"
assert_eq blocked "$(item a cloned .state)"
assert_contains "$(cat "$(state_of a)/skills/last-capture.json")" "no license file"
printf 'MIT\n' >"$agents_skills/cloned/LICENSE"
git -C "$agents_skills/cloned" add -A
git -C "$agents_skills/cloned" commit -q -m "chore: a license"
find "$agents_skills/cloned" -exec touch -h -d '2001-01-01' {} +
ds_code a skills track cloned --all
entry=$(remote_entry cloned)
assert_eq "$world/skill-upstream" "$(jq -r .source <<<"$entry")"
assert_eq "$(git -C "$agents_skills/cloned" rev-parse HEAD)" "$(jq -r .revision <<<"$entry")"
# .git itself stays out of the repository.
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/cloned/.git/HEAD 2>/dev/null; then
  ds_fail ".git stays out"
fi

# --- unknown origin: --all says --own, and --here keeps it to this machine -------------------

mkdir -p "$agents_skills/unzipped"
printf -- '---\nname: unzipped\n---\n' >"$agents_skills/unzipped/SKILL.md"
find "$agents_skills/unzipped" -exec touch -h -d '2001-01-01' {} +
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a unzipped .origin)"
EXPECT_STATUS=1 ds_code a skills track unzipped --all
assert_contains "$DS_STDERR" "--own"
tip=$(remote_tip)
ds_code a skills track unzipped --here --own
assert_json - '.machines == ["a"] and .revision == "same-as-instance-checkout"' <<<"$(remote_entry unzipped)"
# The host file arrives in the same commit, so the name is known.
assert_contains "$(git -C "$remote" diff-tree --no-commit-id --name-only -r refs/heads/main)" hosts/a.toml
assert_eq "$tip" "$(git -C "$remote" rev-parse 'refs/heads/main^')"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a static --only skills
# The other machine never hears of it.
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b skills effective --json
assert_json - '.skip.skills | index("unzipped") != null' <<<"$DS_STDOUT"
assert_exit 0 ds b agents install --profile workstation --skip-validation
[[ ! -e $(home_of b)/.agents/skills/unzipped ]] || ds_fail "the other machine does not get it"

# --- --never: in the host file, never asked again, here only ----------------------------------

mkdir -p "$agents_skills/unwanted"
printf -- '---\nname: unwanted\n---\n' >"$agents_skills/unwanted/SKILL.md"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a unwanted .state)"
ds_code a skills track unwanted --never
assert_contains "$(remote_file hosts/a.toml)" unwanted
assert_eq declined "$(item a unwanted .state)"
assert_eq none "$(base a unwanted)"
assert_eq null "$(remote_entry unwanted | jq -r '.name // null')"
assert_exit 0 ds a skills reconcile --full
assert_eq declined "$(item a unwanted .state)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills effective --json
# A reinstall under the same name: the host file remembers, nothing asks.
rm -f "$(state_of a)/skills/pending.json"
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a unwanted .)"

# --- a local edit of a pinned skill: only a report, and --own keeps it ---------------------------

git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
printf 'local\n' >>"$agents_skills/fetched/SKILL.md"
file=$agents_skills/fetched/SKILL.md
on a bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|fe058fc9|g" -e "s|@FILE@|$2|g" "$1" |
  "$3" skills hook PostToolUse --agent claude' _ "$fixtures/claude/post-tool-use-edit.json" "$file" "$DS_REPO_ROOT/cli/dotsteward"
assert_eq local-edit "$(item a fetched .state)"
find "$agents_skills/fetched" -exec touch -h -d '2001-01-01' {} +
ds_code a skills track fetched --own
entry=$(remote_entry fetched)
assert_eq same-as-instance-checkout "$(jq -r .revision <<<"$entry")"
assert_contains "$(remote_file agent/skills/fetched/SKILL.md)" local
assert_eq "{}" "$(item a fetched .)"

# --- forget: from all machines; restore: back from the repository ------------------------------

own_new a to-forget
settle a to-forget
ds_code a skills capture --now
own_new a to-restore
settle a to-restore
ds_code a skills capture --now
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
rm -rf "$agents_skills/to-forget" "$agents_skills/to-restore"
ds_code a skills forget to-forget
assert_eq null "$(remote_entry to-forget | jq -r '.name // null')"
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/to-forget/SKILL.md 2>/dev/null; then
  ds_fail "forget takes it out of the repository"
fi
assert_eq none "$(base a to-forget)"
assert_eq "{}" "$(item a to-forget .)"
ds_code a skills restore to-restore
[[ -f $agents_skills/to-restore/SKILL.md ]] || ds_fail "restore brings it back"
assert_eq "$(remote_entry to-restore | jq -r .directory_sha256)" "$(base a to-restore)"
assert_eq "{}" "$(item a to-restore .)"
assert_exit 1 ds a skills restore no-such-skill
assert_exit 1 ds a skills forget no-such-skill
assert_exit 1 ds a skills track no-such-skill --all
assert_exit 2 ds a skills track to-restore
assert_exit 2 ds a skills track to-restore --all --never

# --- tracking off: nothing moves ----------------------------------------------------------------

new_machine c
sed -i '/^tracking = true$/d' "$(clone_of c)/workstation.toml"
new_skill c quiet
assert_exit 1 ds c skills track quiet --all --own
assert_contains "$DS_STDERR" "tracking is off"
tip=$(remote_tip)
ds_code c skills capture --now
assert_eq "$tip" "$(remote_tip)"
