# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `skills capture`: a skill a file tool wrote lands on the remote in one commit without
# a question. Everything happens in a worktree of its own: a dirty checkout is no
# obstacle, the checkout never moves, and a rebuild on the checkout that stayed behind
# does not take the local copy back. What the lock says beside the digests stays, a file
# deleted here leaves the repository, and with no git identity the author of the tip
# signs. A file an ignore rule holds back is named.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
checkout=$(clone_of a)
skill=$(home_of a)/.claude/skills/mine
start=$(remote_tip)

# --- a new skill: no question, one commit, the checkout stays as it is -------------

own_new a mine
assert_eq capture "$(item a mine .state)"
assert_eq own "$(item a mine .origin)"
printf 'dirty\n' >>"$checkout/home/AGENTS.md"
printf 'untracked\n' >"$checkout/untracked.txt"
head_before=$(git -C "$checkout" rev-parse HEAD)
status_before=$(git -C "$checkout" status --porcelain)
settle a mine
ds_code a skills capture --now --json
assert_json - '.status == "ok" and .captured == ["mine"]' <<<"$DS_STDOUT"
tip=$(remote_tip)
[[ $tip != "$start" ]] || ds_fail "the remote moved"
assert_eq "$start" "$(git -C "$remote" rev-parse "$tip^")" "one commit on the old tip"
assert_eq "chore(skills): capture mine" "$(git -C "$remote" log -1 --format=%s "$tip")"
assert_contains "$(git -C "$remote" log -1 --format=%B "$tip")" "Dotsteward-Machine: a"
assert_json - '.revision == "same-as-instance-checkout" and .name == "mine" and .directory == "mine"
  and (.skill_sha256 | length == 64) and (.directory_sha256 | length == 64) and (has("source") | not)' <<<"$(remote_entry mine)"
assert_eq "$(cat "$skill/SKILL.md")" "$(remote_file agent/skills/mine/SKILL.md)"
assert_eq "$(cat "$skill/references/guide.md")" "$(remote_file agent/skills/mine/references/guide.md)"
# The lock stays what it was around the new entry, generated_at included.
assert_eq "$(jq -c 'del(.skills)' "$seed/agent/skills.lock.json")" "$(remote_lock 'del(.skills)')"
assert_eq '["example-skill","mine"]' "$(remote_lock '[.skills[].name]')" "in name order"
# The checkout never moves and keeps its dirt.
assert_eq "$head_before" "$(git -C "$checkout" rev-parse HEAD)"
assert_eq "$status_before" "$(git -C "$checkout" status --porcelain)"
[[ ! -e $checkout/agent/skills/mine ]] || ds_fail "the checkout got the skill"
# What this machine knows now.
assert_eq "$(jq -r .directory_sha256 <<<"$(remote_entry mine)")" "$(base a mine)"
assert_eq "$tip" "$(jq -r '.["skill:mine"].base_commit' "$(state_of a)/skills/base.json")"
assert_eq "{}" "$(item a mine .)" "nothing waits"
[[ ! -e $(state_of a)/skills/worktree ]] || ds_fail "the worktree is gone"
assert_eq 1 "$(git -C "$checkout" worktree list --porcelain | grep -c '^worktree ')"
assert_json "$(state_of a)/skills/last-capture.json" '.status == "ok" and .captured == ["mine"]'
# Where a copy lives is the business of `agents install`.
[[ -d $skill && ! -L $skill ]] || ds_fail "capture does not move the skill"
# Nothing waits: no second commit, no fetch needed.
ds_code a skills capture --now --json
assert_json - '.status == "ok" and .captured == []' <<<"$DS_STDOUT"
assert_eq "$tip" "$(remote_tip)"

# --- what the lock says beside the digests stays; a deleted file goes --------------

new_machine other
ds other skills hooks install --agent claude >/dev/null
other_clone=$(clone_of other)
git -C "$other_clone" pull -q --ff-only
jq '(.skills[] | select(.name == "mine")) += {source: "https://example.invalid/mine", source_path: "skills/mine", machines: ["a"]}' \
  "$other_clone/agent/skills.lock.json" >"$DS_TEST_ROOT/lock.json"
cp "$DS_TEST_ROOT/lock.json" "$other_clone/agent/skills.lock.json"
mkdir -p "$other_clone/hosts"
printf 'schema_version = 1\n' >"$other_clone/hosts/a.toml"
git -C "$other_clone" add -A
git -C "$other_clone" commit -q -m "chore: scope the skill"
git -C "$other_clone" push -q origin main
rm "$skill/references/guide.md"
printf 'more\n' >>"$skill/SKILL.md"
wrote a mine
settle a mine
ds_code a skills capture --now
assert_json - '.machines == ["a"] and .source == "https://example.invalid/mine" and .source_path == "skills/mine"
  and .revision == "same-as-instance-checkout"' <<<"$(remote_entry mine)"
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/mine/references/guide.md 2>/dev/null; then
  ds_fail "a file deleted here leaves the repository"
fi
assert_contains "$(remote_file agent/skills/mine/SKILL.md)" more

# --- a rebuild on the checkout behind does not take the copy back -------------------

copy_before=$(cat "$skill/SKILL.md")
assert_exit 0 ds a agents install --profile workstation --skip-validation
assert_eq "$copy_before" "$(cat "$skill/SKILL.md")"
git -C "$checkout" checkout -q -- home/AGENTS.md
rm -f "$checkout/untracked.txt"
git -C "$checkout" pull -q --ff-only
# Up to date: the same copy, placed as `agents install` places every skill.
assert_exit 0 ds a agents install --profile workstation --skip-validation
placed=$(home_of a)/.agents/skills/mine
[[ -d $placed && ! -L $placed ]] || ds_fail "agents install places the copy in the canonical root"
assert_symlink_to "$skill" ../../.agents/skills/mine
assert_eq "$copy_before" "$(cat "$placed/SKILL.md")"
assert_exit 0 ds a skills status --json
assert_json - '.own[] | select(.name == "mine") | .state == "in-sync"' <<<"$DS_STDOUT"
assert_exit 0 ds a agents check --profile workstation

# --- no git identity: the author of the tip, and nothing written to a configuration --

assert_exit 0 git -C "$checkout" log -1 --format=%an
author=$DS_STDOUT
own_new a anonymous
settle a anonymous
printf '[init]\ndefaultBranch = main\n[user]\nuseConfigOnly = true\n' >"$DS_TEST_ROOT/no-identity"
GIT_CONFIG_GLOBAL=$DS_TEST_ROOT/no-identity ds_code a skills capture --now
assert_eq "$author" "$(git -C "$remote" log -1 --format=%an)"
assert_eq "" "$(git -C "$checkout" config --local user.name || true)"

# --- what an ignore rule holds back is named and stays out ----------------------------

new_skill a ignored
ignored=$(home_of a)/.claude/skills/ignored
mkdir -p "$ignored/logs"
printf 'noise\n' >"$ignored/logs/run.log"
printf 'kept\n' >"$ignored/kept.md"
wrote a ignored
settle a ignored
ds_code a skills capture --now
assert_json "$(state_of a)/skills/last-capture.json" '.dropped.ignored == ["logs/run.log"]'
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/ignored/logs/run.log 2>/dev/null; then
  ds_fail "an ignored file stays out"
fi
assert_eq kept "$(remote_file agent/skills/ignored/kept.md)"
assert_exit 0 ds a skills status
# A skill with its frontmatter name, not the name of its directory.
new_skill a folder-name
sed -i 's/^name: folder-name$/name: declared-name/' "$(home_of a)/.claude/skills/folder-name/SKILL.md"
wrote a folder-name
settle a folder-name
ds_code a skills capture --now
assert_json - '.directory == "folder-name"' <<<"$(remote_entry declared-name)"
assert_eq none "$(base a folder-name)"
assert_eq "$(jq -r .directory_sha256 <<<"$(remote_entry declared-name)")" "$(base a declared-name)"
# Nothing asks about its directory while the checkout is behind.
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a folder-name .)"

# A lock entry whose name is not its directory: a write through the link of the name
# changes the directory of the entry.
assert_exit 0 ds a agents install --profile workstation --skip-validation
git -C "$checkout" pull -q --ff-only
assert_exit 0 ds a agents install --profile workstation --skip-validation
named_link=$(home_of a)/.claude/skills/declared-name
assert_symlink_to "$named_link" ../../.agents/skills/folder-name
printf 'through the link\n' >>"$named_link/SKILL.md"
wrote a declared-name
find "$(home_of a)/.agents/skills/folder-name" -exec touch -h -d '2001-01-01' {} +
ds_code a skills capture --now
assert_contains "$(remote_file agent/skills/folder-name/SKILL.md)" "through the link"
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/declared-name/SKILL.md 2>/dev/null; then
  ds_fail "the copy goes to the directory of the entry"
fi

# --- a named machine: its host file arrives with its first commit ---------------------

new_machine named
jq -n --arg system "$fixture_system" '{schema_version: 1, name: "named", machine_key: "00112233445566778899aabbccddeeff", named_at: "2026-01-01T00:00:00Z",
  host: {system: $system, profile: "workstation", platform: "ubuntu-24.04", tags: []}}' >"$(state_of named)/machine.json"
own_new named hosted
settle named hosted
ds_code named skills capture --now
assert_contains "$(remote_file hosts/named.toml)" "system = \"$fixture_system\""
assert_eq "chore(skills): capture hosted" "$(git -C "$remote" log -1 --format=%s)"
tip=$(remote_tip)
printf 'more\n' >>"$(home_of named)/.claude/skills/hosted/SKILL.md"
wrote named hosted
settle named hosted
ds_code named skills capture --now
assert_eq "$tip" "$(git -C "$remote" rev-parse 'refs/heads/main^')"
assert_not_contains "$(git -C "$remote" diff-tree --no-commit-id --name-only -r refs/heads/main)" hosts/
