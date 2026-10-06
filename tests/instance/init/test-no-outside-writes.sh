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
