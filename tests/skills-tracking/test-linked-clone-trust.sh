# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A clone says where a skill comes from only for what its remote holds. What is published
# is the tree of the pinned commit: a file git ignores in the clone (an .env) or an
# untracked one never goes, and the skill is unknown while it is there. A commit of the
# clone that no remote branch holds is not upstream: unknown before an answer, and drift
# (red) after one, as is any other difference to the pinned tree; only a clean clone of the
# upstream at another commit is a note. A remote that is a path of this machine is no
# upstream. Credentials of every shape stay out. Nothing the clone configures runs: its
# fsmonitor and hooks stay silent through reconcile, track, agents install and check.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
install=(agents install --profile workstation --skip-validation)
agents_skills=$(home_of a)/.agents/skills
sources=$(home_of a)/.local/share/skill-sources
mkdir -p "$sources"

# upstream NAME SKILL...: a repository with the skills as its directories, the license at
# its top and a .gitignore for local files, and a bare copy of it that stands in for
# https://github.com/example-org/NAME.
upstream() {
  local name=$1 skill
  shift
  git init -q -b main "$world/$name"
  for skill in "$@"; do
    mkdir -p "$world/$name/$skill"
    printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\nversion one\n' "$skill" >"$world/$name/$skill/SKILL.md"
  done
  printf 'Synthetic license\n' >"$world/$name/LICENSE"
  printf '.env\n*.local\n' >"$world/$name/.gitignore"
  git -C "$world/$name" add -A
  git -C "$world/$name" commit -q -m "chore: skills"
  git clone -q --bare "$world/$name" "$world/$name.git"
}

# cloned NAME: the clone of upstream NAME under its public remote.
cloned() {
  git -c "url.file://$world/$1.git.insteadOf=https://github.com/example-org/$1" \
    clone -q "https://github.com/example-org/$1" "$sources/$1"
}

upstream figs s-ignored s-local s-fsmon
cloned figs
clone=$sources/figs

# --- a file git ignores in the clone: unknown, and never published ---------------------------------

ln -s "$clone/s-ignored" "$agents_skills/s-ignored"
printf 'TOKEN=synthetic-value\n' >"$clone/s-ignored/.env"
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a s-ignored .origin)"
assert_contains "$(item a s-ignored .origin_detail)" ".env"
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code a skills track s-ignored --all
assert_contains "$DS_STDERR" ".env"
assert_eq "$tip" "$(remote_tip)"
# Without it, the tree of the commit goes, and only that.
rm -f "$clone/s-ignored/.env"
ds_code a skills track s-ignored --all
assert_eq "$(git -C "$clone" rev-parse HEAD)" "$(remote_entry s-ignored | jq -r .revision)"
assert_eq "SKILL.md" "$(git -C "$remote" ls-tree --name-only -r refs/heads/main agent/skills/s-ignored | sed 's|.*/||')"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
assert_exit 0 ds a agents check --profile workstation

# --- after the answer, what the pinned tree does not hold is drift, red ------------------------------

printf 'TOKEN=synthetic-value\n' >"$clone/s-ignored/.env"
EXPECT_STATUS=1 ds_code a agents check --profile workstation
assert_contains "$DS_STDERR" "installed skill differs from the lock: s-ignored"
rm -f "$clone/s-ignored/.env"
printf 'an instruction of nobody upstream\n' >>"$clone/s-ignored/SKILL.md"
git -C "$clone" commit -q -am "chore: a commit of this clone only"
EXPECT_STATUS=1 ds_code a agents check --profile workstation
assert_contains "$DS_STDERR" "installed skill differs from the lock: s-ignored"
assert_not_contains "$DS_STDERR" "follows its clone"
git -C "$clone" reset -q --hard HEAD~1
assert_exit 0 ds a agents check --profile workstation

# --- a commit no remote branch holds is not upstream ------------------------------------------------

printf 'a local change\n' >>"$clone/s-local/SKILL.md"
git -C "$clone" commit -q -am "chore: another commit of this clone only"
ln -s "$clone/s-local" "$agents_skills/s-local"
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a s-local .origin)"
assert_contains "$(item a s-local .origin_detail)" "no remote branch"
EXPECT_STATUS=1 ds_code a skills track s-local --all
assert_contains "$DS_STDERR" "no remote branch"
git -C "$clone" reset -q --hard HEAD~1

# --- a remote that is a path of this machine is no upstream ------------------------------------------

upstream paths s-path
git clone -q "$world/paths.git" "$sources/paths"
ln -s "$sources/paths/s-path" "$agents_skills/s-path"
assert_exit 0 ds a skills reconcile
assert_eq unknown "$(item a s-path .origin)"
assert_contains "$(item a s-path .origin_detail)" "path of this machine"
EXPECT_STATUS=1 ds_code a skills track s-path --all
assert_contains "$DS_STDERR" "path of this machine"
if git -C "$remote" grep -q "$world" refs/heads/main --; then
  ds_fail "no path of this machine reaches the remote"
fi

# --- credentials of every shape stay out --------------------------------------------------------------

upstream creds s-creds
cloned creds
ln -s "$sources/creds/s-creds" "$agents_skills/s-creds"
for pair in \
  "https://user:p@ss@example.com/example-org/creds.git|https://example.com/example-org/creds.git" \
  "https://token@example.com/example-org/creds.git?private_token=synthetic|https://example.com/example-org/creds.git" \
  "ssh://user:synthetic@example.com/example-org/creds.git|ssh://user@example.com/example-org/creds.git"; do
  git -C "$sources/creds" remote set-url origin "${pair%%|*}"
  rm -f "$(state_of a)/skills/pending.json"
  assert_exit 0 ds a skills reconcile
  assert_eq "${pair#*|}" "$(item a s-creds .source.url)"
done
if grep -rq "synthetic\|p@ss" "$(state_of a)/skills/pending.json"; then
  ds_fail "no credential is kept"
fi

# --- nothing the clone configures runs ------------------------------------------------------------------

marker=$DS_TEST_ROOT/clone-command-ran
git -C "$clone" config core.fsmonitor "touch $marker; false"
mkdir -p "$DS_TEST_ROOT/clone-hooks"
printf '#!/bin/sh\ntouch %s\n' "$marker" >"$DS_TEST_ROOT/clone-hooks/post-index-change"
chmod 0755 "$DS_TEST_ROOT/clone-hooks/post-index-change"
git -C "$clone" config core.hooksPath "$DS_TEST_ROOT/clone-hooks"
ln -s "$clone/s-fsmon" "$agents_skills/s-fsmon"
assert_exit 0 ds a skills reconcile
assert_eq downloaded "$(item a s-fsmon .origin)"
ds_code a skills track s-fsmon --all
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a "${install[@]}"
assert_exit 0 ds a agents check --profile workstation
assert_exit 0 ds a skills reconcile --full
[[ ! -e $marker ]] || ds_fail "a command the clone configures ran"

# --- every question that offers --never offers --later too ----------------------------------------------

pending=$(state_of a)/skills/pending.json
jq '.items += {
  "skill:gone": {kind: "skill", name: "gone", state: "deleted", origin: "own"},
  "skill:taken": {kind: "skill", name: "taken", state: "name-taken", origin: "unknown"}}' "$pending" >"$pending.tmp"
mv -- "$pending.tmp" "$pending"
HOOK_ENV=(CLAUDE_CODE_ENTRYPOINT=cli)
HOOK_SESSION=fe058fc9-0000-4000-8000-0000000000b1
hook_on a Stop stop
reason=$(jq -r .reason <<<"$HOOK_OUT")
assert_contains "$(grep 'Deleted on this machine' <<<"$reason")" "--later"
assert_contains "$(grep 'The name is taken' <<<"$reason")" "--later"
