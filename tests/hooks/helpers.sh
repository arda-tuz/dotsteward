# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers shared by the pre-push hook tests. Not a test file (no test- prefix).
#
# Every test pushes through the real hook with `git push` to a local bare
# remote. Leak strings come from the privacy helpers, which assemble them at
# run time so that no file of the framework holds one.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

# shellcheck disable=SC2034 # read by the test files that source this file
HOOK=$DS_REPO_ROOT/.githooks/pre-push
DENYLIST=$HOME/.config/dotsteward/denylist.txt

# Every commit of the hook tests satisfies the framework commit rules unless
# a test overrides the identity or the date on purpose.
use_noreply_identity

# write_denylist TERM...: the private denylist at its fixed location, mode
# 0600, with a comment on line 1 (so TERM n is reported as denylist:n+1).
write_denylist() {
  mkdir -p "$(dirname "$DENYLIST")"
  printf '%s\n' "# hook test denylist" "$@" >"$DENYLIST"
  chmod 0600 "$DENYLIST"
}

# remove_denylist: the denylist file is gone.
remove_denylist() {
  rm -f -- "$DENYLIST"
}

# hook_repo DIR [plain]: a repository with one base commit on main, the hook
# installed through core.hooksPath (absolute path to the framework's hook
# directory) and a bare remote "origin" at DIR.git with a relative URL. The
# base commit carries privacy/policy.toml, which marks a framework
# repository, unless the second argument is "plain".
hook_repo() {
  local dir=$1 kind=${2:-framework}
  new_repo "$dir"
  git init -q --bare "$dir.git"
  if [[ $kind != plain ]]; then
    copy_policy "$dir"
  fi
  printf 'base\n' >"$dir/README.md"
  commit_all "$dir" "chore: base"
  git -C "$dir" config core.hooksPath "$DS_REPO_ROOT/.githooks"
  git -C "$dir" remote add origin "../$(basename "$dir").git"
}

# push [GIT_PUSH_ARG...]: `git push` in the current directory, through
# assert_exit by the caller; the hook's output is in DS_STDERR because git
# sends hook output to standard error.
push() {
  git push -q "$@"
}

# hook_output: everything the last assert_exit captured.
hook_output() {
  printf '%s\n%s' "$DS_STDOUT" "$DS_STDERR"
}

# finding_lines: the redacted finding lines of the last assert_exit, in
# order (rule, then a location; never a [dotsteward] message).
finding_lines() {
  hook_output | grep -E '^[a-z0-9]+(-[a-z0-9]+)*(:[0-9]+)? [^ ]' | grep -v '^\[' || true
}

# remote_sha GIT_DIR REF: the value of REF in the (bare) repository GIT_DIR,
# empty when it does not exist.
remote_sha() {
  git --git-dir="$1" rev-parse --verify --quiet "$2" || true
}

# assert_no_hook_temp: the hook removed its temporary directories.
assert_no_hook_temp() {
  local left
  left=$(compgen -G "$TMPDIR/dotsteward-hook.*" || true)
  assert_eq "" "$left" "the hook leaves no temporary directory behind"
}

# add_file DIR PATH CONTENT MESSAGE: writes PATH and commits it.
add_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$4"
}
