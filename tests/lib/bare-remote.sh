# shellcheck shell=bash
# Local git repositories and bare remotes for tests. Source it from a test
# (after the harness, which provides the git identity and defaultBranch
# main):
#   source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
#
#   ds_git_repo DIR                        a repository on main with one
#                                          commit (README.md)
#   ds_git_commit DIR FILE CONTENT MESSAGE writes FILE (relative to DIR,
#                                          parents created), commits it
#   ds_bare_remote BARE [REPO]             a bare repository with HEAD on
#                                          main; with REPO, every branch and
#                                          tag of REPO is pushed to it and it
#                                          becomes REPO's origin when REPO
#                                          has none
# Combine with tests/lib/fakessh.sh to reach a bare repository through an
# SSH remote URL.

ds_git_repo() {
  (($# == 1)) || {
    printf 'ds_git_repo: usage: ds_git_repo DIR\n' >&2
    return 1
  }
  [[ ! -e $1 ]] || {
    printf 'ds_git_repo: already exists: %s\n' "$1" >&2
    return 1
  }
  git init -q -b main "$1"
  printf '# Test repository\n' >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "chore: initial commit"
}

ds_git_commit() {
  (($# == 4)) || {
    printf 'ds_git_commit: usage: ds_git_commit DIR FILE CONTENT MESSAGE\n' >&2
    return 1
  }
  local dir=$1 file=$2
  mkdir -p "$(dirname "$dir/$file")"
  printf '%s\n' "$3" >"$dir/$file"
  git -C "$dir" add -- "$file"
  git -C "$dir" commit -q -m "$4"
}

ds_bare_remote() {
  (($# == 1 || $# == 2)) || {
    printf 'ds_bare_remote: usage: ds_bare_remote BARE [REPO]\n' >&2
    return 1
  }
  local bare=$1 repo=${2:-} absolute
  [[ ! -e $bare ]] || {
    printf 'ds_bare_remote: already exists: %s\n' "$bare" >&2
    return 1
  }
  git init -q --bare -b main "$bare"
  [[ -n $repo ]] || return 0
  absolute=$(cd "$bare" && pwd -P)
  git -C "$repo" push -q "$absolute" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" remote add origin "$absolute"
    git -C "$repo" fetch -q origin
  fi
}
