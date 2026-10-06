# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# SPEC 10.3 step 6: the commit carries the user's own git identity, the one
# a plain `git commit` in --dir would use. Git chooses it by the location of
# the repository (an includeIf "gitdir:..." rule, for example a work
# identity for every repository below ~/work/), so init commits in --dir
# itself, never in the temporary directory the instance was composed in. A
# missing identity is refused before any Nix step when git can tell (a
# repository already, or no location-dependent configuration at all), else
# the commit fails and --dir is left as it was.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix

work_identity="Work <work@example.com>"
printf '[user]\nname = Work\nemail = work@example.com\n' >"$HOME/.gitconfig-work"
mkdir -p "$HOME/work" "$HOME/elsewhere"

# The harness configuration without its [user] section.
anonymous_config() {
  sed '/^\[user\]$/,/^email = /d' "$DS_TEST_ROOT/gitconfig"
}
# The includeIf rule that gives every repository below ~/work/ the work
# identity.
work_rule() {
  printf '[includeIf "gitdir:%s/work/"]\npath = %s/.gitconfig-work\n' "$HOME" "$HOME"
}

# author DIR: the name and email of the last commit's author and committer.
author() {
  git -C "$1" log -1 --format='%an <%ae>|%cn <%ce>'
}
# expected DIR: the identity `git commit` in DIR uses.
expected() {
  local author committer
  author=$(git -C "$1" var GIT_AUTHOR_IDENT)
  committer=$(git -C "$1" var GIT_COMMITTER_IDENT)
  printf '%s|%s\n' "${author% * *}" "${committer% * *}"
}

# flake_init_repository DIR: the template as `nix flake init -t` leaves it,
# committed to a new repository.
flake_init_repository() {
  mkdir -p "$1"
  cp -R "$tpl/." "$1/"
  chmod -R u+w "$1"
  git -C "$1" init -q -b main
  commit_all "$1" "chore: nix flake init"
}

# --- a global identity and a work identity for ~/work/ -----------------------------

{
  cat "$DS_TEST_ROOT/gitconfig"
  work_rule
} >"$DS_TEST_ROOT/gitconfig-work"
export GIT_CONFIG_GLOBAL=$DS_TEST_ROOT/gitconfig-work

# A missing directory below ~/work/.
dir=$HOME/work/station
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$work_identity|$work_identity" "$(expected "$dir")" "git in --dir uses the work identity"
assert_eq "$(expected "$dir")" "$(author "$dir")" "the commit in a new directory below ~/work/"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all)" "clean tree in a new directory"

# An empty directory below ~/work/.
dir=$HOME/work/empty
mkdir "$dir"
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$work_identity|$work_identity" "$(author "$dir")" "the commit in an empty directory below ~/work/"

# A flake-init repository below ~/work/: the commit goes on top of its
# history, without the directory init keeps the previous entries in.
dir=$HOME/work/repo
flake_init_repository "$dir"
first=$(git -C "$dir" rev-parse HEAD)
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$work_identity|$work_identity" "$(author "$dir")" "the commit in a repository below ~/work/"
assert_eq "$first" "$(git -C "$dir" rev-parse HEAD~1)" "the history of the repository stays"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all --ignored)" "clean tree in the repository"
assert_eq "" "$(git -C "$dir" ls-files | grep -F .dotsteward-init- || true)" "nothing of init's own is committed"
assert_eq "" "$(find "$dir" -maxdepth 1 -name '.dotsteward-init-*' -print)" "init's previous entries are gone"

# Elsewhere the global identity stays.
dir=$HOME/elsewhere/station
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$DS_TEST_IDENTITY_NAME <$DS_TEST_IDENTITY_EMAIL>|$DS_TEST_IDENTITY_NAME <$DS_TEST_IDENTITY_EMAIL>" \
  "$(author "$dir")" "the commit outside ~/work/"

# --- only the work identity (no global [user]) ----------------------------------------

{
  anonymous_config
  work_rule
} >"$DS_TEST_ROOT/gitconfig-work-only"
export GIT_CONFIG_GLOBAL=$DS_TEST_ROOT/gitconfig-work-only

# A flake-init repository below ~/work/.
dir=$HOME/work/only-repo
flake_init_repository "$dir"
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$work_identity|$work_identity" "$(author "$dir")" "the commit in a repository with only the work identity"
assert_eq 2 "$(git -C "$dir" rev-list --count HEAD)" "one commit on top of the repository's history"

# A missing directory below ~/work/: git has the identity once the
# repository exists, so init does not refuse early.
dir=$HOME/work/only-station
init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "$work_identity|$work_identity" "$(author "$dir")" "the commit in a new directory with only the work identity"

# A missing directory elsewhere: the commit has no identity and fails after
# the Nix steps; the directory stays missing and no temporary directory is
# left.
dir=$HOME/elsewhere/anonymous
assert_exit 1 "$DS_CLI" init --dir "$dir" --remote "$init_remote" --components shell
assert_contains "$DS_STDERR" "Author identity unknown"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: git commit failed (exit 128); $dir was left as it was"
[[ ! -e $dir ]] || ds_fail "a failed commit left $dir"
assert_eq "" "$(init_temp_dirs)" "no temporary directory is left after a failed commit"

# An empty directory and a flake-init repository elsewhere, likewise as they
# were: the repository is refused before any Nix step (git knows its
# identity there), the empty directory after the commit failed.
dir=$HOME/elsewhere/empty
mkdir "$dir"
chmod 0750 "$dir"
before=$(tree_state "$dir")
assert_exit 1 "$DS_CLI" init --dir "$dir" --remote "$init_remote" --components shell
assert_contains "$DS_STDERR" "[dotsteward] ERROR: git commit failed (exit 128); $dir was left as it was"
assert_unchanged "$dir" "$before" "an empty directory after a failed commit"
assert_eq "" "$(init_temp_dirs)" "no temporary directory is left after a failed commit (empty)"

dir=$HOME/elsewhere/repo
mkdir -p "$dir"
cp -R "$tpl/." "$dir/"
git -C "$dir" init -q -b main
before=$(tree_state "$dir")
: >"$DS_CALL_LOG"
assert_exit 1 "$DS_CLI" init --dir "$dir" --remote "$init_remote" --components shell
assert_contains "$DS_STDERR" "[dotsteward] ERROR: git has no identity for the commit; set user.name and user.email (git config --global), or pass --no-git"
assert_call_count 0 nix
assert_unchanged "$dir" "$before" "a repository without an identity"
