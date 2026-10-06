# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# I7 (SPEC 10.3): init never writes outside --dir. Whether it succeeds, is
# refused or fails in a step, everything outside the target is afterwards as
# it was before: HOME, TMPDIR (the temporary directory init composed the
# instance in is gone), the state root, the working directory, the parent of
# the target and the framework checkout. Only the test's own bookkeeping
# (the stub state with the fake Nix's caches, the call log and the isolated
# Nix store) changes.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"
dir=$DS_TEST_ROOT/instances/station

# outside: the state of DS_TEST_ROOT without the target and the test's
# bookkeeping.
outside() {
  (
    cd "$DS_TEST_ROOT"
    find . \( -path ./stubs -o -path ./calls.log -o -path ./nix -o -path ./instances/station \) -prune \
      -o -printf '%p %y %m %s\n' | LC_ALL=C sort |
      while IFS= read -r line; do
        path=${line%% *}
        if [[ -f $path && ! -L $path ]]; then
          printf '%s %s\n' "$line" "$(sha256sum <"$path" | cut -d' ' -f1)"
        else
          printf '%s\n' "$line"
        fi
      done
  )
}

# repo_state: the tracked and untracked files of the framework checkout (it
# may be a plain directory in the build sandbox).
repo_state() {
  tree_state "$DS_REPO_ROOT" | grep -v '^\./\.git[/ ]' || true
}

# unchanged_outside RUN...: RUN leaves everything outside the target as it
# was.
unchanged_outside() {
  local before repo_before
  before=$(outside)
  repo_before=$(repo_state)
  "$@"
  assert_eq "$before" "$(outside)" "outside the target after: $*"
  assert_eq "$repo_before" "$(repo_state)" "the framework checkout after: $*"
}

cd "$DS_TEST_ROOT/work"
all=$(
  IFS=,
  echo "${init_catalog[*]}"
)

# Success into a missing directory, with the working directory elsewhere.
unchanged_outside init_run 0 --dir "$dir" --remote "$init_remote" --components "$all" --allow-unfree
[[ -f $dir/flake.lock ]] || ds_fail "init did not write the instance"

# A refusal: the target is not empty.
unchanged_outside init_run 1 --dir "$dir" --remote "$init_remote"

# A failed step, into an empty directory and into a template directory.
rm -rf "$dir"
mkdir "$dir"
unchanged_outside assert_exit 1 env DS_INIT_NIX_FAIL='eval *#lib.pinnedVersions' DS_INIT_NIX_FAIL_SKIP=1 \
  "$DS_CLI" init --dir "$dir" --remote "$init_remote" --components shell
assert_contains "$DS_STDERR" "dotsteward pins check --nix failed"
cp -R "$tpl/." "$dir/"
unchanged_outside assert_exit 1 env DS_INIT_NIX_FAIL='flake lock *' "$DS_CLI" init --dir "$dir" --remote "$init_remote"

# Success in place, with the working directory inside the target.
cd "$dir"
unchanged_outside init_run 0 --dir . --remote "$init_remote" --no-git
assert_eq "$dir" "$(jq -r .instance.checkout <<<"$(toml_json "$dir/workstation.toml")")" "--dir . is the working directory"

# The caller's git environment names another repository (init run from a git
# hook, `git rebase -x` or a tool that exports GIT_DIR): init commits in --dir
# only, and the other repository's HEAD, index and files stay as they were.
cd "$DS_TEST_ROOT/work"
other=$DS_TEST_ROOT/other
mkdir -p "$other"
printf 'other\n' >"$other/README"
git -C "$other" init -q -b main
commit_all "$other" "chore: the other repository"
other_head=$(git -C "$other" rev-parse HEAD)
other_index=$(sha256sum <"$other/.git/index")

# other_unchanged CASE: the other repository is as it was.
other_unchanged() {
  assert_eq "$other_head" "$(git -C "$other" rev-parse HEAD)" "the other repository's HEAD after $1"
  assert_eq 1 "$(git -C "$other" rev-list --count --all)" "the other repository's commits after $1"
  assert_eq "$other_index" "$(sha256sum <"$other/.git/index")" "the other repository's index after $1"
}

# A flake-init directory that is a git repository already, with GIT_DIR set.
rm -rf "$dir"
mkdir -p "$dir"
cp -R "$tpl/." "$dir/"
git -C "$dir" init -q -b main
commit_all "$dir" "chore: nix flake init"
first=$(git -C "$dir" rev-parse HEAD)
unchanged_outside assert_exit 0 env GIT_DIR="$other/.git" \
  "${DS_INIT_CLI:-$DS_CLI}" init --dir "$dir" --remote "$init_remote" --components shell
other_unchanged "init with GIT_DIR into a repository"
assert_eq 2 "$(git -C "$dir" rev-list --count HEAD)" "init commits in --dir"
assert_eq "$first" "$(git -C "$dir" rev-parse HEAD~1)" "the history of --dir stays"
assert_eq "chore: initialize dotsteward instance" "$(git -C "$dir" log -1 --format=%s)" "the commit in --dir"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all)" "clean tree in --dir"

# A missing directory, with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE set.
rm -rf "$dir"
unchanged_outside assert_exit 0 env GIT_DIR="$other/.git" GIT_WORK_TREE="$other" \
  GIT_INDEX_FILE="$other/.git/index" \
  "${DS_INIT_CLI:-$DS_CLI}" init --dir "$dir" --remote "$init_remote" --components shell
other_unchanged "init with GIT_DIR into a missing directory"
assert_eq 1 "$(git -C "$dir" rev-list --count HEAD)" "init commits in the new --dir"
assert_eq "chore: initialize dotsteward instance" "$(git -C "$dir" log -1 --format=%s)" "the commit in the new --dir"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all)" "clean tree in the new --dir"
